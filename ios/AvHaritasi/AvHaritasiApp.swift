import SwiftUI

@main
struct AvHaritasiApp: App {
    @StateObject private var model = AppModel()

    init() {
        Diagnostics.shared.start()
        Keychain.migrateFromDefaults("birdnetKey")
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var playedLaunch = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    // Açılışta kınalı keklik (bir kez)
                    guard !playedLaunch else { return }
                    playedLaunch = true
                    AppSound.acilis.play()
                }
        }
        .onChange(of: scenePhase) { old, new in
            // Arka plana geçerken kızılgerdan
            if old == .inactive, new == .background { AppSound.kapanis.play() }
            if new == .active { model.refreshSystemStatus() }
        }
    }
}
