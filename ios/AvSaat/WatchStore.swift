import Foundation
import Observation
import WatchConnectivity
import WatchKit

/// iPhone'dan gelen son av durumu. Durum "avlanmayın"a dönünce güçlü titreşim verir.
@MainActor
@Observable
final class WatchStore {
    static let shared = WatchStore()

    /// Bu süreden eski durum "güncel değil" sayılır.
    static let staleAfter: TimeInterval = 5 * 60

    private(set) var status: WatchStatus?
    private(set) var reachable = false

    private let link = WatchSessionLink()
    private let defaultsKey = "lastWatchStatus"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            status = WatchStatus(data: data)
        }
        link.store = self
        link.activate()
    }

    func isStale(at now: Date) -> Bool {
        guard let status else { return true }
        return now.timeIntervalSince(status.updated) > Self.staleAfter
    }

    /// Uygulama öne gelince iPhone'dan en son durumu iste (açıksa).
    func requestLatest() {
        link.requestLatest()
    }

    func setReachable(_ r: Bool) { reachable = r }

    func receive(_ new: WatchStatus) {
        let old = status
        // Sıra dışı (daha eski) gelen iletiyi yok say
        if let old, new.updated < old.updated { return }
        status = new
        if let data = new.encoded { UserDefaults.standard.set(data, forKey: defaultsKey) }
        haptic(from: old?.level, to: new.level)
    }

    private func haptic(from old: Int?, to new: Int) {
        guard old != new else { return }
        let device = WKInterfaceDevice.current()
        switch new {
        case 3:
            // Avlanmayın: iki kez güçlü uyarı
            device.play(.failure)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { device.play(.notification) }
        case 1 where (old ?? 0) >= 2:
            device.play(.success)
        default:
            break
        }
    }
}

/// WatchConnectivity temsilcisi (delege çağrıları arka plan kuyruğundan gelir).
final class WatchSessionLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    @MainActor weak var store: WatchStore?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func requestLatest() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        deliver(session.receivedApplicationContext)
        guard session.isReachable else { return }
        session.sendMessage(["request": "status"], replyHandler: { [weak self] reply in
            self?.deliver(reply)
        }, errorHandler: nil)
    }

    private func deliver(_ dict: [String: Any]) {
        guard let s = WatchStatus(dictionary: dict) else { return }
        Task { @MainActor [weak self] in self?.store?.receive(s) }
    }

    private func reachability(_ session: WCSession) {
        let r = session.isReachable
        Task { @MainActor [weak self] in self?.store?.setReachable(r) }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        reachability(session)
        requestLatest()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        reachability(session)
        if session.isReachable { requestLatest() }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }
}
