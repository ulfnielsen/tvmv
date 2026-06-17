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

# --- 3. Ad-hoc codesign ---------------------------------------------------
echo "==> codesign (ad-hoc, --deep --force)"
codesign -s - --deep --force $app; or exit $fail_status
codesign --verify --verbose $app; or exit $fail_status
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

# --- 5. Install the CLI shim ---------------------------------------------
set -l bindir $HOME/.local/bin
mkdir -p $bindir
echo "==> installing CLI shim -> $bindir/tvmv"
cp $repo_root/build/tvmv $bindir/tvmv
chmod +x $bindir/tvmv
echo "    shim installed"

echo "==> done."
