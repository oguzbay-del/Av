import Foundation
import os
import WatchConnectivity

/// Av durumunu eşleşmiş Apple Watch'taki "Av Durumu" (AvSaat) uygulamasına gönderir.
///
/// - `updateApplicationContext`: her zaman en son durum (saat uygulaması açılınca okur).
/// - `sendMessage`: saat uygulaması o an açıksa anında iletim (titreşim için).
/// Aynı içerik en fazla dakikada bir yeniden gönderilir (saat "güncel değil" demesin diye).
@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    /// Aynı içeriğin yeniden gönderilme aralığı (saat 5 dakikadan eskiyi bayat sayar).
    private static let heartbeat: TimeInterval = 60

    private var last: WatchStatus?
    private var pending: WatchStatus?
    /// Saatten gelen "son durumu ver" isteğine delege kuyruğundan yanıt verebilmek için.
    private nonisolated let latest = OSAllocatedUnfairLock<Data?>(initialState: nil)

    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(_ status: WatchStatus) {
        guard WCSession.isSupported() else { return }
        if let last, last.sameContent(as: status), status.updated.timeIntervalSince(last.updated) < Self.heartbeat {
            return
        }
        let data = status.encoded
        latest.withLock { $0 = data }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            pending = status
            return
        }
        pending = nil
        last = status
        let dict = status.dictionary
        try? session.updateApplicationContext(dict)
        if session.isReachable {
            session.sendMessage(dict, replyHandler: nil, errorHandler: nil)
        }
    }

    private func flushPending() {
        guard let p = pending ?? last else { return }
        last = nil  // yeniden göndermeyi zorla
        send(p)
    }

    // MARK: WCSessionDelegate (WatchConnectivity bunları arka plan kuyruğunda çağırır)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.flushPending() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Başka bir saate geçildi: yeni saat için oturumu yeniden aç.
        WCSession.default.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.flushPending() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.flushPending() }
    }

    /// Saat uygulaması açılınca son durumu ister.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let data = latest.withLock { $0 }
        replyHandler(data.map { [WatchStatus.key: $0] } ?? [:])
    }
}
