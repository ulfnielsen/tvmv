/*
 * boot.js — tvmv WKWebView controller.
 *
 * Responsibilities:
 *   render(bodyHTML, docBaseHref)  inject HTML, slug headings, build outline,
 *                                  lazily enrich (hljs / KaTeX / Mermaid).
 *   applyStyle(json)               live-tune typography + theme, no re-parse.
 *   scrollToAnchor / getScrollRatio / setScrollRatio  navigation helpers.
 *
 * Heavy vendor assets (highlight.js, KaTeX, Mermaid) are NOT in template.html.
 * They are injected from tvmv-asset://app/vendor/... only when a document
 * actually contains code / math / diagrams, so simple docs stay light.
 *
 * Note on innerHTML: bodyHTML is produced by the app's own cmark-gfm pipeline
 * (default options => raw inline HTML is escaped, not passed through), so it is
 * trusted, first-party content for this offline document viewer.
 */
(function () {
  "use strict";

  var ASSET_BASE = "tvmv-asset://app/vendor/";

  /* ---- native bridge ---------------------------------------------------- */

  function post(msg) {
    try {
      window.webkit.messageHandlers.tvmv.postMessage(msg);
    } catch (e) {
      // No bridge (e.g. plain-browser preview); ignore.
    }
  }

  function postError(message) {
    post({ type: "error", message: String(message) });
  }

  /* ---- lazy asset injection -------------------------------------------- */
  // Each loader resolves a cached promise so repeated renders never re-inject.

  var _loaded = Object.create(null);

  function loadScript(relPath) {
    var url = ASSET_BASE + relPath;
    if (_loaded[url]) return _loaded[url];
    _loaded[url] = new Promise(function (resolve, reject) {
      var s = document.createElement("script");
      s.src = url;
      s.async = false; // preserve execution order when chained
      s.onload = function () { resolve(); };
      s.onerror = function () { reject(new Error("Failed to load script: " + url)); };
      document.head.appendChild(s);
    });
    return _loaded[url];
  }

  function loadStyle(relPath) {
    var url = ASSET_BASE + relPath;
    if (_loaded[url]) return _loaded[url];
    _loaded[url] = new Promise(function (resolve, reject) {
      var l = document.createElement("link");
      l.rel = "stylesheet";
      l.href = url;
      l.onload = function () { resolve(); };
      l.onerror = function () { reject(new Error("Failed to load style: " + url)); };
      document.head.appendChild(l);
    });
    return _loaded[url];
  }

  /* ---- GitHub heading-slug algorithm ----------------------------------- */
  // Verified to match github-slugger: lowercase; strip punctuation EXCEPT
  // hyphen and underscore; spaces -> hyphens; collapse repeated hyphens;
  // dedupe with -1/-2 (first duplicate of "foo" becomes "foo-1").

  // Strip everything that is not a unicode letter/number/mark, underscore,
  // hyphen, or space. Built via RegExp so the source survives tooling.
  var SLUG_STRIP = new RegExp("[^\\p{L}\\p{N}\\p{M}_\\- ]", "gu");

  function makeSlugger() {
    var seen = Object.create(null);

    function base(text) {
      return text
        .toLowerCase()
        .replace(SLUG_STRIP, "") // strip punctuation except _ and -
        .replace(/ /g, "-")      // spaces -> hyphens
        .replace(/-+/g, "-");    // collapse repeats
    }

    return function slug(text) {
      var s = base(text);
      if (s in seen) {
        var n = seen[s] + 1;
        var candidate;
        do {
          candidate = s + "-" + n;
          n++;
        } while (candidate in seen);
        seen[s] = n - 1;     // remember how far we counted for base s
        seen[candidate] = 0; // the deduped slug is itself now taken
        return candidate;
      }
      seen[s] = 0;
      return s;
    };
  }

  /* ---- outline + slugging ---------------------------------------------- */

  function assignSlugsAndBuildOutline(root) {
    var slug = makeSlugger();
    var headings = root.querySelectorAll("h1, h2, h3, h4, h5, h6");
    var items = [];
    for (var i = 0; i < headings.length; i++) {
      var h = headings[i];
      var title = (h.textContent || "").trim();
      var anchor = slug(title);
      h.id = anchor;
      items.push({
        level: parseInt(h.tagName.charAt(1), 10),
        title: title,
        anchor: anchor
      });
    }
    return items;
  }

  /* ---- enrichment passes ----------------------------------------------- */

  // Convert cmark-gfm mermaid output (<pre><code class="language-mermaid">)
  // into <div class="mermaid">{decoded text}</div>. Returns the new nodes.
  function convertMermaidBlocks(root) {
    var nodes = [];
    var codes = root.querySelectorAll("pre code.language-mermaid");
    for (var i = 0; i < codes.length; i++) {
      var code = codes[i];
      var pre = code.closest("pre");
      // textContent decodes HTML entities for us -> raw mermaid source.
      var src = code.textContent;
      var div = document.createElement("div");
      div.className = "mermaid";
      div.textContent = src;
      // Carry the source mapping over so editor/preview sync (scroll, click)
      // still sees the diagram block after the <pre> is replaced.
      var sp = pre ? pre.getAttribute("data-sourcepos") : null;
      if (sp) div.setAttribute("data-sourcepos", sp);
      if (pre && pre.parentNode) {
        pre.parentNode.replaceChild(div, pre);
      }
      nodes.push(div);
    }
    return nodes;
  }

  // Highlighting is bounded (the design contract: enrichment must not scale
  // unbounded with document size). Oversized blocks and blocks past the count
  // cap stay plain — still styled as code by app.css, just untokenized.
  var HIGHLIGHT_MAX_BLOCK_CHARS = 50000;
  var HIGHLIGHT_MAX_BLOCKS = 200;

  function highlightCode(root) {
    // Every `pre code` EXCEPT mermaid ones (already converted away above, but
    // guard anyway in case conversion order ever changes).
    var blocks = root.querySelectorAll("pre code");
    var targets = [];
    for (var i = 0; i < blocks.length; i++) {
      var el = blocks[i];
      if (el.classList.contains("language-mermaid")) continue;
      if ((el.textContent || "").length > HIGHLIGHT_MAX_BLOCK_CHARS) continue;
      targets.push(el);
      if (targets.length >= HIGHLIGHT_MAX_BLOCKS) break;
    }
    if (targets.length === 0) return Promise.resolve();

    // Token colors come from app.css (Concordat palette) — no external theme.
    return loadScript("highlight.js/highlight.min.js").then(function () {
      for (var j = 0; j < targets.length; j++) {
        try { window.hljs.highlightElement(targets[j]); } catch (e) { /* per-block */ }
      }
    });
  }

  function renderMath(root) {
    var text = root.textContent || "";
    if (text.indexOf("$") === -1) return Promise.resolve();

    return Promise.all([
      loadStyle("katex/katex.min.css"),
      loadScript("katex/katex.min.js")
    ]).then(function () {
      return loadScript("katex/contrib/auto-render.min.js");
    }).then(function () {
      // DEFAULT auto-render delimiters do NOT include single-$ inline, so we
      // pass the full set explicitly. throwOnError:false keeps bad math inline.
      // Default ignoredTags (script/noscript/style/textarea/pre/code/option)
      // are relied upon so fenced/inline code never collide with math.
      window.renderMathInElement(root, {
        delimiters: [
          { left: "$$", right: "$$", display: true },
          { left: "$", right: "$", display: false },
          { left: "\\(", right: "\\)", display: false },
          { left: "\\[", right: "\\]", display: true }
        ],
        throwOnError: false
      });
    });
  }

  function renderMermaid(root, mermaidNodes) {
    if (!mermaidNodes || mermaidNodes.length === 0) return Promise.resolve();

    return loadScript("mermaid/mermaid.min.js").then(function () {
      var theme = (document.documentElement.getAttribute("data-theme") === "dark")
        ? "dark" : "neutral";
      // UMD bundle assigns globalThis.mermaid -> window.mermaid is available.
      window.mermaid.initialize({ startOnLoad: false, theme: theme });
      return window.mermaid.run({ nodes: mermaidNodes });
    });
  }

  /* ---- public: render -------------------------------------------------- */

  // Monotonic render generation. Each render bumps it; the async enrichment
  // chain re-checks between stages so a superseded render stops doing work on
  // (and stops retaining) a DOM that innerHTML already replaced.
  var _renderGen = 0;

  function render(bodyHTML, docBaseHref) {
    var gen = ++_renderGen;
    try {
      // Optional <base> so relative image/link hrefs resolve against the doc.
      if (docBaseHref) {
        var base = document.head.querySelector("base");
        if (!base) {
          base = document.createElement("base");
          document.head.appendChild(base);
        }
        base.setAttribute("href", docBaseHref);
      }

      var content = document.getElementById("content");
      content.innerHTML = bodyHTML; // trusted first-party cmark-gfm output
      clearFind(); // drop stale find ranges/highlights from the previous document

      // 1. slugs + outline (synchronous, before KaTeX mutates heading text).
      var items = assignSlugsAndBuildOutline(content);
      post({ type: "outline", items: items });

      // 2. convert mermaid fences up front (changes the DOM the later passes
      //    scan; also keeps $-detection from seeing diagram source).
      var mermaidNodes = convertMermaidBlocks(content);

      // 2b. index sourcepos blocks now that the block set is final (mermaid
      //     conversion replaced its <pre> nodes; enrichment below only
      //     mutates within blocks).
      _buildLineIndex(content);

      // 3. lazy enrichment in a safe order: highlight remaining code, then
      //    KaTeX (skips pre/code via ignoredTags), then mermaid diagrams.
      //    Each stage exits when a newer render has superseded this one.
      Promise.resolve()
        .then(function () { if (gen !== _renderGen) return; return highlightCode(content); })
        .then(function () { if (gen !== _renderGen) return; return renderMath(content); })
        .then(function () { if (gen !== _renderGen) return; return renderMermaid(content, mermaidNodes); })
        .then(function () {
          if (gen !== _renderGen) return;
          post({ type: "renderComplete", gen: gen });
        })
        .catch(function (e) {
          if (gen !== _renderGen) return; // stale chain: outcome no longer matters
          postError(e && e.message ? e.message : e);
        });
    } catch (e) {
      postError(e && e.message ? e.message : e);
    }
  }

  /* ---- public: applyStyle ---------------------------------------------- */
  // Live-update typography + theme without re-parsing the document.
  // Accepts an object or a JSON string. Recognized keys (all optional):
  //   bodyFont, monoFont, baseSize, measure, theme ("light"|"dark"),
  //   fullWidth (bool).

  function applyStyle(json) {
    try {
      var cfg = (typeof json === "string") ? JSON.parse(json) : (json || {});
      var rootStyle = document.documentElement.style;

      // Quote the family name — an unquoted value like `Source Serif 4` is
      // invalid CSS (identifier can't start with the digit "4"), which silently
      // drops font-family and falls back to a generic serif (Regular+Bold only).
      if (cfg.bodyFont != null) {
        rootStyle.setProperty("--tvmv-body-font", JSON.stringify(cfg.bodyFont) + ", serif");
      }
      if (cfg.monoFont != null) {
        rootStyle.setProperty("--tvmv-mono-font", JSON.stringify(cfg.monoFont) + ", monospace");
      }
      if (cfg.baseSize != null) {
        var size = (typeof cfg.baseSize === "number") ? cfg.baseSize + "px" : cfg.baseSize;
        rootStyle.setProperty("--tvmv-base-size", size);
      }
      if (cfg.measure != null) {
        var measure = (typeof cfg.measure === "number") ? cfg.measure + "ch" : cfg.measure;
        rootStyle.setProperty("--tvmv-measure", measure);
      }

      if (cfg.fullWidth != null) {
        document.documentElement.setAttribute(
          "data-measure", cfg.fullWidth ? "full" : "measured");
      }

      if (cfg.theme === "light" || cfg.theme === "dark") {
        setTheme(cfg.theme);
      }
    } catch (e) {
      postError(e && e.message ? e.message : e);
    }
  }

  // Light/dark lives entirely in app.css via the <html data-theme> attribute.
  function setTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
  }

  /* ---- public: scroll helpers ------------------------------------------ */

  function scrollToAnchor(id) {
    if (!id) return;
    var el = document.getElementById(id);
    if (el) el.scrollIntoView({ block: "start" });
  }

  function maxScroll() {
    var doc = document.documentElement;
    return Math.max(0, (doc.scrollHeight || 0) - (window.innerHeight || 0));
  }

  function getScrollRatio() {
    var max = maxScroll();
    if (max <= 0) return 0;
    return Math.min(1, Math.max(0, (window.scrollY || 0) / max));
  }

  function setScrollRatio(r) {
    var ratio = Math.min(1, Math.max(0, Number(r) || 0));
    window.scrollTo(0, ratio * maxScroll());
  }

  /* ---- public: sourcepos scroll sync ------------------------------------ */
  // Rendered blocks carry data-sourcepos="startLine:col-endLine:col" (cmark
  // CMARK_OPT_SOURCEPOS). These helpers map source lines <-> viewport position
  // for the app's editor/preview sync.

  function _sourceposStart(el) {
    var sp = el.getAttribute("data-sourcepos");
    if (!sp) return null;
    var n = parseInt(sp, 10); // "12:1-14:8" -> 12
    return isNaN(n) ? null : n;
  }

  // Index of {line, el} in document order, built once per render. Cursor and
  // scroll sync fire at debounce cadence; without the index each fired a
  // querySelectorAll + full attribute parse over every rendered block.
  var _lineIndex = [];

  function _buildLineIndex(content) {
    _lineIndex = [];
    var els = content.querySelectorAll("[data-sourcepos]");
    for (var i = 0; i < els.length; i++) {
      var start = _sourceposStart(els[i]);
      if (start !== null) _lineIndex.push({ line: start, el: els[i] });
    }
  }

  // The deepest block whose sourcepos start is <= line (last match in document
  // order wins, so a list item beats its containing list). Falls back to the
  // first block when `line` precedes all blocks. Starts in document order are
  // nondecreasing (pre-order over source positions), so binary-search the
  // rightmost entry with line <= target.
  function _elementForLine(line) {
    if (_lineIndex.length === 0) return null;
    var lo = 0, hi = _lineIndex.length - 1, found = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (_lineIndex[mid].line <= line) { found = mid; lo = mid + 1; }
      else { hi = mid - 1; }
    }
    return found >= 0 ? _lineIndex[found].el : _lineIndex[0].el;
  }

  // Source line of the topmost visible block, preferring the deepest nested
  // block (children follow parents in document order, so a visible child
  // inside a tall container wins over the container itself).
  function topVisibleSourceLine() {
    var best = null;
    for (var i = 0; i < _lineIndex.length; i++) {
      var el = _lineIndex[i].el;
      var r = el.getBoundingClientRect();
      if (r.height <= 0 || r.bottom <= 0) continue;      // empty or above viewport
      if (r.top > window.innerHeight) break;             // below viewport — done
      if (best === null || best.contains(el)) best = el;
      else break;                                        // left the first visible container
    }
    return best ? _sourceposStart(best) : null;
  }

  // Scroll the block for `line` to just below the viewport top (editor-scroll sync).
  function scrollToSourceLine(line) {
    var el = _elementForLine(Number(line) || 1);
    if (!el) return;
    var rect = el.getBoundingClientRect();
    window.scrollTo(0, Math.max(0, window.scrollY + rect.top - 16));
  }

  // Scroll only if the block for `line` is fully outside the viewport (cursor
  // sync — don't yank the preview around while the target is already in view).
  function revealSourceLine(line) {
    var el = _elementForLine(Number(line) || 1);
    if (!el) return;
    var rect = el.getBoundingClientRect();
    if (rect.bottom < 0 || rect.top > window.innerHeight) {
      el.scrollIntoView({ block: "center" });
    }
  }

  /* ---- preview -> editor click sync ------------------------------------ */
  // A click on a rendered block reports its source line so the app can jump
  // the editor there. The native side ignores it unless the editor pane is
  // open. Clicks on links keep their normal navigation behavior.

  document.addEventListener("click", function (ev) {
    var target = ev.target;
    if (!target || typeof target.closest !== "function") return;
    if (target.closest("a")) return;
    var el = target.closest("[data-sourcepos]");
    if (!el) return;
    var line = _sourceposStart(el);
    if (line !== null) post({ type: "sourceClick", line: line });
  });

  /* ---- public: find in page ------------------------------------------- */
  // Uses the CSS Custom Highlight API (no DOM mutation, so KaTeX/Mermaid and
  // layout are untouched). Degrades to count-only if the API is unavailable.

  var _findRanges = [];
  var _findIndex = -1;
  var _findTotal = 0;   // true match count; can exceed the materialized ranges

  function _supportsHighlight() {
    return !!(window.CSS && CSS.highlights && window.Highlight);
  }

  function clearFind() {
    _findRanges = [];
    _findIndex = -1;
    _findTotal = 0;
    if (_supportsHighlight()) {
      CSS.highlights.delete("tvmv-find");
      CSS.highlights.delete("tvmv-find-current");
    }
  }

  function _paintCurrent() {
    if (!_supportsHighlight() || _findIndex < 0 || _findIndex >= _findRanges.length) return;
    var cur = new Highlight();
    cur.add(_findRanges[_findIndex]);
    CSS.highlights.set("tvmv-find-current", cur);
    var rect = _findRanges[_findIndex].getBoundingClientRect();
    var target = window.scrollY + rect.top - (window.innerHeight / 2);
    window.scrollTo(0, Math.max(0, target));
  }

  // Find all case-insensitive occurrences of `query` within #content text
  // nodes. Returns { count, index } with a 1-based index (0 when no matches).
  function findInPage(query) {
    clearFind();
    var q = (query || "").toLowerCase();
    if (!q) return { count: 0, index: 0 };

    var content = document.getElementById("content");
    if (!content) return { count: 0, index: 0 };

    var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (!node.nodeValue) return NodeFilter.FILTER_REJECT;
        var p = node.parentElement;
        while (p) {
          var tag = p.tagName;
          if (tag === "SCRIPT" || tag === "STYLE" || tag === "TEXTAREA") {
            return NodeFilter.FILTER_REJECT;
          }
          p = p.parentElement;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });

    // Materialized Range objects (and their highlights) are capped: a short
    // query in repetitive content can match hundreds of thousands of times,
    // and each retained Range pins DOM state. Counting continues past the cap
    // so the match label stays honest; navigation cycles the materialized set.
    var MAX_RANGES = 10000;
    var total = 0;

    var node;
    while ((node = walker.nextNode())) {
      var hay = node.nodeValue.toLowerCase();
      var from = 0, i;
      while ((i = hay.indexOf(q, from)) !== -1) {
        total++;
        if (_findRanges.length < MAX_RANGES) {
          var r = document.createRange();
          r.setStart(node, i);
          r.setEnd(node, i + q.length);
          _findRanges.push(r);
        }
        from = i + q.length;
      }
    }

    if (_supportsHighlight() && _findRanges.length > 0) {
      var all = new Highlight();
      for (var k = 0; k < _findRanges.length; k++) all.add(_findRanges[k]);
      CSS.highlights.set("tvmv-find", all);
    }

    _findTotal = total;
    if (_findRanges.length > 0) {
      _findIndex = 0;
      _paintCurrent();
    }
    return { count: _findTotal, index: _findRanges.length ? 1 : 0 };
  }

  // Move to the next (dir >= 0) or previous (dir < 0) match, wrapping around.
  function findNext(dir) {
    if (_findRanges.length === 0) return { count: 0, index: 0 };
    var step = (dir < 0) ? -1 : 1;
    _findIndex = (_findIndex + step + _findRanges.length) % _findRanges.length;
    _paintCurrent();
    return { count: _findTotal, index: _findIndex + 1 };
  }

  /* ---- public: user CSS override --------------------------------------- */
  // Inject (or replace/remove) a user-supplied stylesheet. Appended LAST in
  // <head> so it overrides app.css and the lazily-loaded vendor styles.
  function applyUserCSS(css) {
    var id = "tvmv-user-css";
    var el = document.getElementById(id);
    if (!css) { if (el && el.parentNode) el.parentNode.removeChild(el); return; }
    if (!el) {
      el = document.createElement("style");
      el.id = id;
    }
    el.textContent = css;
    document.head.appendChild(el); // (re)append so it stays last in the cascade
  }

  /* ---- expose to native ------------------------------------------------ */

  window.tvmv = {
    render: render,
    applyStyle: applyStyle,
    setTheme: setTheme,
    scrollToAnchor: scrollToAnchor,
    getScrollRatio: getScrollRatio,
    setScrollRatio: setScrollRatio,
    topVisibleSourceLine: topVisibleSourceLine,
    scrollToSourceLine: scrollToSourceLine,
    revealSourceLine: revealSourceLine,
    find: findInPage,
    findNext: findNext,
    clearFind: clearFind,
    applyUserCSS: applyUserCSS
  };
})();
