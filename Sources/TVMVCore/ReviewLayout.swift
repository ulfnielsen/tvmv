import Foundation

extension MarkdownLayout {
    /// Fold review markup into the layout. cmark knows nothing of it: with
    /// footnotes off it reads a `[^rv-…]` ref as a link and a thread as a
    /// paragraph, and `{~~a~>b~~}` holds a strikethrough. Whatever cmark made
    /// of the markup's own characters goes; the review spans replace it.
    mutating func fold(_ review: ReviewMarkup.Review) {
        guard !review.anchors.isEmpty || !review.threads.isEmpty else { return }
        self.review = review
        func ns(_ r: Range<Int>) -> NSRange { NSRange(location: r.lowerBound, length: r.count) }
        func meets(_ a: NSRange, _ b: NSRange) -> Bool { NSIntersectionRange(a, b).length > 0 }

        let spans = ReviewMarkup.spans(review)
        let anchors = review.anchors.map { ns($0.range) }
        let syntax = spans.filter { $0.isHidden || $0.role == .pointMarker }.map { ns($0.range) }
        let refs = spans.filter { $0.role == .ref || $0.role == .pointMarker }.map { ns($0.range) }
        let threads = spans.filter { $0.role == .definition }.map { ns($0.range) }
        let opaque = refs + threads

        // A style goes if it touches a ref or a thread, or sits inside an
        // anchor across its syntax (the strikethrough cmark sees in "{~~a~~}").
        styles.removeAll { run in
            opaque.contains { meets($0, run.range) }
                || (syntax.contains { meets($0, run.range) } && anchors.contains { $0.encloses(run.range) })
        }
        markers.removeAll { m in
            (syntax + threads).contains { meets($0, m.range) } || threads.contains { meets($0, m.unit) }
        }
        listItems.removeAll { item in threads.contains { meets($0, item.marker) } }
        quoteLines.removeAll { line in threads.contains { meets($0, line.prefix) } }
        blockImages.removeAll { image in opaque.contains { meets($0, image.range) } }
        tables.removeAll { table in threads.contains { meets($0, table.range) } }
        codeBlocks.removeAll { block in threads.contains { meets($0, block.range) } }
        headings.removeAll { heading in threads.contains { meets($0, heading.range) } }
        softBreaks.removeAll { b in threads.contains { NSLocationInRange(b, $0) } }

        for span in spans {
            let range = ns(span.range)
            guard range.length > 0 else { continue }
            if span.isSpellingExempt { spellExempt.append(range) }
            switch span.role {
            case .definition:
                markers.append(.init(range: range, unit: range, collapsesLine: true))
            case .delimiter, .ref:
                guard let unit = anchors.first(where: { $0.encloses(range) }) else { continue }
                markers.append(.init(range: range, unit: unit))
            case .pointMarker:
                // The "[" stays, small and clear, to carry the drawn marker.
                styles.append(.init(range: NSRange(location: range.location, length: 1),
                                    style: .review(role: .pointMarker, id: span.id)))
                if range.length > 1 {
                    markers.append(.init(range: NSRange(location: range.location + 1, length: range.length - 1),
                                         unit: range))
                }
            case .highlight, .insertion, .deletion, .substitutionOld, .substitutionNew:
                styles.append(.init(range: range, style: .review(role: span.role, id: span.id)))
            }
        }
        // Source order keeps `changedRange`'s front and back scans exact.
        markers.sort { $0.range.location < $1.range.location }
        styles.sort { $0.range.location < $1.range.location }
        spellExempt.sort { $0.location < $1.location }
    }
}
