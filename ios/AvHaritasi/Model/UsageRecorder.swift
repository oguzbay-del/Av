import CryptoKit
import Foundation

/// Kullanım sayaçlarını cihazda tutar ve günde en çok bir kez gönderir (bkz. `UsageStats`).
///
/// Disk: Application Support/istatistik/gunluk.bin — AES-GCM ile şifreli (anahtar Anahtar Zinciri'nde,
/// "ilk kilit açmadan sonra, yalnızca bu cihaz"); dosya ayrıca `.completeUntilFirstUserAuthentication`
/// ile korunur ve yedeğe alınmaz (FieldLog ile aynı yaklaşım). İlk kilit açmadan önce okunamazsa
/// sayaçlar bellekte birikir, sonra diskteki kayda eklenir.
/// Gönderim: bağlantı varken, son denemeden 24 saat geçtiyse bitmiş günler tek istekte gider; başarılıysa
/// silinir. Başarısız deneme de sayılır (ertesi güne kadar yeniden denenmez); 30 günden eskiler silinir.
/// Tüm durum tek bir seri kuyrukta tutulur; herhangi bir iş parçacığından çağrılabilir, arayüzü bekletmez.
final class UsageRecorder: @unchecked Sendable {
    static let shared = UsageRecorder()

    typealias Transport = @Sendable (URLRequest) async throws -> Int

    private static let keychainKey = "usageStatsKey"

    private let appID: String?
    private let fileURL: URL
    private let isEnabled: @Sendable () -> Bool
    private let isOnline: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let transport: Transport
    private let fixedKey: SymmetricKey?
    private let queue = DispatchQueue(label: "av.kullanim-istatistik", qos: .utility)

    // Yalnızca `queue` üzerinde
    private var ledger = UsageLedger()
    /// Diskteki kayıt okundu mu (okunamadıysa bellekteki sayaçlar sonra birleştirilir).
    private var loaded = false
    private var sending = false
    /// Bu oturumda yer (avlak/ilçe) sayıldı mı.
    private var areaCounted = true

    private convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("istatistik", isDirectory: true)
        // Birim testleri uygulamanın içinde koşar: testlerin dokunduğu özellikler sayılmasın, gönderilmesin
        let underTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.init(directory: dir, appID: underTests ? nil : UsageStats.appID)
        guard appID != nil else { return }
        // Bağlantı gelince (gün içinde ilk kez) göndermeyi dene
        NetworkState.shared.observe { [weak self] s in if s.online { self?.sendIfDue() } }
    }

    /// Testler için: ayrı klasör, sabit anahtar, sahte ağ ve saat.
    init(directory: URL, appID: String?, key: SymmetricKey? = nil,
         isEnabled: @escaping @Sendable () -> Bool = { UsageStats.isEnabledSetting },
         isOnline: @escaping @Sendable () -> Bool = { NetworkState.shared.isOnline },
         now: @escaping @Sendable () -> Date = { Date() },
         transport: @escaping Transport = UsageRecorder.urlSessionTransport) {
        self.appID = appID?.isEmpty == false ? appID : nil
        fileURL = directory.appendingPathComponent("gunluk.bin")
        fixedKey = key
        self.isEnabled = isEnabled
        self.isOnline = isOnline
        self.now = now
        self.transport = transport
    }

    private var active: Bool { appID != nil && isEnabled() }

    // MARK: Kayıt

    /// Uygulama öne geldi: oturum say, cihaz bilgisini güncelle, gerekiyorsa gönder.
    func sessionStarted() {
        guard active else { return }
        let info = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let model = Self.deviceModel
        change { d in
            d.sessions += 1
            d.appVersion = info
            d.osVersion = osText
            d.deviceModel = model
        }
        queue.async { [self] in areaCounted = false }
        sendIfDue()
    }

    /// Arka plana geçerken: oturumda yer belirlenemediyse "bilinmiyor" say.
    func sessionEnded() {
        guard active else { return }
        queue.async { [self] in
            guard !areaCounted else { return }
            areaCounted = true
            apply { $0.areas[UsageStats.unknownArea, default: 0] += 1 }
        }
    }

    /// Bulunulan avlak/ilçe (yalnızca uygulamanın kendi bölge verisinden; ava yasak alanda nil gelir).
    /// Oturum başına bir kez, ilk bilinen ad sayılır. Sık çağrılabilir (diske yalnızca ilk seferde yazılır).
    func noteArea(_ unitName: String?) {
        guard active, let name = UsageStats.areaName(unitName) else { return }
        queue.async { [self] in
            guard !areaCounted else { return }
            areaCounted = true
            apply { $0.areas[name, default: 0] += 1 }
        }
    }

    func record(_ feature: UsageFeature) {
        guard active else { return }
        change { $0.features[feature.rawValue, default: 0] += 1 }
    }

    /// Uyarı: yalnızca sayı (yer ya da seviye eklenmez).
    func recordAlert() {
        guard active else { return }
        change { $0.alerts += 1 }
    }

    func recordBirdID(_ kind: UsageBirdKind, confidence: UsageConfidence, online: Bool) {
        guard active else { return }
        let feature: UsageFeature = kind == .foto ? .kusFotografi : .kusSesi
        change { d in
            d.birdIDs[UsageDay.birdKey(kind, confidence, online: online), default: 0] += 1
            d.features[feature.rawValue, default: 0] += 1
        }
    }

    /// Kapatıldı: bekleyen tüm veriyi, kurulum kimliğini ve anahtarı sil.
    func deleteAll() {
        queue.async { [self] in
            ledger = UsageLedger()
            loaded = true
            areaCounted = true
            try? FileManager.default.removeItem(at: fileURL)
            if fixedKey == nil { Keychain.set(Self.keychainKey, nil) }
        }
    }

    // MARK: Gönderim

    /// Bağlantı varsa ve son denemeden 24 saat geçtiyse bitmiş günleri gönder.
    func sendIfDue() {
        guard active, let appID else { return }
        queue.async { [self] in
            let t = now()
            guard !sending, isOnline() else { return }
            loadIfNeeded()
            ledger.prune(now: t)
            let days = ledger.completedDays(now: t)
            guard !days.isEmpty, ledger.isSendDue(now: t) else { return }
            #if DEBUG
            let testMode = true
            #else
            let testMode = false
            #endif
            let signals = UsageSignalBuilder.signals(for: days, appID: appID, installID: ledger.installID, testMode: testMode)
            guard let request = try? UsageSignalBuilder.request(signals) else { return }
            ledger.lastAttempt = t
            save()
            sending = true
            let keys = Set(days.map(\.key))
            let sent = Dictionary(uniqueKeysWithValues: days.map { ($0.key, $0.day) })
            let transport = transport
            Task.detached(priority: .background) { [weak self] in
                let ok = ((try? await transport(request)).map { (200..<300).contains($0) }) ?? false
                self?.finishSend(ok: ok, keys: keys, sent: sent)
            }
        }
    }

    private func finishSend(ok: Bool, keys: Set<String>, sent: [String: UsageDay]) {
        queue.async { [self] in
            sending = false
            guard ok, active else { return }
            // Gönderim sürerken o günlere eklenen (geç gelen) sayaçlar kaybolmasın: yalnızca gönderileni düş
            for k in keys {
                guard var d = ledger.days[k] else { continue }
                if d == sent[k] { ledger.days[k] = nil; continue }
                d.sessions -= sent[k]?.sessions ?? 0
                d.alerts -= sent[k]?.alerts ?? 0
                for (f, n) in sent[k]?.features ?? [:] { d.features[f] = (d.features[f] ?? 0) - n }
                for (a, n) in sent[k]?.areas ?? [:] { d.areas[a] = (d.areas[a] ?? 0) - n }
                for (b, n) in sent[k]?.birdIDs ?? [:] { d.birdIDs[b] = (d.birdIDs[b] ?? 0) - n }
                d.features = d.features.filter { $0.value > 0 }
                d.areas = d.areas.filter { $0.value > 0 }
                d.birdIDs = d.birdIDs.filter { $0.value > 0 }
                ledger.days[k] = d
            }
            save()
        }
    }

    static let urlSessionTransport: Transport = { request in
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    // MARK: Testler için

    /// Kuyruktaki işler bitince bellekteki kayıt.
    func snapshot() -> UsageLedger { queue.sync { ledger } }
    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    /// Diskteki kaydı yeniden oku (bellekteki yok sayılır).
    func reloadFromDisk() -> UsageLedger? { queue.sync { read() } }

    // MARK: Disk (yalnızca `queue` üzerinde)

    private func change(_ c: @escaping @Sendable (inout UsageDay) -> Void) {
        queue.async { [self] in apply(c) }
    }

    private func apply(_ c: (inout UsageDay) -> Void) {
        guard active else { return }
        loadIfNeeded()
        ledger.update(now(), c)
        save()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) { loaded = true; return }
        guard let disk = read() else { return }
        var merged = disk
        merged.merge(ledger)
        ledger = merged
        loaded = true
    }

    /// Diskteki kayıt; dosya yoksa ya da bozuksa boş kayıt, okunamıyorsa (cihaz kilitli) nil.
    private func read() -> UsageLedger? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return UsageLedger() }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Dosya okunabiliyorsa Anahtar Zinciri de açıktır: anahtar yoksa kayıt çözülemez, at
        guard let key = key(create: false) else {
            try? FileManager.default.removeItem(at: fileURL)
            return UsageLedger()
        }
        guard let box = try? AES.GCM.SealedBox(combined: data), let plain = try? AES.GCM.open(box, using: key),
              let l = try? JSONDecoder().decode(UsageLedger.self, from: plain) else {
            // Bozuk ya da eski anahtarla şifreli: at
            try? FileManager.default.removeItem(at: fileURL)
            return UsageLedger()
        }
        return l
    }

    private func save() {
        ledger.prune(now: now())
        // Okunamayan bir kaydın üzerine yazma (bellekte bekler, sonra birleştirilir)
        guard loaded, let key = key(create: true),
              let plain = try? JSONEncoder().encode(ledger),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? sealed.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
        else { return }
        var u = fileURL
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    /// Şifreleme anahtarı. Yeni anahtar yalnızca dosya yokken üretilir (kilitliyken Anahtar Zinciri
    /// okunamadığında mevcut kaydın anahtarı ezilmesin).
    private func key(create: Bool) -> SymmetricKey? {
        if let fixedKey { return fixedKey }
        if let s = Keychain.get(Self.keychainKey), let d = Data(base64Encoded: s) { return SymmetricKey(data: d) }
        guard create, !FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let k = SymmetricKey(size: .bits256)
        Keychain.set(Self.keychainKey, k.withUnsafeBytes { Data($0) }.base64EncodedString())
        // Yazılamadıysa (ör. ilk kilit açmadan önce) kullanma
        guard Keychain.get(Self.keychainKey) != nil else { return nil }
        return k
    }

    /// Donanım modeli (ör. "iPhone15,2"); ad ya da seri numarası değildir.
    private static let deviceModel: String = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? "iPhone" : machine
    }()
}
