#!/usr/bin/env fish
#
# editor-bundle.fish — build the vendored CodeMirror 6 bundle for the editor
# pane. The output is COMMITTED (Sources/TVMVCore/Resources/web/vendor/codemirror/
# codemirror.bundle.js) so normal builds never need npm; run this only to
# upgrade CodeMirror.
#
# Requires: node + npm (verified with Node v26).
#
# Note: --inlineDynamicImports is required — @codemirror/language-data lazy-
# loads languages via dynamic import(), which IIFE output cannot code-split.

set -l script_dir (cd (dirname (status --current-filename)); pwd)
set -l repo_root (dirname $script_dir)
set -l out_dir "$repo_root/Sources/TVMVCore/Resources/web/vendor/codemirror"
set -l work (mktemp -d)

echo "==> building CodeMirror bundle in $work"
cd $work; or exit 1

npm init -y >/dev/null 2>&1

# Pinned versions — verified building cleanly together on 2026-07-03.
npm install --no-audit --no-fund --silent \
    codemirror@6.0.2 \
    @codemirror/lang-markdown@6.5.0 \
    @codemirror/language-data@6.5.2 \
    @codemirror/theme-one-dark@6 \
    rollup@4.62.2 \
    @rollup/plugin-node-resolve@16.0.3 \
    @rollup/plugin-terser@1.0.0
or begin; echo "npm install failed" >&2; exit 1; end

printf '%s\n' '
// tvmv editor bundle entry: expose the CodeMirror 6 pieces editor.js needs
// on window.CM, as a single vendored IIFE.
import { EditorView, keymap, drawSelection, highlightActiveLine } from "@codemirror/view";
import { EditorState, Compartment } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, undo, redo } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { languages } from "@codemirror/language-data";
import { syntaxHighlighting, defaultHighlightStyle } from "@codemirror/language";
import { oneDark } from "@codemirror/theme-one-dark";

window.CM = {
  EditorView, EditorState, Compartment, keymap, drawSelection, highlightActiveLine,
  defaultKeymap, history, historyKeymap, undo, redo,
  markdown, languages, syntaxHighlighting, defaultHighlightStyle, oneDark,
};' > entry.js

npx rollup entry.js --format iife --inlineDynamicImports \
    --plugin @rollup/plugin-node-resolve --plugin @rollup/plugin-terser \
    --file codemirror.bundle.js
or begin; echo "rollup failed" >&2; exit 1; end

# Smoke test: the bundle must define window.CM with the expected surface.
node -e '
global.window = {};
require("./codemirror.bundle.js");
const need = ["EditorView","EditorState","Compartment","keymap","drawSelection",
  "highlightActiveLine","defaultKeymap","history","historyKeymap","undo","redo",
  "markdown","languages","syntaxHighlighting","defaultHighlightStyle","oneDark"];
const missing = need.filter(k => !(k in global.window.CM));
if (missing.length) { console.error("missing:", missing.join(",")); process.exit(1); }
console.log("window.CM ok:", need.length, "exports");'
or begin; echo "bundle smoke test failed" >&2; exit 1; end

mkdir -p $out_dir
cp codemirror.bundle.js $out_dir/
echo "==> wrote $out_dir/codemirror.bundle.js ("(du -h $out_dir/codemirror.bundle.js | cut -f1)")"
echo "==> resolved versions:"
node -e 'const l=require("./package-lock.json");
for (const n of ["codemirror","@codemirror/lang-markdown","@codemirror/language-data","@codemirror/theme-one-dark"])
  console.log("   ", n, l.packages["node_modules/"+n].version)'
rm -rf $work
