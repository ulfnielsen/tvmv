#!/usr/bin/env fish
#
# release.fish [major|minor|patch]  (default: patch)
#
# Cuts a TVMV release:
#   1. runs the test suite
#   2. bumps CFBundleShortVersionString (semver) + CFBundleVersion (build number)
#   3. builds + signs TVMV.app with Developer ID (build/bundle.fish)
#   4. notarizes the app and staples the ticket to it
#   5. packages a stapled .zip and a notarized + stapled .dmg
#   6. commits "Release vX.Y.Z", tags vX.Y.Z
#   7. pushes branch + tag, and creates a GitHub Release with both assets
#
# Prereqs: a git `origin` remote on GitHub, `gh` authenticated, clean working
# tree, a Developer ID Application certificate, and a notarytool keychain
# profile (default name "tvmv-notary", override with $TVMV_NOTARY_PROFILE):
#
#   xcrun notarytool store-credentials tvmv-notary \
#       --key <AuthKey_XXXXXXXXXX.p8> --key-id <KEYID> --issuer <ISSUER-UUID>
#
# Notarization requires network access and normally takes 1-5 minutes per
# submission; there are two per release (the app, then the disk image).

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

# A release MUST be Developer ID signed — an ad-hoc build cannot be notarized
# and Gatekeeper rejects it on every Mac but this one.
source $repo_root/build/signing.fish; or exit 1
tvmv_report_identity
if test "$tvmv_identity_kind" = adhoc
    echo "error: no Developer ID Application certificate found — cannot cut a release." >&2
    echo "  create one: Xcode > Settings > Accounts > <team> > Manage Certificates > + >" >&2
    echo "  Developer ID Application  (team Account Holder only)" >&2
    exit 1
end

# Fail fast on missing notary credentials: this is a live authenticated call,
# so it catches a revoked or mistyped key BEFORE we run tests and a full build.
set -l notary_profile tvmv-notary
set -q TVMV_NOTARY_PROFILE; and set notary_profile $TVMV_NOTARY_PROFILE
echo "==> checking notary credentials (profile: $notary_profile)"
if not xcrun notarytool history --keychain-profile $notary_profile >/dev/null 2>&1
    echo "error: notarytool profile '$notary_profile' is missing or invalid." >&2
    echo "  create it with:" >&2
    echo "    xcrun notarytool store-credentials $notary_profile \\" >&2
    echo "        --key <AuthKey_XXXXXXXXXX.p8> --key-id <KEYID> --issuer <ISSUER-UUID>" >&2
    exit 1
end
echo "    credentials OK"

# abort_release <reason> — bail out, undoing the in-place version stamp so a
# failed release leaves the working tree exactly as it was found.
function abort_release --inherit-variable plist
    echo "error: $argv[1] — reverting version stamp." >&2
    git checkout -- $plist quicklook/Info.plist
    exit 1
end

# tvmv_notarize <path> — submit to the notary service and wait for a verdict.
# On rejection, fetch and print the notary log: it names the offending binary
# and reason, which is the only practical way to debug a rejection.
#
# --timeout is deliberate. Plain --wait blocks forever, so a wedged submission
# hangs the release with no diagnosis. Two hours is generous: submissions are
# usually minutes, but 90 minutes has been observed with no incident reported
# on Apple's status page, so a short timeout would abort perfectly good runs.
function tvmv_notarize --inherit-variable notary_profile
    set -l target $argv[1]
    set -l out (mktemp)
    echo "==> notarizing "(path basename $target)" — usually minutes, occasionally over an hour"
    xcrun notarytool submit $target --keychain-profile $notary_profile \
        --wait --timeout 2h 2>&1 | tee $out
    if grep -q 'status: Accepted' $out
        echo "    notarization accepted"
        rm -f $out
        return 0
    end
    if grep -qi 'timed out\|timeout' $out
        echo "error: notarization timed out after 2h for "(path basename $target)"." >&2
        echo "  The submission may still complete — check with:" >&2
        echo "    xcrun notarytool history --keychain-profile $notary_profile" >&2
    end
    echo "error: notarization failed for "(path basename $target) >&2
    set -l sid (grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' $out | head -n1)
    if test -n "$sid"
        echo "==> notary log for submission $sid:" >&2
        xcrun notarytool log $sid --keychain-profile $notary_profile >&2
    end
    rm -f $out
    return 1
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
# Keep the QuickLook extension's version in sync with the app.
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $ver" quicklook/Info.plist
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $build" quicklook/Info.plist

# --- Build + sign the .app ------------------------------------------------
if not fish build/bundle.fish
    abort_release "build failed"
end

set -l app $repo_root/dist/TVMV.app

# --- Notarize the app, then staple the ticket -----------------------------
# notarytool cannot take a bare .app directory, so submit a throwaway zip.
# The ticket is issued against the app's cdhash, so once it is accepted we
# staple it onto the .app itself — and every container we then build FROM
# that stapled app (the release zip, the dmg) carries the ticket with it.
# Stapling is what lets first launch succeed OFFLINE; without it macOS has to
# reach Apple to confirm notarization.
set -l notarize_dir (mktemp -d)
ditto -c -k --sequesterRsrc --keepParent $app $notarize_dir/TVMV.zip
if not tvmv_notarize $notarize_dir/TVMV.zip
    rm -rf $notarize_dir
    abort_release "notarization of the app failed"
end
rm -rf $notarize_dir

echo "==> stapling ticket to TVMV.app"
xcrun stapler staple $app; or abort_release "stapling the app failed"
xcrun stapler validate $app; or abort_release "stapled ticket does not validate"

# Assert the end state rather than assume it: this is the check that would
# have caught every ad-hoc build this script used to ship. Note that spctl
# alone is not proof of stapling — it can pass via an online check — which is
# why stapler validate above is a separate assertion.
echo "==> verifying Gatekeeper acceptance"
if not spctl -a -t exec $app 2>/dev/null
    spctl -a -vv -t exec $app 2>&1 | sed 's/^/    /' >&2
    abort_release "Gatekeeper still rejects the app after notarization"
end
spctl -a -vv -t exec $app 2>&1 | sed 's/^/    /'

# --- Package the zip ------------------------------------------------------
# ditto preserves the code signature and the stapled ticket.
set -l zip $repo_root/dist/TVMV-$tag.zip
rm -f $zip
ditto -c -k --sequesterRsrc --keepParent $app $zip
echo "==> packaged $zip"

# --- Package the dmg ------------------------------------------------------
# Built from the already-stapled app, then notarized and stapled in its own
# right so the disk image ALSO passes Gatekeeper when opened directly.
set -l dmg $repo_root/dist/TVMV-$tag.dmg
rm -f $dmg
set -l stage (mktemp -d)/TVMV
mkdir -p $stage
# ditto, not cp -R: it preserves extended attributes and the code signature
# verbatim, so the stapled ticket makes it into the image intact.
ditto $app $stage/TVMV.app; or abort_release "staging the app for the dmg failed"
ln -s /Applications $stage/Applications  # classic drag-to-install layout
echo "==> building $dmg"
hdiutil create -volname "TVMV $ver" -srcfolder $stage -ov -format UDZO -quiet $dmg
or begin
    rm -rf (path dirname $stage)
    abort_release "hdiutil failed to build the disk image"
end
rm -rf (path dirname $stage)

# A disk image is data, not code, so it gets a plain timestamped signature —
# no hardened runtime (that flag only means something for an executable).
echo "==> signing $dmg"
codesign --sign $tvmv_identity --force --timestamp $dmg
or abort_release "signing the disk image failed"

if not tvmv_notarize $dmg
    abort_release "notarization of the disk image failed"
end
echo "==> stapling ticket to the disk image"
xcrun stapler staple $dmg; or abort_release "stapling the disk image failed"
xcrun stapler validate $dmg; or abort_release "dmg stapled ticket does not validate"
echo "==> packaged $dmg"

# --- Commit + tag ---------------------------------------------------------
git add $plist quicklook/Info.plist
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
    echo "**Disk image** — download \`TVMV-$tag.dmg\`, open it, and drag **TVMV** to Applications."
    echo
    echo "**Zip** — download \`TVMV-$tag.zip\`, unzip, and move **TVMV.app** to \`/Applications\`."
    echo
    echo "Signed with Developer ID and notarized by Apple, with the ticket stapled, so"
    echo "it launches normally on first run — no Gatekeeper warning, no right-click →"
    echo "Open, and no \`xattr\` workaround. Requires macOS 14 or later."
end > $notes_file

gh release create "$tag" $dmg $zip --title "TVMV $ver" --notes-file $notes_file
rm -f $notes_file

set -l nwo (gh repo view --json nameWithOwner -q .nameWithOwner)
echo "==> done: https://github.com/$nwo/releases/tag/$tag"
