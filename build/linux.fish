#!/usr/bin/env fish
#
# linux.fish — build and install TVMV natively.
#
#   fish build/linux.fish [install]     build + install       (default)
#   fish build/linux.fish uninstall     remove everything it installed
#   fish build/linux.fish build         build only
#
# Env: PREFIX (default /usr/local)
#
# A native install is the primary distribution path. It is measurably better
# than the Flatpak on at least one real machine (60 fps at ~0% CPU vs 41 fps and
# 3-4.5 cores), and Flatpak apps pick up the runtime's theming rather than the
# desktop's — the cursor theme is the visible one.
#
# Deliberately NOT bundle.fish: that builds the macOS app. This refuses to run
# anywhere but Linux so the two can never be confused.

set -l action $argv[1]
test -z "$action"; and set action install

if test (uname) != Linux
    echo "error: this is the Linux installer; macOS uses build/bundle.fish" >&2
    exit 1
end

set -l repo (realpath (dirname (status --current-filename))/..)
set -l prefix (test -n "$PREFIX"; and echo $PREFIX; or echo /usr/local)
set -l bindir  $prefix/bin
set -l datadir $prefix/share
set -l appdir  $datadir/applications
set -l icondir $datadir/icons/hicolor
set -l metadir $datadir/metainfo
set -l webdir  $datadir/tvmv/web
set -l apparmor /etc/apparmor.d/tvmv

# The shared web layer: /web after the Task 1 promotion, the SwiftPM resource
# directory before it.
set -l websrc $repo/web
test -f $websrc/boot.js; or set websrc $repo/Sources/TVMVCore/Resources/web

# Root only where it is actually needed, so a PREFIX under $HOME needs none.
# The prefix may not exist yet, so test the nearest ancestor that does.
set -l probe $prefix
while not test -e $probe
    set probe (dirname $probe)
end
# A function rather than a variable prefix: an empty variable expands to nothing
# ("The expanded command was empty") and `command` swallows flags like -Dm755 as
# its own options.
if test -w $probe
    function asroot; $argv; end
else
    function asroot; sudo $argv; end
end

function step; echo "  "$argv; end

switch $action
    case build install
        echo "==> building"
        cargo build --release --manifest-path $repo/linux/Cargo.toml; or exit 1
        step "linux/target/release/tvmv"
        test "$action" = build; and exit 0

    case uninstall
    case '*'
        echo "usage: linux.fish [build|install|uninstall]" >&2
        exit 1
end

switch $action
    case install
        echo "==> installing to $prefix"
        asroot install -Dm755 $repo/linux/target/release/tvmv $bindir/tvmv
        step "$bindir/tvmv"

        # Assets are found relative to the executable ($bin/../share/tvmv/web).
        asroot rm -rf $webdir
        asroot mkdir -p (dirname $webdir)
        asroot cp -r $websrc $webdir
        step "$webdir"

        asroot install -Dm644 $repo/linux/data/dk.dyregod.tvmv.desktop \
            $appdir/dk.dyregod.tvmv.desktop
        step "$appdir/dk.dyregod.tvmv.desktop"

        # AppStream metadata, so GNOME Software and Discover can describe the
        # app rather than showing a bare desktop entry.
        asroot install -Dm644 $repo/linux/data/dk.dyregod.tvmv.metainfo.xml \
            $metadir/dk.dyregod.tvmv.metainfo.xml
        step "$metadir/dk.dyregod.tvmv.metainfo.xml"

        for size in 16 24 32 48 64 128 256 512
            set -l png $repo/linux/data/icons/hicolor/{$size}x{$size}/apps/dk.dyregod.tvmv.png
            test -f $png; and asroot install -Dm644 $png \
                $icondir/{$size}x{$size}/apps/dk.dyregod.tvmv.png
        end
        step "$icondir/*/apps/dk.dyregod.tvmv.png"

        # Without this, Ubuntu 24.04 denies the user namespace bubblewrap needs
        # and WebKit cannot sandbox its web processes. The app still runs (it
        # detects this and falls back with a warning), but unconfined.
        if test -d /etc/apparmor.d
            sudo install -Dm644 $repo/linux/data/apparmor/tvmv $apparmor
            and sudo apparmor_parser -r $apparmor 2>/dev/null
            and step "$apparmor (WebKit sandbox enabled)"
            or step "$apparmor — could not load; app will run unsandboxed"
        end

        # Thumbnailer: one file registers with the shared freedesktop spec,
        # which covers Nautilus, Nemo, Caja, PCManFM and Thunar (via tumbler).
        asroot install -Dm644 $repo/linux/data/tvmv.thumbnailer \
            $datadir/thumbnailers/tvmv.thumbnailer
        step "$datadir/thumbnailers/tvmv.thumbnailer"

        # Context menu, into whichever file managers are actually present. A
        # soft dependency: absent bindings just mean no menu entry.
        for fm in nautilus nemo caja
            set -l extdir $HOME/.local/share/$fm-python/extensions
            if test -d $HOME/.local/share/$fm-python; or test -d /usr/share/$fm-python
                mkdir -p $extdir
                install -Dm644 $repo/linux/data/extensions/tvmv-preview.py \
                    $extdir/tvmv-preview.py
                step "$extdir/tvmv-preview.py"
            end
        end

        command -q update-desktop-database; and asroot update-desktop-database -q $appdir 2>/dev/null
        command -q gtk4-update-icon-cache; and asroot gtk4-update-icon-cache -qtf $icondir 2>/dev/null
        command -q xdg-mime; and xdg-mime default dk.dyregod.tvmv.desktop text/markdown 2>/dev/null

        # The default body font is the Mac's, and no Ubuntu package provides it,
        # so most Linux installs quietly fall back to the generic serif and the
        # reading theme looks subtly off. Say so once, here, rather than leaving
        # it to be noticed.
        if command -q fc-list
            set -l found (fc-list : family 2>/dev/null | grep -ci "source serif")
            if test "$found" -eq 0
                echo "  note: the default body font 'Source Serif 4' is not installed, so"
                echo "        text falls back to the generic serif. Install it (SIL OFL,"
                echo "        from Adobe's Source Serif releases) for the intended look,"
                echo "        or choose another body font in settings (Ctrl+,)."
            end
        end

        echo "==> done. `tvmv file.md`, or open a .md from Files."

    case uninstall
        echo "==> removing from $prefix"
        for path in $bindir/tvmv $appdir/dk.dyregod.tvmv.desktop \
                    $metadir/dk.dyregod.tvmv.metainfo.xml
            test -e $path; and asroot rm -f $path; and step "removed $path"
        end
        test -d $webdir; and asroot rm -rf (dirname $webdir); and step "removed $webdir"
        set -l thumb $datadir/thumbnailers/tvmv.thumbnailer
        test -e $thumb; and asroot rm -f $thumb; and step "removed $thumb"
        for fm in nautilus nemo caja
            set -l ext $HOME/.local/share/$fm-python/extensions/tvmv-preview.py
            test -e $ext; and rm -f $ext; and step "removed $ext"
        end
        for size in 16 24 32 48 64 128 256 512
            asroot rm -f $icondir/{$size}x{$size}/apps/dk.dyregod.tvmv.png
        end
        step "removed icons"
        if test -e $apparmor
            sudo apparmor_parser -R $apparmor 2>/dev/null
            sudo rm -f $apparmor; and step "removed $apparmor"
        end
        command -q update-desktop-database; and asroot update-desktop-database -q $appdir 2>/dev/null
        command -q gtk4-update-icon-cache; and asroot gtk4-update-icon-cache -qtf $icondir 2>/dev/null
        echo "==> done."
end
