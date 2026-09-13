import Foundation
@testable import PicSigCore

/// Screenshots that look like the ones people actually stitch.
///
/// `SyntheticImage` fills the content with per-pixel noise and repeats the header
/// and footer bit for bit. That is the easiest possible input, and it hid a real
/// failure: on an iPhone the navigation and tab bars are translucent, so their
/// pixels change with whatever scrolls beneath them; the status bar clock ticks
/// between captures; most content rows are white with a little text; and a scroll
/// indicator appears at a different height in every shot. This generator models
/// all of that at native @3x resolution.
enum RealisticScreenshot {
    enum Style {
        /// Table view: separator, title, subtitle, thumbnail on the right.
        case list
        /// Chat: alternating bubbles of varying height.
        case chat
        /// Settings-like list where every row has the same layout, which makes the
        /// alignment genuinely ambiguous at the row period.
        case repetitiveList
    }

    struct Device {
        var width = 1170
        var height = 2532
        var statusBar = 141
        var navigationBar = 132
        var tabBar = 249

        var header: Int { statusBar + navigationBar }
        var footer: Int { tabBar }
        var contentHeight: Int { height - header - footer }

        static let iPhone13 = Device()
        static let iPhoneSE = Device(width: 750, height: 1334, statusBar: 60, navigationBar: 88, tabBar: 147)
    }

    struct Shot {
        var scroll: Int
        /// Changes the clock digits; a different value per shot mimics time passing.
        var clockVariant: Int = 0
        var showsScrollIndicator = true
    }

    static func sequence(style: Style,
                         device: Device = .iPhone13,
                         scrolls: [Int],
                         translucentBars: Bool = true,
                         seed: UInt64 = 11) -> [GrayImage] {
        scrolls.enumerated().map { index, scroll in
            render(style: style,
                   device: device,
                   shot: Shot(scroll: scroll, clockVariant: index, showsScrollIndicator: index > 0),
                   translucentBars: translucentBars,
                   seed: seed)
        }
    }

    static func render(style: Style,
                       device: Device = .iPhone13,
                       shot: Shot,
                       translucentBars: Bool = true,
                       seed: UInt64 = 11) -> GrayImage {
        let width = device.width
        let height = device.height
        var pixels = [UInt8](repeating: 250, count: width * height)

        // iOS bar materials blur what is beneath them heavily, so what shows
        // through is a smooth tint that shifts a little from shot to shot — not
        // the content's own edges. Modelled as block averages of the content.
        let blurBlock = 48
        var blurCache = [Int: UInt8]()
        func blurredBeneath(x: Int, absoluteY: Int) -> UInt8 {
            let bx = x / blurBlock
            let by = absoluteY / blurBlock
            let key = by * 4096 + bx
            if let cached = blurCache[key] { return cached }
            var total = 0
            var count = 0
            var sy = by * blurBlock
            while sy < (by + 1) * blurBlock {
                var sx = bx * blurBlock
                while sx < min(width, (bx + 1) * blurBlock) {
                    total += Int(content(style: style, x: sx, absoluteY: sy, width: width, seed: seed))
                    count += 1
                    sx += 3
                }
                sy += 3
            }
            let value = UInt8(clamping: total / max(1, count))
            blurCache[key] = value
            return value
        }

        for y in 0..<height {
            let rowStart = y * width
            for x in 0..<width {
                let value: UInt8
                if y < device.header {
                    value = topBar(x: x, y: y, device: device,
                                   beneath: blurredBeneath(x: x, absoluteY: y + shot.scroll),
                                   clockVariant: shot.clockVariant, translucent: translucentBars)
                } else if y >= height - device.footer {
                    value = bottomBar(x: x, y: y - (height - device.footer), device: device,
                                      beneath: blurredBeneath(x: x, absoluteY: y + shot.scroll),
                                      translucent: translucentBars)
                } else {
                    value = content(style: style, x: x, absoluteY: y + shot.scroll, width: width, seed: seed)
                }
                pixels[rowStart + x] = value
            }
        }

        if shot.showsScrollIndicator {
            drawScrollIndicator(into: &pixels, device: device, scroll: shot.scroll, style: style)
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    // MARK: - Chrome

    private static func blend(bar: Int, beneath: UInt8, translucent: Bool) -> UInt8 {
        guard translucent else { return UInt8(bar) }
        return UInt8(clamping: (bar * 82 + Int(beneath) * 18) / 100)
    }

    private static func topBar(x: Int, y: Int, device: Device, beneath: UInt8,
                               clockVariant: Int, translucent: Bool) -> UInt8 {
        let base = blend(bar: 249, beneath: beneath, translucent: translucent)
        if y < device.statusBar {
            // Clock, left. Digits differ per shot.
            if (45..<100).contains(y), (75..<220).contains(x) {
                let glyph = (x - 75) / 24
                let on = hash(UInt64(clockVariant), UInt64(glyph), UInt64((y - 45) / 9)) % 3 != 0
                return on ? 25 : base
            }
            // Signal / Wi-Fi / battery, right. Never change.
            if (50..<95).contains(y), (930..<1100).contains(x) {
                return hash(7, UInt64(x / 10), UInt64(y / 8)) % 2 == 0 ? 20 : base
            }
            return base
        }
        // Navigation bar: centred title, back chevron at the left.
        let inBar = y - device.statusBar
        if (44..<90).contains(inBar), (430..<740).contains(x) {
            return hash(3, UInt64((x - 430) / 18), UInt64((inBar - 44) / 7)) % 4 != 0 ? 30 : base
        }
        if (40..<92).contains(inBar), (40..<70).contains(x) {
            return 40
        }
        if inBar == device.navigationBar - 1 { return 200 } // hairline
        return base
    }

    private static func bottomBar(x: Int, y: Int, device: Device, beneath: UInt8, translucent: Bool) -> UInt8 {
        let base = blend(bar: 249, beneath: beneath, translucent: translucent)
        if y == 0 { return 200 } // hairline
        // Five tab icons.
        if (24..<96).contains(y) {
            let slot = x / (device.width / 5)
            let centre = slot * (device.width / 5) + device.width / 10
            if abs(x - centre) < 36 {
                return hash(5, UInt64(slot), UInt64((x - centre + 36) / 9), UInt64((y - 24) / 9)) % 3 != 0 ? 60 : base
            }
        }
        // Home indicator.
        if (device.tabBar - 42..<device.tabBar - 27).contains(y), (400..<770).contains(x) {
            return 30
        }
        return base
    }

    private static func drawScrollIndicator(into pixels: inout [UInt8], device: Device, scroll: Int, style: Style) {
        let totalContent = 12_000
        let track = device.contentHeight - 40
        let length = max(80, track * device.contentHeight / totalContent)
        let top = device.header + 20 + (track - length) * min(scroll, totalContent - device.contentHeight) / max(1, totalContent - device.contentHeight)
        for y in top..<min(device.height - device.footer, top + length) {
            for x in (device.width - 18)..<(device.width - 9) {
                pixels[y * device.width + x] = 150
            }
        }
    }

    // MARK: - Content plane

    /// Content is a pure function of the absolute row, so two shots at different
    /// scroll offsets genuinely share pixels, exactly like a real page.
    static func content(style: Style, x: Int, absoluteY y: Int, width: Int, seed: UInt64) -> UInt8 {
        switch style {
        case .list: return listContent(x: x, y: y, width: width, seed: seed)
        case .chat: return chatContent(x: x, y: y, width: width, seed: seed)
        case .repetitiveList: return repetitiveContent(x: x, y: y, width: width, seed: seed)
        }
    }

    private static func listContent(x: Int, y: Int, width: Int, seed: UInt64) -> UInt8 {
        let cellHeight = 264
        let cell = UInt64(y / cellHeight)
        let r = y % cellHeight
        if r < 3 { return 225 }
        if (36..<80).contains(r) {
            return textRun(cell: cell, line: 0, x: x, rowInLine: r - 36, lineHeight: 44,
                           lengthFraction: 0.45 + Double(hash(seed, cell, 1) % 45) / 100, ink: 30, width: width, seed: seed)
        }
        if (100..<136).contains(r) {
            return textRun(cell: cell, line: 1, x: x, rowInLine: r - 100, lineHeight: 36,
                           lengthFraction: 0.3 + Double(hash(seed, cell, 2) % 50) / 100, ink: 130, width: width, seed: seed)
        }
        if (150..<240).contains(r), (900..<1110).contains(x), hash(seed, cell, 3) % 3 != 0 {
            return UInt8(60 + hash(seed, cell, UInt64(x / 6), UInt64(r / 6)) % 140)
        }
        return 250
    }

    private static func chatContent(x: Int, y: Int, width: Int, seed: UInt64) -> UInt8 {
        let period = 420
        let bubble = UInt64(y / period)
        let r = y % period
        let bubbleHeight = 110 + Int(hash(seed, bubble, 9) % 260)
        guard r >= 20, r < 20 + bubbleHeight else { return 250 }
        let bubbleWidth = 480 + Int(hash(seed, bubble, 10) % 520)
        let onRight = hash(seed, bubble, 11) % 2 == 0
        let left = onRight ? width - 60 - bubbleWidth : 60
        guard x >= left, x < left + bubbleWidth else { return 250 }
        let background: UInt8 = onRight ? 150 : 232
        let inBubbleY = r - 20 - 32
        let inBubbleX = x - left - 40
        guard inBubbleY >= 0, inBubbleY < bubbleHeight - 64, inBubbleX >= 0, inBubbleX < bubbleWidth - 80 else {
            return background
        }
        let line = UInt64(inBubbleY / 54)
        let rowInLine = inBubbleY % 54
        guard rowInLine < 40 else { return background }
        let chunk = UInt64(inBubbleX / 14)
        let lineLength = UInt64(Double(bubbleWidth - 80) / 14 * (line == UInt64((bubbleHeight - 64) / 54) ? 0.5 : 1))
        guard chunk < lineLength, hash(seed, bubble, line, chunk) % 4 != 0 else { return background }
        return glyph(rowInLine: rowInLine, lineHeight: 40, key: hash(seed, bubble, line, chunk), ink: onRight ? 250 : 30, background: background)
    }

    private static func repetitiveContent(x: Int, y: Int, width: Int, seed: UInt64) -> UInt8 {
        // Every row: icon square at the left, a label, a chevron at the right.
        // Only the label text differs.
        let rowHeight = 176
        let row = UInt64(y / rowHeight)
        let r = y % rowHeight
        if r < 2 { return 225 }
        if (52..<124).contains(r), (48..<120).contains(x) { return 90 }
        if (70..<106).contains(r), (1080..<1110).contains(x) { return 160 }
        if (66..<110).contains(r) {
            return textRun(cell: row, line: 0, x: x - 100, rowInLine: r - 66, lineHeight: 44,
                           lengthFraction: 0.25 + Double(hash(seed, row, 4) % 35) / 100, ink: 30, width: width, seed: seed)
        }
        return 250
    }

    private static func textRun(cell: UInt64, line: UInt64, x: Int, rowInLine: Int, lineHeight: Int,
                                lengthFraction: Double, ink: UInt8, width: Int, seed: UInt64) -> UInt8 {
        let start = 60
        guard x >= start else { return 250 }
        let chunk = UInt64((x - start) / 14)
        let length = UInt64(Double(width - 200) / 14 * lengthFraction)
        guard chunk < length else { return 250 }
        let key = hash(seed, cell, line, chunk)
        guard key % 4 != 0 else { return 250 } // word gaps
        return glyph(rowInLine: rowInLine, lineHeight: lineHeight, key: key, ink: ink, background: 250)
    }

    /// Something glyph-shaped: solid through the x-height, sparser at the ascender
    /// and descender rows, with per-chunk variation so rows inside one line differ.
    private static func glyph(rowInLine: Int, lineHeight: Int, key: UInt64, ink: UInt8, background: UInt8) -> UInt8 {
        let ascender = lineHeight / 5
        let descender = lineHeight - lineHeight / 5
        if rowInLine < ascender || rowInLine >= descender {
            return hash(key, UInt64(rowInLine / 3)) % 3 == 0 ? ink : background
        }
        return hash(key, UInt64(rowInLine / 5)) % 7 == 0 ? background : ink
    }

    // MARK: - Hash

    private static func hash(_ values: UInt64...) -> UInt64 {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for value in values {
            state ^= value &+ 0x632B_E59B_D9B4_E019
            state = state &* 0xBF58_476D_1CE4_E5B9
            state ^= state >> 29
        }
        state = state &* 0x94D0_49BB_1331_11EB
        state ^= state >> 32
        return state
    }
}
