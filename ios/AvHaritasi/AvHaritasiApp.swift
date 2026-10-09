import SwiftUI

@main
struct AvHaritasiApp: App {
    @State private var model = AppModel()

    init() {
        Diagnostics.shared.start()
        // Eski sürümlerdeki BirdNET sunucu ayarlarını temizle (artık yalnızca cihazda çalışır)
        Keychain.set("birdnetKey", "")
        ["birdnetURL", "birdnetPreferServer"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        WatchLink.shared.activate()
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var playedLaunch = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
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
