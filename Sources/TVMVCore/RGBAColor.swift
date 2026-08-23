import Foundation

/// Platform-neutral color value for the window-chrome tint. The model computes
/// it; each platform converts at its own boundary (NSColor / SwiftUI.Color).
public struct RGBAColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Rec. 601 luma — used to pick light/dark chrome text.
    public var luminance: Double { 0.299 * red + 0.587 * green + 0.114 * blue }

    public func blended(fraction: Double, of other: RGBAColor) -> RGBAColor {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        return RGBAColor(red: mix(red, other.red), green: mix(green, other.green),
                         blue: mix(blue, other.blue), alpha: mix(alpha, other.alpha))
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
}
