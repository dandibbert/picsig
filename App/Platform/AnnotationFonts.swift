import UIKit
import SwiftUI
import CoreText

/// Fonts for text annotations.
///
/// Since iOS 14 a process only sees the fonts the user installed — through a
/// configuration profile or a font app — when it carries the *Use Installed
/// Fonts* entitlement (`com.apple.developer.user-fonts`, see
/// `PicSig.entitlements`). Even then `UIFont.familyNames` is not a complete list:
/// fonts registered by font provider apps have to be asked for by name with
/// `CTFontManagerRequestFonts`. The one place that sees everything is the
/// system's `UIFontPickerViewController`, which runs out of process, so that is
/// the picker this app presents; the chosen font is then requested explicitly so
/// it resolves in this process when the mark is rendered and exported.
enum AnnotationFonts {
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
        guard let name else { return NSLocalizedString("font.system", comment: "") }
        guard let font = UIFont(name: name, size: 12) else { return name }
        let family = font.familyName
        let style = (font.fontDescriptor.object(forKey: .face) as? String) ?? ""
        if style.isEmpty || style == "Regular" { return family }
        return "\(family) \(style)"
    }

    /// Whether the font resolves in this process right now.
    static func isAvailable(_ name: String?) -> Bool {
        guard let name else { return true }
        return UIFont(name: name, size: 12) != nil
    }

    /// Asks the font manager to make user-installed fonts available to this
    /// process. Needed for fonts registered by font provider apps, which are not
    /// visible until requested by name; fonts from configuration profiles resolve
    /// on their own once the entitlement is present. Calls `completion` with the
    /// names that still could not be found.
    static func request(_ names: [String], completion: @escaping @MainActor ([String]) -> Void) {
        let missing = names.filter { !isAvailable($0) }
        guard !missing.isEmpty else {
            Task { @MainActor in completion([]) }
            return
        }
        let descriptors = missing.map { name in
            CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name] as CFDictionary)
        }
        CTFontManagerRequestFonts(descriptors as CFArray) { unresolved in
            var stillMissing = [String]()
            for index in 0..<CFArrayGetCount(unresolved) {
                guard let pointer = CFArrayGetValueAtIndex(unresolved, index) else { continue }
                let descriptor = unsafeBitCast(pointer, to: CTFontDescriptor.self)
                if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
                    stillMissing.append(name)
                }
            }
            Task { @MainActor in completion(stillMissing) }
        }
    }
}

/// The system font picker, wrapped for SwiftUI. Shows every font on the device,
/// including user-installed ones, with the system's own search field.
struct SystemFontPicker: UIViewControllerRepresentable {
    /// PostScript name of the chosen face; `nil` means the system font.
    @Binding var selection: String?
    /// Called after the user picked (or cancelled) so the host can dismiss.
    var onFinish: () -> Void = {}

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = true
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        if let selection {
            picker.selectedFontDescriptor = UIFontDescriptor(fontAttributes: [.name: selection])
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIFontPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        let parent: SystemFontPicker

        init(parent: SystemFontPicker) { self.parent = parent }

        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            guard let descriptor = viewController.selectedFontDescriptor else { return }
            // Resolving through UIFont gives the PostScript name for a family
            // descriptor too (the picker returns families unless a face was chosen).
            let name = UIFont(descriptor: descriptor, size: 12).fontName
            parent.selection = name
            // A provider-installed font may still need to be requested by name
            // before it resolves in this process.
            AnnotationFonts.request([name]) { _ in }
            parent.onFinish()
        }

        func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
            parent.onFinish()
        }
    }
}
