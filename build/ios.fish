#!/usr/bin/env fish
# Generate the Xcode project and build (optionally install+launch) the iOS app.
#   fish build/ios.fish            build for iPad simulator
#   fish build/ios.fish run        also install + launch in the simulator
set -l repo_root (path resolve (dirname (status filename))/..)
set -lx DEVELOPER_DIR /Applications/Xcode.app/Contents/Developer
set -l dest 'platform=iOS Simulator,name=iPad Air 13-inch (M4)'

cd $repo_root/ios
xcodegen generate; or exit 1
xcodebuild -project TVMV.xcodeproj -scheme TVMV \
    -destination $dest -configuration Debug build; or exit 1

if test "$argv[1]" = run
    set -l bin (xcodebuild -project TVMV.xcodeproj -scheme TVMV \
        -destination $dest -configuration Debug -showBuildSettings 2>/dev/null \
        | awk '/ TARGET_BUILD_DIR /{print $3}')
    set -l udid (xcrun simctl list devices available \
        | grep 'iPad Air 13-inch (M4)' | head -1 \
        | string match -r '[0-9A-F-]{36}')
    xcrun simctl bootstatus $udid -b
    xcrun simctl install $udid $bin/TVMV.app; or exit 1
    xcrun simctl launch $udid dk.dyregod.tvmv.ios
end
