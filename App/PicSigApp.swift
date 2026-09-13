import SwiftUI
import UIKit

@main struct PicSigApp: App {
    @StateObject private var library = LibraryModel()
    var body: some Scene {
        WindowGroup {
            HomeView().environmentObject(library).tint(.picAccent)
                .task { PrivacyCurtain.shared.install(); await library.reload() }
        }
    }
}

extension Color {
    static let picAccent = Color(red: 0.36, green: 0.29, blue: 0.83)
    static let picMint = Color(red: 0.14, green: 0.63, blue: 0.52)
    static let picCanvas = Color(uiColor: .systemGroupedBackground)
}
struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
extension View {
    func cardSurface() -> some View { modifier(CardSurface()) }
    func notice(_ item: Binding<Notice?>) -> some View {
        alert(item.wrappedValue?.title ?? "提示", isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })) {
            Button("知道了", role: .cancel) { item.wrappedValue = nil }
        } message: { Text(item.wrappedValue?.message ?? "") }
    }
}
struct WorkOverlay: View {
    @ObservedObject var session: StudioSession
    var body: some View {
        if session.busy {
            ZStack {
                Color.black.opacity(0.18).ignoresSafeArea()
                VStack(spacing: 18) {
                    ProgressView(value: session.progress).tint(.picAccent)
                    Text(session.workLabel).font(.headline).multilineTextAlignment(.center)
                    Text("所有处理均在此设备上进行").font(.caption).foregroundStyle(.secondary)
                    Button("取消操作", role: .cancel) { session.cancel() }.buttonStyle(.bordered)
                }.padding(26).frame(maxWidth: 320).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
            }.accessibilityAddTraits(.isModal)
        }
    }
}

/// A separate non-key window covers modal previews as well as the main workspace in app-switcher snapshots.
@MainActor final class PrivacyCurtain {
    static let shared = PrivacyCurtain()
    private var window: UIWindow?
    private var observers: [NSObjectProtocol] = []
    func install() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window?.isHidden = true; self?.window = nil }
        })
    }
    private func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else { return }
        let curtain = UIWindow(windowScene: scene); curtain.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        curtain.rootViewController = UIHostingController(rootView:
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "lock.shield").font(.system(size: 46)).foregroundStyle(Color.picAccent)
                    Text("PicSig").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("内容留在这里，隐私也是。").font(.subheadline).foregroundStyle(.secondary)
                }
            })
        curtain.isUserInteractionEnabled = false; curtain.isHidden = false; window = curtain
    }
}
