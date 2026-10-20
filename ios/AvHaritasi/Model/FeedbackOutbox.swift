import Foundation
import Observation

/// Geri bildirimi gönderir; bağlantı yoksa ya da sunucu şu an almıyorsa cihazda bekletir (en çok 5) ve
/// bağlantı gelince, uygulama öne gelince ya da yeni bildirim gönderilince yeniden dener (bkz. `Feedback`).
///
/// Disk: Application Support/geribildirim/sira.json — iOS dosya koruması (ilk kilit açmadan sonra),
/// yedeğe alınmaz; gönderilince ya da 30 gün sonra silinir.
@MainActor
@Observable
final class FeedbackOutbox {
    static let shared = FeedbackOutbox()

    typealias Transport = @Sendable (URLRequest) async -> (status: Int?, body: Data?)

    /// Gönderimin kullanıcıya gösterilen sonucu.
    enum Status: Equatable {
        case sent
        /// İnternet yok ya da geçici hata: bağlantı gelince gönderilecek.
        case queued
        /// Sunucu şu an almıyor (503): sırada bekliyor.
        case unavailable
        case rejected(String?)
        /// Sıra dolu (gönderilemeyen 5 bildirim var).
        case queueFull

        var message: String {
            switch self {
            case .sent: L("Gönderildi, teşekkürler")
            case .queued: L("Bağlantı gelince gönderilecek")
            case .unavailable: L("Geri bildirim şu an alınamıyor; daha sonra kendiliğinden yeniden denenecek.")
            case .rejected(let m): m.map { L("Gönderilemedi: %@", $0) } ?? L("Gönderilemedi.")
            case .queueFull: L("Gönderilmeyi bekleyen çok fazla bildirim var; bağlantı gelince yeniden deneyin.")
            }
        }

        var isSuccess: Bool { self == .sent }
    }

    /// Bekleyen bildirim sayısı.
    private(set) var pendingCount = 0

    @ObservationIgnored private let endpoint: URL?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let isOnline: @Sendable () -> Bool
    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var queue = FeedbackQueue()
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var lastOutcomes: [UUID: FeedbackDelivery] = [:]
    /// Son denemede sırayı durduran sonuç (önceki bir bildirim takıldıysa yenisi de onu paylaşır).
    @ObservationIgnored private var lastStop: FeedbackDelivery?

    private convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("geribildirim", isDirectory: true)
        // Birim testleri uygulama içinde koşar: gerçek sunucuya istek gitmesin
        let underTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.init(directory: dir, endpoint: underTests ? nil : Feedback.endpoint)
        guard endpoint != nil else { return }
        NetworkState.shared.observe { s in
            guard s.online else { return }
            Task { @MainActor in FeedbackOutbox.shared.flush() }
        }
    }

    /// Testler için: ayrı klasör, sahte ağ ve saat.
    init(directory: URL, endpoint: URL?,
         isOnline: @escaping @Sendable () -> Bool = { NetworkState.shared.isOnline },
         transport: @escaping Transport = FeedbackOutbox.urlSessionTransport,
         now: @escaping () -> Date = { Date() }) {
        self.endpoint = endpoint
        fileURL = directory.appendingPathComponent("sira.json")
        self.isOnline = isOnline
        self.transport = transport
        self.now = now
        load()
    }

    /// Yeni bildirimi sıraya alır ve (bağlantı varsa) hemen gönderir.
    func submit(_ payload: FeedbackPayload) async -> Status {
        guard endpoint != nil else { return .unavailable }
        let item = QueuedFeedback(created: now(), payload: payload)
        queue.prune(now: now())
        guard queue.enqueue(item) else { return .queueFull }
        save()
        guard isOnline() else { return .queued }
        await flushNow()
        let outcome = lastOutcomes[item.id] ?? lastStop
        lastOutcomes.removeAll()
        switch outcome {
        case .sent: return .sent
        case .rejected(let m): return .rejected(m)
        case .unavailable: return .unavailable
        case .retryLater, nil: return .queued
        }
    }

    /// Bekleyenleri sırayla göndermeyi dener (bağlantı geldiğinde, uygulama öne geldiğinde).
    func flush() {
        guard endpoint != nil, !queue.items.isEmpty else { return }
        Task { await flushNow() }
    }

    private func flushNow() async {
        guard let endpoint, !flushing, isOnline() else { return }
        flushing = true
        defer { flushing = false }
        lastStop = nil
        queue.prune(now: now())
        for item in queue.items {
            guard let request = try? Self.request(item.payload, endpoint: endpoint) else {
                queue.remove(item.id)
                continue
            }
            let (status, body) = await transport(request)
            let outcome = FeedbackDelivery.outcome(status: status, body: body)
            lastOutcomes[item.id] = outcome
            if outcome.keepsQueued {  // sunucu almıyor / bağlantı yok: sonrakileri de deneme
                lastStop = outcome
                break
            }
            queue.remove(item.id)
            if outcome == .sent { UsageStats.record(.geriBildirim) }
        }
        save()
    }

    static func request(_ payload: FeedbackPayload, endpoint: URL) throws -> URLRequest {
        var r = URLRequest(url: endpoint, timeoutInterval: OnlineBirdID.timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("1", forHTTPHeaderField: Feedback.appHeader)
        r.httpBody = try payload.encoded()
        return r
    }

    static let urlSessionTransport: Transport = { request in
        do {
            let (data, response) = try await OnlineBirdIDClient.defaultSession.data(for: request)
            return (status: (response as? HTTPURLResponse)?.statusCode, body: Optional(data))
        } catch {
            return (status: nil, body: nil)
        }
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let q = try? JSONDecoder().decode(FeedbackQueue.self, from: data) else { return }
        queue = q
        queue.prune(now: now())
        pendingCount = queue.items.count
    }

    private func save() {
        pendingCount = queue.items.count
        if queue.items.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
        else { return }
        var u = fileURL
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    // MARK: Testler için

    var queuedItems: [QueuedFeedback] { queue.items }
}
