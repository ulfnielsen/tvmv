# KDE thumbnail plugin

Dolphin does not read freedesktop `.thumbnailer` files; it needs a KIO plugin.
Worth having, because on KDE one plugin serves **two** surfaces: grid thumbnails
*and* the Information Panel's large preview, which is the closest KDE has to
QuickLook.

It links the C ABI in `linux/include/tvmv_card.h`, so it draws the **same card**
as the freedesktop thumbnailer rather than reimplementing it — a `.md` looks
identical in Files, Dolphin and Thunar.

## Status

**Not built or tested here.** The development machine has neither `cmake` nor
KDE development packages, and installing them needs root. The C ABI it depends
on *is* built and tested (`linux/src/capi.rs`, exercised from C — see
`tvmv_card_render_png`); this directory is the C++ shim around it.

Treat it as unverified until someone builds it on a KDE system.

## Building

Ubuntu 24.04 ships KF5 only — `libkf6kio-dev` is not in its archive — so the
framework version has to be detected rather than assumed. KF5 uses
`ThumbCreator`; KF6 uses `KIO::ThumbnailCreator`.

```sh
sudo apt install cmake extra-cmake-modules libkf5kio-dev
cargo build --release --manifest-path ../Cargo.toml   # produces libtvmv.so
cmake -B build -S . && cmake --build build
sudo cmake --install build
```

Then restart Dolphin and enable the preview for Markdown files under
**Configure Dolphin → General → Previews**.
