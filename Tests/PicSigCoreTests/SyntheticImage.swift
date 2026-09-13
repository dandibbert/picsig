import Foundation
@testable import PicSigCore

/// Helpers that build deterministic fake screenshots so the stitching
/// algorithms can be tested without any image files.
enum SyntheticImage {
    /// A "screenshot" made of a fixed header, scrolling content and a fixed
    /// footer. Content pixels are a function of the absolute content row, so two
    /// captures of the same page at different scroll offsets really do share
    /// pixels, exactly like the real thing.
    static func screenshot(width: Int,
                           height: Int,
                           scrollOffset: Int,
                           headerHeight: Int = 0,
                           footerHeight: Int = 0,
                           seed: UInt64 = 7) -> GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8
                if y < headerHeight {
                    value = header(x: x, y: y)
                } else if y >= height - footerHeight {
                    value = footer(x: x, y: height - 1 - y)
                } else {
                    value = content(x: x, y: y - headerHeight + scrollOffset, seed: seed)
                }
                pixels[y * width + x] = value
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    /// Deterministic pseudo random content that varies strongly in both axes so
    /// that vertical alignment is unambiguous.
    static func content(x: Int, y: Int, seed: UInt64 = 7) -> UInt8 {
        var state = UInt64(bitPattern: Int64(y)) &* 0x9E37_79B9_7F4A_7C15 &+ seed
        state ^= UInt64(bitPattern: Int64(x)) &* 0xBF58_476D_1CE4_E5B9
        state ^= state >> 27
        state = state &* 0x94D0_49BB_1331_11EB
        state ^= state >> 31
        return UInt8(truncatingIfNeeded: state)
    }

    static func header(x: Int, y: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: 40 + (x % 5) + (y % 3) * 7)
    }

    static func footer(x: Int, y: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: 200 - (x % 7) - (y % 4) * 5)
    }

    static func solid(width: Int, height: Int, value: UInt8) -> GrayImage {
        GrayImage(width: width, height: height, repeating: value)
    }
}
