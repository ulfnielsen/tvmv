#!/usr/bin/env fish
#
# bundle.fish — assemble the SwiftPM executable into a signed tvmv.app.
#
# Steps:
#   1. release build, locate bin dir + executable + tvmv_tvmv.bundle
#   2. assemble dist/tvmv.app (Contents/MacOS, Contents/Resources)
#   3. ad-hoc codesign  (resource bundle in Contents/Resources => seals clean)
#   4. install to ~/Applications, register doc types via lsregister
#   5. install the CLI shim to ~/.local/bin/tvmv
#
# Run from anywhere; paths are resolved relative to the repo root.

set -l fail_status 1

# --- Locate repo root robustly -------------------------------------------
# This script lives in <repo>/build/, so the repo root is its parent's parent.
set -l script_dir (path resolve (status filename) | path dirname)
set -l repo_root (path resolve $script_dir/..)

echo "==> repo root: $repo_root"
cd $repo_root; or exit $fail_status

# --- 1. Build & locate artifacts -----------------------------------------
echo "==> swift build -c release"
swift build -c release; or exit $fail_status

set -l bin (swift build -c release --show-bin-path)
echo "==> bin dir: $bin"

set -l exe $bin/tvmv
set -l resbundle $bin/tvmv_tvmv.bundle
if not test -x $exe
    echo "ERROR: executable not found at $exe" >&2
    exit $fail_status
end
if not test -d $resbundle
    echo "ERROR: resource bundle not found at $resbundle" >&2
    exit $fail_status
end

# --- 2. Assemble the .app -------------------------------------------------
# Bundle is TVMV.app (display name); the executable inside stays lowercase tvmv.
set -l app $repo_root/dist/TVMV.app
echo "==> assembling $app"
rm -rf $app
mkdir -p $app/Contents/MacOS
mkdir -p $app/Contents/Resources

cp $exe $app/Contents/MacOS/tvmv
echo "    copied executable -> Contents/MacOS/tvmv"

cp $repo_root/build/Info.plist $app/Contents/Info.plist
echo "    copied Info.plist -> Contents/Info.plist"

# Resource bundle MUST live under Contents/Resources so codesign can seal it.
cp -R $resbundle $app/Contents/Resources/tvmv_tvmv.bundle
echo "    copied tvmv_tvmv.bundle -> Contents/Resources/"

# App icon (optional).
set -l icon $repo_root/build/AppIcon.icns
if test -f $icon
    cp $icon $app/Contents/Resources/AppIcon.icns
    echo "    copied AppIcon.icns -> Contents/Resources/"
else
    echo "    (no AppIcon.icns at build/AppIcon.icns; skipping)"
end

# --- 2b. Build + embed the QuickLook extension ----------------------------
# Must run BEFORE the app codesign below so the app signature seals the
# embedded .appex (the appex is itself already signed with its sandbox
# entitlement inside quicklook.fish).
echo "==> embedding QuickLook extension via build/quicklook.fish"
fish $repo_root/build/quicklook.fish; or exit $fail_status

# --- 3. Ad-hoc codesign ---------------------------------------------------
# The deep sign seals the whole tree, but it also RE-SIGNS the embedded
# QuickLook .appex(es) without entitlements — stripping the sandbox entitlement
# that QuickLook requires to load each extension. So after the deep sign we
# re-sign every embedded appex WITH its entitlements, then re-seal the app
# WITHOUT --deep (which seals each appex by reference, leaving its signature
# intact).
set -l ql_ent $repo_root/quicklook/entitlements.plist

echo "==> codesign (ad-hoc, --deep --force)"
codesign -s - --deep --force $app; or exit $fail_status

set -l embedded_appexes $app/Contents/PlugIns/*.appex
set -l resealed 0
for appex_embedded in $embedded_appexes
    if test -d $appex_embedded
        echo "==> re-signing embedded appex with sandbox entitlement: "(path basename $appex_embedded)
        codesign -s - --force --entitlements $ql_ent $appex_embedded; or exit $fail_status
        set resealed 1
    end
end
if test $resealed -eq 1
    echo "==> re-sealing app (no --deep, preserves appex signatures)"
    codesign -s - --force $app; or exit $fail_status
end

codesign --verify --deep --strict --verbose $app; or exit $fail_status
echo "    signature OK"

# --- 4. Install + register doc types -------------------------------------
set -l installed $HOME/Applications/TVMV.app
mkdir -p $HOME/Applications
echo "==> installing to $installed"
rm -rf $installed $HOME/Applications/tvmv.app
cp -R $app $installed

set -l lsregister /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
echo "==> registering document types via lsregister"
$lsregister -f $installed
echo "    registered $installed"

# Register the embedded QuickLook extensions (preview + thumbnail) with
# pluginkit so they are discoverable.
for installed_appex in $installed/Contents/PlugIns/*.appex
    if test -d $installed_appex
        echo "==> registering QuickLook extension via pluginkit -a: "(path basename $installed_appex)
        pluginkit -a $installed_appex
        echo "    pluginkit registered $installed_appex"
    end
end

# --- 5. Install the CLI shim ---------------------------------------------
set -l bindir $HOME/.local/bin
mkdir -p $bindir
echo "==> installing CLI shim -> $bindir/tvmv"
cp $repo_root/build/tvmv $bindir/tvmv
chmod +x $bindir/tvmv
echo "    shim installed"

echo "==> done."
