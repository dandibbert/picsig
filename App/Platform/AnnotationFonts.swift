import UIKit
import CoreText

/// Fonts available for text annotations: the system font, every family iOS
/// ships, and any font the user installed on the device through a configuration
/// profile (Settings → General → Fonts). Profile-installed fonts register with
/// the font manager system-wide, so they appear in `UIFont.familyNames` like
/// any other and need no special API to use — the picker only tells them apart
/// so they are easy to find.
enum AnnotationFonts {
    struct Family: Identifiable, Hashable {
        /// Display name as CoreText reports it ("PingFang SC").
        let name: String
        /// PostScript names of the faces, regular weight first.
        let faces: [String]
        /// True when the font file lives outside the system font directories —
        /// i.e. the user installed it.
        let isUserInstalled: Bool

        var id: String { name }
        /// The face to store in an annotation when the family is chosen.
        var preferredFace: String { faces.first ?? name }
    }

    /// Resolves a stored font name; unknown or `nil` names fall back to the
    /// system font so a document keeps rendering on a device without that font.
    static func font(named name: String?, size: CGFloat) -> UIFont {
        if let name, let font = UIFont(name: name, size: size) {
            return font
        }
        return UIFont.systemFont(ofSize: size, weight: .semibold)
    }

    /// Human readable name for a stored face, for lists and history rows.
    static func displayName(for name: String?) -> String {
        guard let name, let font = UIFont(name: name, size: 12) else {
            return NSLocalizedString("font.system", comment: "")
        }
        let family = font.familyName
        let style = (font.fontDescriptor.object(forKey: .face) as? String) ?? ""
        if style.isEmpty || style == "Regular" { return family }
        return "\(family) \(style)"
    }

    /// Every family on the device, user-installed ones flagged, sorted by name.
    /// Hidden system UI fonts (names starting with a dot) are left out.
    static func installedFamilies() -> [Family] {
        UIFont.familyNames
            .filter { !$0.hasPrefix(".") }
            .compactMap { familyName -> Family? in
                let names = UIFont.fontNames(forFamilyName: familyName)
                guard !names.isEmpty else { return nil }
                let faces = names.sorted { lhs, rhs in
                    faceRank(lhs) == faceRank(rhs) ? lhs < rhs : faceRank(lhs) < faceRank(rhs)
                }
                return Family(name: familyName,
                              faces: faces,
                              isUserInstalled: isUserInstalled(fontNamed: faces[0]))
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Regular faces first, then the rest alphabetically, so tapping a family
    /// gives its plain weight rather than "UltraLight Italic".
    private static func faceRank(_ postScriptName: String) -> Int {
        let lowered = postScriptName.lowercased()
        if !lowered.contains("-") { return 0 }
        if lowered.hasSuffix("-regular") || lowered.hasSuffix("-medium") || lowered.hasSuffix("-book") { return 1 }
        if lowered.contains("italic") || lowered.contains("oblique") { return 3 }
        return 2
    }

    private static func isUserInstalled(fontNamed name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { return false }
        let path = url.standardizedFileURL.path
        // System fonts sit under /System/Library/Fonts on a device and under the
        // simulator runtime's copy of that tree; a bundled app font is inside the
        // .app. Everything else was put there by the user.
        if path.contains("/var/mobile/") || path.contains("/private/var/") { return true }
        return !path.contains("/System/Library/Fonts")
            && !path.contains(".app/")
            && !path.contains("/Library/Developer/")
    }
}
