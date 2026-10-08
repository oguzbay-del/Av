import SwiftUI

/// Apple Watch uygulaması "Av Durumu": iPhone'daki Av Haritası'nın hesapladığı av durumunu gösterir.
@main
struct AvSaatApp: App {
    @State private var store = WatchStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StatusView()
                .environment(store)
        }
        .onChange(of: scenePhase) { _, new in
            if new == .active { store.requestLatest() }
        }
    }
}
