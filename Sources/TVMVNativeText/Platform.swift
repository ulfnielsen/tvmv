import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
#endif

public enum FontTrait: Sendable { case bold, italic }

extension PlatformFont {
    /// This font with a symbolic trait added; the font itself when the
    /// family has no such face.
    public func adding(_ trait: FontTrait) -> PlatformFont {
        #if os(macOS)
        NSFontManager.shared.convert(self, toHaveTrait: trait == .bold ? .boldFontMask : .italicFontMask)
        #else
        let symbolic: UIFontDescriptor.SymbolicTraits = trait == .bold ? .traitBold : .traitItalic
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(symbolic))
        else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
        #endif
    }
}

extension PlatformColor {
    /// An sRGB color from 0xRRGGBB.
    public static func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> PlatformColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        #if os(macOS)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
        #endif
    }
}
