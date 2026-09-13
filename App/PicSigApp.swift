import SwiftUI

@main
struct PicSigApp: App {
    @State private var settings = AppSettings.load()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(settings)
                .tint(.accentColor)
        }
    }
}
