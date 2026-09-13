import SwiftUI

/// Blocking overlay shown while a long operation runs. `progress` switches it
/// from a spinner to a bar; frame extraction is the one step slow enough that a
/// spinner alone would feel broken.
struct ProgressOverlay: View {
    let title: LocalizedStringKey
    var progress: Double?

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 170)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .transition(.opacity)
        // The point of the overlay is to swallow taps while work is in flight.
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityAddTraits(.isModal)
    }
}
