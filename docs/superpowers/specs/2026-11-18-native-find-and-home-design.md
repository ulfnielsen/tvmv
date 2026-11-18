# Native Find and Home

**Intent:** In the macOS native document, Find should match and highlight rendered table text, and Home should scroll to the top even when a table cell has focus.

**Constraints:** Keep the AppKit Find bar, document search order, Markdown storage, and table editing. Home scrolls the outer document without changing selection, focus, or edits. Leave modified Home shortcuts and other platforms alone.

**Approaches:** Keep AppKit’s bar and provide a table-aware `NSTextFinderClient`, rather than building a separate bar or drawing highlights over matches in hidden table source. A source-only overlay cannot find phrases split by hidden inline Markdown and would still count table delimiters. Route Home through the document’s scroll view rather than treating it as a caret movement.

**Design:** Search ordinary document text as before, substitute visible cell text in row/column order where a table is rendered, and search raw table text when it is revealed as Markdown. Keep cells as separate search boundaries. Map a cell match to that cell’s selection, scroll position, and find-indicator geometry. Find commands from cells use the outer document’s finder. Preserve normal editing and unrelated keyboard commands.
