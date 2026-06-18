#!/usr/bin/env fish
#
# quicklook.fish — build the TVMV QuickLook preview app-extension (.appex) and
# embed it into dist/TVMV.app/Contents/PlugIns/.
#
# The extension renders Markdown through TVMV's existing pipeline:
#   MarkdownText.decode -> renderHTML (cmark-gfm) -> WKWebView + bundled web/.
#
# Standalone-runnable, but normally invoked by bundle.fish BEFORE the final
# app codesign so the app signature seals the embedded extension.
#
# Requires: env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
#
# Run from anywhere; paths resolve relative to the repo root.

set -l fail_status 1

set -l script_dir (path resolve (status filename) | path dirname)
set -l repo_root (path resolve $script_dir/..)
cd $repo_root; or exit $fail_status

echo "==> [QL] repo root: $repo_root"

# --- 1. Release build (produces cmark .o objects + the renderer sources) ----
echo "==> [QL] swift build -c release"
swift build -c release; or exit $fail_status

set -l rel .build/arm64-apple-macosx/release

# --- 2. Archive cmark objects into a static lib ----------------------------
set -l cmark_objs $rel/cmark_gfm.build/*.o $rel/cmark_gfm_extensions.build/*.o
set -l libcmark $rel/libcmark.a
echo "==> [QL] ar rcs libcmark.a ("(count $cmark_objs)" objects)"
rm -f $libcmark
ar rcs $libcmark $cmark_objs; or exit $fail_status

# --- 3. Locate cmark headers / module maps ---------------------------------
set -l src_inc .build/checkouts/swift-cmark/src/include
set -l ext_inc .build/checkouts/swift-cmark/extensions/include
for d in $src_inc $ext_inc
    if not test -f $d/module.modulemap
        echo "ERROR: missing module.modulemap in $d" >&2
        exit $fail_status
    end
end

# --- 4. Compile the extension executable -----------------------------------
# Sources: the QL controller + scheme handler, plus the reused renderer files.
set -l ql_src \
    quicklook/PreviewViewController.swift \
    quicklook/PreviewAssetSchemeHandler.swift \
    Sources/tvmv/MarkdownRenderer.swift \
    Sources/tvmv/MarkdownText.swift

set -l build_dir .build/quicklook
rm -rf $build_dir
mkdir -p $build_dir
set -l exe $build_dir/TVMVQuickLook

echo "==> [QL] swiftc compile extension executable"
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swiftc \
    -O \
    -target arm64-apple-macosx14.0 \
    -Xcc -fmodule-map-file=$src_inc/module.modulemap \
    -Xcc -fmodule-map-file=$ext_inc/module.modulemap \
    -I $src_inc \
    -I $ext_inc \
    -framework Cocoa \
    -framework WebKit \
    -framework QuickLookUI \
    -Xlinker -e -Xlinker _NSExtensionMain \
    $libcmark \
    -o $exe \
    $ql_src; or exit $fail_status
echo "    compiled -> $exe"

# --- 5. Assemble the .appex bundle -----------------------------------------
set -l appex $repo_root/dist/TVMVQuickLook.appex
echo "==> [QL] assembling $appex"
rm -rf $appex
mkdir -p $appex/Contents/MacOS
mkdir -p $appex/Contents/Resources

cp $exe $appex/Contents/MacOS/TVMVQuickLook
cp quicklook/Info.plist $appex/Contents/Info.plist

# Bundled web assets -> Contents/Resources/web (Bundle(for:).resourceURL/web).
cp -R Sources/tvmv/Resources/web $appex/Contents/Resources/web
echo "    copied web/ -> Contents/Resources/web"

# --- 6. Sign the appex with the sandbox entitlement (inside-out) ------------
echo "==> [QL] codesign appex (ad-hoc, sandbox entitlement)"
codesign -s - --force --entitlements quicklook/entitlements.plist $appex; or exit $fail_status
codesign -d --entitlements - $appex 2>/dev/null | grep -q app-sandbox; \
    and echo "    sandbox entitlement present"; \
    or echo "    WARNING: sandbox entitlement not detected"

# --- 7. Embed into the app's PlugIns dir -----------------------------------
set -l app $repo_root/dist/TVMV.app
if not test -d $app
    echo "ERROR: dist/TVMV.app not found; run bundle.fish first" >&2
    exit $fail_status
end
mkdir -p $app/Contents/PlugIns
rm -rf $app/Contents/PlugIns/TVMVQuickLook.appex
cp -R $appex $app/Contents/PlugIns/TVMVQuickLook.appex
echo "==> [QL] embedded preview appex -> $app/Contents/PlugIns/"

# === SECOND APPEX: QuickLook Thumbnail provider ============================
# Renders a page-overview thumbnail (document scaled to fit thumbnail width)
# rather than the zoomed-in heading the preview-derived auto thumbnail gives.

# --- T1. Compile the thumbnail extension executable ------------------------
# Sources: the thumbnail provider + scheme handler + reused renderer files.
set -l thumb_src \
    quicklook/ThumbnailProvider.swift \
    quicklook/PreviewAssetSchemeHandler.swift \
    Sources/tvmv/MarkdownRenderer.swift \
    Sources/tvmv/MarkdownText.swift

set -l thumb_build_dir .build/quicklook-thumbnail
rm -rf $thumb_build_dir
mkdir -p $thumb_build_dir
set -l thumb_exe $thumb_build_dir/TVMVThumbnail

echo "==> [QL] swiftc compile thumbnail extension executable"
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swiftc \
    -O \
    -target arm64-apple-macosx14.0 \
    -Xcc -fmodule-map-file=$src_inc/module.modulemap \
    -Xcc -fmodule-map-file=$ext_inc/module.modulemap \
    -I $src_inc \
    -I $ext_inc \
    -framework Cocoa \
    -framework WebKit \
    -framework QuickLookThumbnailing \
    -Xlinker -e -Xlinker _NSExtensionMain \
    $libcmark \
    -o $thumb_exe \
    $thumb_src; or exit $fail_status
echo "    compiled -> $thumb_exe"

# --- T2. Assemble the thumbnail .appex bundle ------------------------------
set -l thumb_appex $repo_root/dist/TVMVThumbnail.appex
echo "==> [QL] assembling $thumb_appex"
rm -rf $thumb_appex
mkdir -p $thumb_appex/Contents/MacOS
mkdir -p $thumb_appex/Contents/Resources

cp $thumb_exe $thumb_appex/Contents/MacOS/TVMVThumbnail
cp quicklook/Thumbnail-Info.plist $thumb_appex/Contents/Info.plist
cp -R Sources/tvmv/Resources/web $thumb_appex/Contents/Resources/web
echo "    copied web/ -> Contents/Resources/web"

# --- T3. Sign the thumbnail appex with the sandbox entitlement -------------
echo "==> [QL] codesign thumbnail appex (ad-hoc, sandbox entitlement)"
codesign -s - --force --entitlements quicklook/entitlements.plist $thumb_appex; or exit $fail_status
codesign -d --entitlements - $thumb_appex 2>/dev/null | grep -q app-sandbox; \
    and echo "    sandbox entitlement present"; \
    or echo "    WARNING: sandbox entitlement not detected"

# --- T4. Embed the thumbnail appex into the app's PlugIns dir --------------
rm -rf $app/Contents/PlugIns/TVMVThumbnail.appex
cp -R $thumb_appex $app/Contents/PlugIns/TVMVThumbnail.appex
echo "==> [QL] embedded thumbnail appex -> $app/Contents/PlugIns/"

echo "==> [QL] done."
