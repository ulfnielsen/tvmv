"""Adds "Preview with TVMV" to the file-manager context menu.

Works in Nautilus, Nemo and Caja: all three expose the same MenuProvider
interface through their Python bindings, so one file serves all of them.

Why a menu and not a preview pane: GNOME Sushi's viewers are compiled into
`.gresource` bundles with no plugin directory (verified on this machine:
/usr/share/sushi contains only gresource files), and modern Nautilus has no
third-party preview-pane API. The menu is the supported extension point.

Install to whichever of these exist:
    ~/.local/share/{nautilus,nemo,caja}-python/extensions/

Requires python3-nautilus (or the nemo/caja equivalent). This is a *soft*
dependency — TVMV installs and works without it; only the menu entry is missing.
"""

import subprocess

from gi.repository import GObject

# Each file manager provides its own binding module under a different name.
_menu_provider = None
for module_name in ("Nautilus", "Nemo", "Caja"):
    try:
        import importlib

        module = importlib.import_module(f"gi.repository.{module_name}")
        _menu_provider = (module.MenuProvider, module.MenuItem)
        break
    except (ImportError, ValueError):
        continue

if _menu_provider is None:  # pragma: no cover - depends on the host
    raise ImportError("no supported file-manager Python bindings found")

MenuProvider, MenuItem = _menu_provider

MARKDOWN_TYPES = {"text/markdown", "text/x-markdown"}
MARKDOWN_SUFFIXES = (".md", ".markdown", ".mdown", ".mkd")


class TvmvPreviewExtension(GObject.GObject, MenuProvider):
    """Offers a preview action for markdown files."""

    def _is_markdown(self, item):
        if item.get_uri_scheme() != "file" or item.is_directory():
            return False
        if item.get_mime_type() in MARKDOWN_TYPES:
            return True
        # Some file managers report text/plain for .md; fall back to the suffix
        # rather than losing the menu entry on those.
        return item.get_name().lower().endswith(MARKDOWN_SUFFIXES)

    def _preview(self, _menu, files):
        for item in files:
            path = item.get_location().get_path()
            if path:
                # --peek reuses a running instance, so this is near-instant.
                subprocess.Popen(["tvmv", "--peek", path])

    def get_file_items(self, *args):
        # The signature gained/lost a `window` argument across versions; the
        # file list is always last.
        files = args[-1]
        markdown = [f for f in files if self._is_markdown(f)]
        if not markdown:
            return []

        item = MenuItem(
            name="TvmvPreviewExtension::preview",
            label="Preview with TVMV",
            tip="Open a quick preview window",
        )
        item.connect("activate", self._preview, markdown)
        return [item]

    def get_background_items(self, *args):
        return []
