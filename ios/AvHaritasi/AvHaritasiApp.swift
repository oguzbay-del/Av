import SwiftUI

@main
struct AvHaritasiApp: App {
    @State private var model: AppModel
    /// Arka planda biten çevrimdışı harita indirmesi için (URLSession arka plan olayları).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Kilit ekranı güncel av durumunu canlı göstersin
        AppLock.shared.model = model
        // Soğuk açılışta Ayarlar sekmesinde başlama (durum ve harita görünsün)
        if UserDefaults.standard.string(forKey: "selectedTab") == "ayarlar" {
            UserDefaults.standard.set("harita", forKey: "selectedTab")
        }
        Diagnostics.shared.start()
        FieldLog.shared.logLaunch()
        // Arka plan indirme oturumu ve bağlantı izleme açılışta kurulsun (yarım indirme sürsün)
        _ = OfflineMapStore.shared
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
                // Uygulama kilidi (AppLock): yalnızca arayüz örtüsü. Konum, değerlendirme, uyarılar,
                // bildirimler, güvenli daire, Live Activity ve Watch eşitlemesi kilitliyken de çalışır.
                .onChange(of: scenePhase, initial: true) { _, new in AppLock.shared.scenePhaseChanged(new) }
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
            if new != old, new != .inactive { FieldLog.shared.log(new == .active ? .foreground : .background) }
        }
    }
}
