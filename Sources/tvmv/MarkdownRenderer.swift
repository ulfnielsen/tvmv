import cmark_gfm
import cmark_gfm_extensions

/// Parse GitHub-Flavored Markdown and render it to an HTML string.
///
/// Enables the GFM core extensions: table, strikethrough, autolink, tasklist.
func renderHTML(_ markdown: String) -> String {
    // Register the GFM core extensions exactly once per process. This populates
    // the global registry queried by `cmark_find_syntax_extension`. Idempotent.
    cmark_gfm_core_extensions_ensure_registered()

    // Options bitmask. CMARK_OPT_DEFAULT (0) keeps the safe default (raw HTML and
    // javascript:/data: links stripped). Use CMARK_OPT_UNSAFE to allow raw HTML.
    let options = CMARK_OPT_DEFAULT

    guard let parser = cmark_parser_new(options) else { return "" }
    defer { cmark_parser_free(parser) }

    // Attach the four GFM extensions to the parser by their registered names.
    for name in ["table", "strikethrough", "autolink", "tasklist"] {
        if let ext = cmark_find_syntax_extension(name) {
            cmark_parser_attach_syntax_extension(parser, ext)
        }
    }

    // Feed the source bytes and build the document node tree.
    markdown.withCString { cString in
        cmark_parser_feed(parser, cString, strlen(cString))
    }
    guard let document = cmark_parser_finish(parser) else { return "" }
    defer { cmark_node_free(document) }

    // The HTML renderer needs the active extension list so extension nodes
    // (tasklist checkboxes, tables) emit their custom HTML.
    let extensions = cmark_parser_get_syntax_extensions(parser)

    guard let htmlCString = cmark_render_html(document, options, extensions) else {
        return ""
    }
    defer { free(htmlCString) }

    return String(cString: htmlCString)
}
