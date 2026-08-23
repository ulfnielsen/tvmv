/*
 * editor.js — tvmv CodeMirror 6 editor pane controller.
 *
 * Event-driven bridge: keystrokes stay inside CodeMirror; the page pushes
 * debounced textChanged / cursorMoved / scrolled messages to native, and
 * native sends commands via window.tvmvEditor. See the design spec
 * (2026-07-03-codemirror-editor-design.md) for the contract.
 */
(function () {
  "use strict";

  var CMSTATE = window.CM;

  function post(msg) {
    try { window.webkit.messageHandlers.tvmvEditor.postMessage(msg); } catch (e) {}
  }

  window.onerror = function (message) {
    post({ type: "error", message: String(message) });
  };

  /* ---- debounced event reporting ---------------------------------------- */

  var TEXT_DEBOUNCE_MS = 100;
  var POS_DEBOUNCE_MS = 100;
  var textTimer = null, cursorTimer = null, scrollTimer = null;

  // Edits accumulate as a composed ChangeSet against the document as of the
  // last flush; the flush posts compact [from, to, insert] patches (UTF-16
  // offsets, ascending, non-overlapping) instead of the complete document.
  // Native rebuilds its text from them and falls back to getText() on any
  // mismatch. `suppressChanges` masks programmatic setText, which resets the
  // baseline itself.
  var pendingChanges = null;
  var suppressChanges = false;

  function flushText() {
    if (textTimer !== null) { clearTimeout(textTimer); textTimer = null; }
    if (!pendingChanges) return;
    var changes = pendingChanges;
    pendingChanges = null;
    var patches = [];
    changes.iterChanges(function (fromA, toA, fromB, toB, inserted) {
      patches.push([fromA, toA, inserted.toString()]);
    });
    if (patches.length === 0) return;
    post({ type: "textPatch", patches: patches, length: view.state.doc.length });
  }

  function queueText() {
    if (textTimer !== null) clearTimeout(textTimer);
    textTimer = setTimeout(flushText, TEXT_DEBOUNCE_MS);
  }

  function queueCursor() {
    if (cursorTimer !== null) clearTimeout(cursorTimer);
    cursorTimer = setTimeout(function () {
      cursorTimer = null;
      var head = view.state.selection.main.head;
      var line = view.state.doc.lineAt(head).number;
      post({ type: "cursorMoved", line: line, offset: head });
    }, POS_DEBOUNCE_MS);
  }

  function queueScroll() {
    if (scrollTimer !== null) clearTimeout(scrollTimer);
    scrollTimer = setTimeout(function () {
      scrollTimer = null;
      var block = view.lineBlockAtHeight(view.scrollDOM.scrollTop);
      var line = view.state.doc.lineAt(block.from).number;
      post({ type: "scrolled", topLine: line });
    }, POS_DEBOUNCE_MS);
  }

  /* ---- editor construction ---------------------------------------------- */

  var themeCompartment = new CMSTATE.Compartment();

  function extensions() {
    return [
      // CodeMirror disables system text services by default — desktop editor
      // behavior. On touch devices (phone/tablet keyboards) prose editing
      // wants autocorrect, auto-capitalization, and the spell underline.
      CMSTATE.EditorView.contentAttributes.of(
        (navigator.maxTouchPoints > 0)
          ? { autocorrect: "on", autocapitalize: "sentences", spellcheck: "true" }
          : {}
      ),
      CMSTATE.history(),
      CMSTATE.drawSelection(),
      CMSTATE.highlightActiveLine(),
      CMSTATE.EditorView.lineWrapping,               // prose style: soft wrap
      CMSTATE.markdown({ codeLanguages: CMSTATE.languages }),
      CMSTATE.syntaxHighlighting(CMSTATE.defaultHighlightStyle, { fallback: true }),
      CMSTATE.keymap.of(CMSTATE.defaultKeymap.concat(CMSTATE.historyKeymap)),
      themeCompartment.of([]),                       // light: bare; dark: oneDark
      CMSTATE.EditorView.updateListener.of(function (update) {
        if (update.docChanged) {
          if (!suppressChanges) {
            pendingChanges = pendingChanges
              ? pendingChanges.compose(update.changes)
              : update.changes;
            queueText();
          }
          queueCursor();
        } else if (update.selectionSet) { queueCursor(); }
      }),
    ];
  }

  var view = new CMSTATE.EditorView({
    state: CMSTATE.EditorState.create({ doc: "", extensions: extensions() }),
    parent: document.getElementById("editor"),
  });

  view.scrollDOM.addEventListener("scroll", queueScroll);
  // Flush pending keystrokes the moment focus leaves the editor, so native
  // state is authoritative before any click/menu action can act on it.
  view.contentDOM.addEventListener("blur", flushText);

  /* ---- native command surface ------------------------------------------- */

  function clampOffset(offset) {
    return Math.max(0, Math.min(Number(offset) || 0, view.state.doc.length));
  }

  function clampLine(line) {
    return Math.max(1, Math.min(Number(line) || 1, view.state.doc.lines));
  }

  function setText(text, resetHistory) {
    // Programmatic replacement: native already holds this text, so pending
    // user edits against the OLD document are moot and must not be flushed
    // (their coordinates no longer mean anything), and the replacement itself
    // must not echo back as a patch.
    if (textTimer !== null) { clearTimeout(textTimer); textTimer = null; }
    pendingChanges = null;
    suppressChanges = true;
    try {
      if (resetHistory) {
        // Fresh state: replaced text (external reload / discard) must not be
        // resurrectable via undo.
        view.setState(CMSTATE.EditorState.create({ doc: text, extensions: extensions() }));
        applyStyle(_lastStyle); // recreate loses the theme compartment's config
      } else {
        var sel = clampOffset(view.state.selection.main.head);
        view.dispatch({
          changes: { from: 0, to: view.state.doc.length, insert: text },
          selection: { anchor: Math.min(sel, text.length) },
        });
      }
    } finally {
      suppressChanges = false;
    }
  }

  function scrollToLine(line, placeCursor) {
    var pos = view.state.doc.line(clampLine(line)).from;
    var spec = { effects: CMSTATE.EditorView.scrollIntoView(pos, { y: "start", yMargin: 8 }) };
    if (placeCursor) spec.selection = { anchor: pos };
    view.dispatch(spec);
  }

  function restore(cursorOffset, topLine) {
    view.dispatch({ selection: { anchor: clampOffset(cursorOffset) } });
    var pos = view.state.doc.line(clampLine(topLine)).from;
    view.dispatch({ effects: CMSTATE.EditorView.scrollIntoView(pos, { y: "start", yMargin: 8 }) });
  }

  function getText() {
    // A full pull hands native the authoritative document INCLUDING edits
    // still pending in the composed set — so the patch baseline resets here,
    // or those edits would later arrive as patches against an already-updated
    // base.
    if (textTimer !== null) { clearTimeout(textTimer); textTimer = null; }
    pendingChanges = null;
    return view.state.doc.toString();
  }

  var _lastStyle = null;

  function applyStyle(json) {
    if (json == null) return;
    var cfg = (typeof json === "string") ? JSON.parse(json) : json;
    _lastStyle = cfg;
    var rootStyle = document.documentElement.style;
    if (cfg.monoFont != null) {
      rootStyle.setProperty("--tvmv-editor-mono", JSON.stringify(cfg.monoFont) + ", monospace");
    }
    if (cfg.baseSize != null) {
      rootStyle.setProperty("--tvmv-editor-size", cfg.baseSize + "px");
    }
    if (cfg.theme === "dark" || cfg.theme === "light") {
      view.dispatch({
        effects: themeCompartment.reconfigure(cfg.theme === "dark" ? CMSTATE.oneDark : []),
      });
    }
  }

  function focusEditor() {
    view.focus();
  }

  window.tvmvEditor = {
    setText: setText,
    scrollToLine: scrollToLine,
    restore: restore,
    getText: getText,
    applyStyle: applyStyle,
    focusEditor: focusEditor,
    _view: view,   // debug/test hook: lets harnesses dispatch real transactions
  };

  post({ type: "ready" });
})();
