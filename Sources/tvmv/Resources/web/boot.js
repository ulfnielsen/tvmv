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
      if (pre && pre.parentNode) {
        pre.parentNode.replaceChild(div, pre);
      }
      nodes.push(div);
    }
    return nodes;
  }

  function highlightCode(root) {
    // Every `pre code` EXCEPT mermaid ones (already converted away above, but
    // guard anyway in case conversion order ever changes).
    var blocks = root.querySelectorAll("pre code");
    var targets = [];
    for (var i = 0; i < blocks.length; i++) {
      var el = blocks[i];
      if (el.classList.contains("language-mermaid")) continue;
      targets.push(el);
    }
    if (targets.length === 0) return Promise.resolve();

    // GitHub light theme for hljs as the base code palette.
    return Promise.all([
      loadStyle("highlight.js/github.min.css"),
      loadScript("highlight.js/highlight.min.js")
    ]).then(function () {
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
        ? "dark" : "default";
      // UMD bundle assigns globalThis.mermaid -> window.mermaid is available.
      window.mermaid.initialize({ startOnLoad: false, theme: theme });
      return window.mermaid.run({ nodes: mermaidNodes });
    });
  }

  /* ---- public: render -------------------------------------------------- */

  function render(bodyHTML, docBaseHref) {
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

      // 1. slugs + outline (synchronous, before KaTeX mutates heading text).
      var items = assignSlugsAndBuildOutline(content);
      post({ type: "outline", items: items });

      // 2. convert mermaid fences up front (changes the DOM the later passes
      //    scan; also keeps $-detection from seeing diagram source).
      var mermaidNodes = convertMermaidBlocks(content);

      // 3. lazy enrichment in a safe order: highlight remaining code, then
      //    KaTeX (skips pre/code via ignoredTags), then mermaid diagrams.
      Promise.resolve()
        .then(function () { return highlightCode(content); })
        .then(function () { return renderMath(content); })
        .then(function () { return renderMermaid(content, mermaidNodes); })
        .then(function () { post({ type: "renderComplete" }); })
        .catch(function (e) { postError(e && e.message ? e.message : e); });
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

      if (cfg.bodyFont != null) rootStyle.setProperty("--tvmv-body-font", cfg.bodyFont);
      if (cfg.monoFont != null) rootStyle.setProperty("--tvmv-mono-font", cfg.monoFont);
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

  // Switch the active github-markdown stylesheet by toggling link.disabled,
  // and reflect the choice on <html data-theme> for app.css / mermaid.
  function setTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    var light = document.getElementById("gh-light");
    var dark = document.getElementById("gh-dark");
    if (light) light.disabled = (theme === "dark");
    if (dark) dark.disabled = (theme !== "dark");
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

  /* ---- expose to native ------------------------------------------------ */

  window.tvmv = {
    render: render,
    applyStyle: applyStyle,
    setTheme: setTheme,
    scrollToAnchor: scrollToAnchor,
    getScrollRatio: getScrollRatio,
    setScrollRatio: setScrollRatio
  };
})();
