#!/usr/bin/env fish
#
# release.fish [major|minor|patch]  (default: patch)
#
# Cuts a TVMV release:
#   1. runs the test suite
#   2. bumps CFBundleShortVersionString (semver) + CFBundleVersion (build number)
#   3. builds + signs TVMV.app (build/bundle.fish)
#   4. zips it (ditto, preserving the code signature)
#   5. commits "Release vX.Y.Z", tags vX.Y.Z
#   6. pushes branch + tag, and creates a GitHub Release with the zip attached
#
# Prereqs: a git `origin` remote on GitHub, `gh` authenticated, clean working tree.

set -l part $argv[1]
test -z "$part"; and set part patch
if not contains -- $part major minor patch
    echo "usage: release.fish [major|minor|patch]" >&2
    exit 1
end

# Repo root = this script's parent's parent (script lives in <root>/build/).
set -l repo_root (path resolve (status filename) | path dirname | path dirname)
cd $repo_root; or exit 1
set -l plist build/Info.plist

# Use the Xcode toolchain (XCTest + release build) even when Command Line Tools
# is the active selection.
if test -d /Applications/Xcode.app/Contents/Developer
    set -gx DEVELOPER_DIR /Applications/Xcode.app/Contents/Developer
end

# --- Preconditions --------------------------------------------------------
if test (count (git status --porcelain)) -gt 0
    echo "error: working tree has uncommitted changes — commit or stash first." >&2
    exit 1
end
if not git remote get-url origin >/dev/null 2>&1
    echo "error: no 'origin' remote. Create the GitHub repo first:" >&2
    echo "  gh repo create <owner>/tvmv --source=. --remote=origin --push --private" >&2
    exit 1
end
if not gh auth status >/dev/null 2>&1
    echo "error: gh is not authenticated (run: gh auth login)." >&2
    exit 1
end

# --- Compute the new version ---------------------------------------------
set -l cur (/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $plist)
set -l p (string split . $cur)
set -l maj $p[1]; set -l min $p[2]; set -l pat $p[3]
switch $part
    case major; set maj (math $maj + 1); set min 0; set pat 0
    case minor; set min (math $min + 1); set pat 0
    case patch; set pat (math $pat + 1)
end
set -l ver "$maj.$min.$pat"
set -l tag "v$ver"
set -l build (math (/usr/libexec/PlistBuddy -c "Print CFBundleVersion" $plist) + 1)

if git rev-parse "$tag" >/dev/null 2>&1
    echo "error: tag $tag already exists." >&2
    exit 1
end

echo "==> Releasing TVMV $ver (build $build) — $part bump from $cur"

# --- Changelog (commits since the previous tag) --------------------------
set -l prev (git describe --tags --abbrev=0 2>/dev/null)
set -l changelog
if test -n "$prev"
    set changelog (git log "$prev..HEAD" --no-merges --pretty="- %s")
else
    set changelog (git log --no-merges --pretty="- %s")
end

# --- Run tests ------------------------------------------------------------
echo "==> swift test"
swift test; or begin
    echo "error: tests failed — aborting release." >&2
    exit 1
end

# --- Stamp the version ----------------------------------------------------
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $ver" $plist
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $build" $plist

# --- Build + sign the .app ------------------------------------------------
if not fish build/bundle.fish
    echo "error: build failed — reverting version stamp." >&2
    git checkout -- $plist
    exit 1
end

# --- Package (ditto preserves the code signature) -------------------------
set -l zip $repo_root/dist/TVMV-$tag.zip
rm -f $zip
ditto -c -k --sequesterRsrc --keepParent $repo_root/dist/TVMV.app $zip
echo "==> packaged $zip"

# --- Commit + tag ---------------------------------------------------------
git add $plist
git commit -m "Release $tag"
git tag -a "$tag" -m "TVMV $ver"

# --- Push -----------------------------------------------------------------
set -l branch (git rev-parse --abbrev-ref HEAD)
git push origin $branch
git push origin "$tag"

# --- GitHub Release -------------------------------------------------------
set -l notes_file (mktemp)
begin
    echo "## TVMV $ver"
    echo
    echo "### Changes"
    for line in $changelog
        echo $line
    end
    echo
    echo "### Install"
    echo "Download \`TVMV-$tag.zip\`, unzip, and move **TVMV.app** to \`/Applications\`."
    echo
    echo "This build is ad-hoc signed (not notarized), so on first launch macOS may"
    echo "block it. Right-click the app → **Open** → **Open**, or clear quarantine:"
    echo
    echo '```sh'
    echo "xattr -dr com.apple.quarantine /Applications/TVMV.app"
    echo '```'
end > $notes_file

gh release create "$tag" $zip --title "TVMV $ver" --notes-file $notes_file
rm -f $notes_file

set -l nwo (gh repo view --json nameWithOwner -q .nameWithOwner)
echo "==> done: https://github.com/$nwo/releases/tag/$tag"
