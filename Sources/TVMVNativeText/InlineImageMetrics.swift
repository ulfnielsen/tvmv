import CoreGraphics
import Foundation

/// The size an inline image is drawn at in its line of text.
public enum InlineImageMetrics {
    /// `natural` scaled down (never up), keeping its aspect ratio, to at most
    /// 1.4 em tall (inside the 1.7 em body line, so the line keeps its
    /// height) and at most `column` wide.
    public static func size(natural: CGSize, theme: NativeTheme, column: CGFloat) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let scale = min(1, theme.body.pointSize * 1.4 / natural.height, max(0, column) / natural.width)
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }
}
