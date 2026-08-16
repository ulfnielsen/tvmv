#!/usr/bin/env fish
#
# bundle.fish — assemble the SwiftPM executable into a signed tvmv.app.
#
# Steps:
#   1. release build, locate bin dir + executable + tvmv_tvmv.bundle
#   2. assemble dist/tvmv.app (Contents/MacOS, Contents/Resources)
#   3. codesign  (resource bundle in Contents/Resources => seals clean)
#   4. install to ~/Applications, register doc types via lsregister
#   5. install the CLI shim to ~/.local/bin/tvmv
#
# Signing identity comes from build/signing.fish: a Developer ID Application
# certificate when one is in the keychain, ad-hoc otherwise. See that file.
#
# Run from anywhere; paths are resolved relative to the repo root.

set -l fail_status 1

# --- Locate repo root robustly -------------------------------------------
# This script lives in <repo>/build/, so the repo root is its parent's parent.
set -l script_dir (path resolve (status filename) | path dirname)
set -l repo_root (path resolve $script_dir/..)

echo "==> repo root: $repo_root"
cd $repo_root; or exit $fail_status

# Resolve the signing identity (Developer ID when available, else ad-hoc).
source $repo_root/build/signing.fish; or exit $fail_status
tvmv_report_identity

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

# --- 3. Codesign ----------------------------------------------------------
# Sign strictly INSIDE-OUT, never with --deep. Apple deprecates --deep for
# signing, and it is actively wrong here: it re-signs the embedded appexes
# without entitlements, stripping the sandbox entitlement QuickLook requires
# to load them. (The old code worked around that by re-signing each appex
# afterwards, which --deep had already invalidated.)
#
# quicklook.fish has already signed each appex WITH its entitlements before
# embedding it, and cp -R preserves those signatures. So all that remains is
# sealing the outer app, which seals each appex by reference (cdhash) and
# leaves its signature — and its entitlements — intact.
echo "==> codesign app (hardened runtime)"
tvmv_sign $app; or exit $fail_status

# --- 3b. Verify the signature --------------------------------------------
# --deep IS correct for verification (unlike signing): it walks the whole
# nested tree. --strict rejects the malformed-bundle cases Gatekeeper rejects.
echo "==> verifying signature"
codesign --verify --deep --strict --verbose=2 $app; or exit $fail_status
echo "    signature OK"

# The sandbox entitlement surviving on each appex is the exact thing --deep
# used to break, so assert it rather than trust it.
for appex_embedded in $app/Contents/PlugIns/*.appex
    if test -d $appex_embedded
        set -l name (path basename $appex_embedded)
        if codesign -d --entitlements - --xml $appex_embedded 2>/dev/null | grep -q app-sandbox
            echo "    $name: sandbox entitlement intact"
        else
            echo "ERROR: $name lost its sandbox entitlement — QuickLook will not load it" >&2
            exit $fail_status
        end
    end
end

# Informational: unnotarized Developer ID builds are rejected here by design.
# release.fish notarizes and staples, which is what flips this to accepted.
echo "==> Gatekeeper assessment (informational)"
spctl -a -vv -t exec $app 2>&1 | sed 's/^/    /'

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
