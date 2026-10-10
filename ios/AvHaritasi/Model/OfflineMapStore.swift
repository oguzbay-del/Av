import Foundation
import Observation
import UIKit
import UserNotifications

/// Çevrimdışı haritanın indirilmesi ve durumu. Ağa yalnızca kullanıcı "İndir"/"Denetle"ye
/// bastığında çıkılır (manifest + paket, GitHub Releases).
///
/// İndirme arka plan URLSession'ıyla yapılır: uygulama arka plana geçse de sürer, yarıda kalırsa
/// kaldığı yerden devam eder; bitince SHA-256 denetlenip dosya atomik olarak yerine konur.
@MainActor
@Observable
final class OfflineMapStore: NSObject {
    static let shared = OfflineMapStore()
    static let sessionIdentifier = "av.harita.cevrimdisi"
    /// Hücresel veride bu boyutun üstü için onay istenir.
    static let cellularConfirmBytes: Int64 = 50_000_000
    /// İndirme sırasında boş kalması gereken ek pay.
    static let storageMargin: Int64 = 100_000_000

    // Bağlantı (NWPathMonitor)
    private(set) var isOnline = true
    private(set) var isExpensive = false

    // Kurulu paketler
    private(set) var installed: InstalledBasemap?
    private(set) var lowPackBundled = false
    /// Paketler değişince artar; harita katmanı yeniden açılır.
    private(set) var revision = 0

    // Manifest ve indirme
    private(set) var latest: BasemapManifest?
    private(set) var isChecking = false
    private(set) var isDownloading = false
    private(set) var isVerifying = false
    private(set) var bytesWritten: Int64 = 0
    private(set) var bytesExpected: Int64 = 0
    private(set) var hasResumeData = false
    private(set) var errorMessage: String?
    /// Son denetimde manifest sürümü kurulu olanla aynıysa.
    private(set) var checkedUpToDate = false
    /// Hücresel bağlantıda onay bekleyen indirme.
    private(set) var pendingCellular: BasemapManifest?

    /// Arka planda biten indirme olayları için iOS'un verdiği tamamlama bloğu.
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var session: URLSession?

    var hasAnyPack: Bool { lowPackBundled || installed != nil }
    var hasHighPack: Bool { installed != nil }
    var updateAvailable: Bool {
        guard let latest, let installed else { return false }
        return latest.version != installed.version
    }
    var progress: Double { bytesExpected > 0 ? min(1, Double(bytesWritten) / Double(bytesExpected)) : 0 }
    var attribution: String { installed?.attribution ?? latest?.attribution ?? OfflineBasemap.fallbackAttribution }

    override private init() {
        super.init()
        reloadInstalled()
        hasResumeData = OfflineBasemap.resume() != nil

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session

        // Uygulama kapanıp açıldıysa süren indirmeyi yeniden göster
        session.getAllTasks { tasks in
            let running = tasks.compactMap { $0 as? URLSessionDownloadTask }.first { $0.state == .running }
            let info = running.map { ($0.countOfBytesReceived, $0.countOfBytesExpectedToReceive) }
            guard let info else { return }
            Task { @MainActor in
                self.isDownloading = true
                self.bytesWritten = info.0
                self.bytesExpected = info.1
            }
        }

        NetworkState.shared.observe { status in
            Task { @MainActor in
                OfflineMapStore.shared.isOnline = status.online
                OfflineMapStore.shared.isExpensive = status.expensive
            }
        }
    }

    private func reloadInstalled() {
        installed = OfflineBasemap.installedInfo()
        lowPackBundled = OfflineBasemap.bundledLowPackURL != nil
    }

    // MARK: Manifest

    private func fetchManifest() async throws -> BasemapManifest {
        var req = URLRequest(url: OfflineBasemap.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("AvHaritasi/1.0 (+https://github.com/oguzbay-del/harita-veri; iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let manifest = try JSONDecoder().decode(BasemapManifest.self, from: data)
        guard manifest.highPack != nil else { throw URLError(.cannotParseResponse) }
        return manifest
    }

    /// "Güncellemeleri denetle": yalnızca manifesti okur.
    func checkForUpdate() {
        guard !isChecking else { return }
        guard isOnline else { errorMessage = L("İnternet bağlantısı yok."); return }
        errorMessage = nil
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let m = try await fetchManifest()
                latest = m
                checkedUpToDate = installed?.version == m.version
            } catch {
                errorMessage = L("Harita bilgisi alınamadı: %@", error.localizedDescription)
            }
        }
    }

    // MARK: İndirme

    /// İndir / güncelle / devam et. Önce manifest okunur; hücresel veride büyük dosya için onay istenir.
    func download() {
        guard !isChecking, !isDownloading else { return }
        guard isOnline else { errorMessage = L("İnternet bağlantısı yok. Haritayı Wi-Fi'deyken indirin."); return }
        errorMessage = nil
        isChecking = true
        Task {
            defer { isChecking = false }
            let manifest: BasemapManifest
            do {
                manifest = try await fetchManifest()
            } catch {
                errorMessage = L("Harita bilgisi alınamadı: %@", error.localizedDescription)
                return
            }
            latest = manifest
            guard let file = manifest.highPack else { return }
            if installed?.version == manifest.version {
                checkedUpToDate = true
                return
            }
            let resume = OfflineBasemap.resume()
            let remaining = file.bytes - (resume?.job.version == manifest.version ? bytesWritten : 0)
            if let free = OfflineBasemap.availableCapacity(), free < remaining + Self.storageMargin {
                errorMessage = L("Yeterli boş alan yok: %@ gerekli, %@ boş.",
                                 Self.format(remaining + Self.storageMargin), Self.format(free))
                return
            }
            if isExpensive, file.bytes > Self.cellularConfirmBytes {
                pendingCellular = manifest
                return
            }
            start(manifest)
        }
    }

    /// Hücresel veri onayı verildi.
    func confirmCellular(_ manifest: BasemapManifest) {
        pendingCellular = nil
        start(manifest)
    }

    func cancelPending() {
        pendingCellular = nil
    }

    private func start(_ manifest: BasemapManifest) {
        guard let session, let file = manifest.highPack, let url = URL(string: file.url) else { return }
        let job = BasemapDownloadJob(version: manifest.version, attribution: manifest.attribution, file: file)
        let task: URLSessionDownloadTask
        if let r = OfflineBasemap.resume(), r.job == job {
            task = session.downloadTask(withResumeData: r.data)
        } else {
            OfflineBasemap.clearResume()
            bytesWritten = 0
            var req = URLRequest(url: url)
            req.setValue("AvHaritasi/1.0 (+https://github.com/oguzbay-del/harita-veri; iOS)", forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: req)
        }
        task.taskDescription = job.encoded
        task.countOfBytesClientExpectsToReceive = file.bytes
        bytesExpected = file.bytes
        isDownloading = true
        errorMessage = nil
        checkedUpToDate = false
        task.resume()
    }

    /// İndirmeyi durdur; alınan kısım saklanır ("Kaldığı yerden devam et").
    func cancelDownload() {
        guard let session else { return }
        isDownloading = false
        session.getAllTasks { tasks in
            for case let t as URLSessionDownloadTask in tasks {
                let job = BasemapDownloadJob(encoded: t.taskDescription)
                t.cancel(byProducingResumeData: { data in
                    if let data, let job { OfflineBasemap.saveResume(data, job: job) }
                    Task { @MainActor in OfflineMapStore.shared.hasResumeData = OfflineBasemap.resume() != nil }
                })
            }
        }
    }

    /// İndirilen ayrıntılı paketi ve yarım indirmeyi sil.
    func deleteDownloaded() {
        if isDownloading { cancelDownload() }
        OfflineBasemap.removeInstalled()
        hasResumeData = false
        bytesWritten = 0
        checkedUpToDate = false
        reloadInstalled()
        revision += 1
    }

    private func finished(_ result: Result<InstalledBasemap, OfflineBasemap.InstallError>) {
        isDownloading = false
        isVerifying = false
        switch result {
        case .success:
            errorMessage = nil
            hasResumeData = false
            reloadInstalled()
            checkedUpToDate = installed?.version == latest?.version
            revision += 1
        case .failure(let e):
            errorMessage = e.message
        }
    }

    private func failed(_ message: String, cancelled: Bool, resumable: Bool) {
        isDownloading = false
        isVerifying = false
        hasResumeData = resumable
        if cancelled { return }
        errorMessage = L("İndirme yarıda kaldı: %@", message)
            + (resumable ? " " + L("Kaldığı yerden devam edebilirsiniz.") : "")
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension OfflineMapStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            let store = OfflineMapStore.shared
            store.isDownloading = true
            store.bytesWritten = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { store.bytesExpected = totalBytesExpectedToWrite }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        Task { @MainActor in OfflineMapStore.shared.bytesWritten = fileOffset }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in OfflineMapStore.shared.isVerifying = true }
        let result: Result<InstalledBasemap, OfflineBasemap.InstallError>
        if let job = BasemapDownloadJob(encoded: downloadTask.taskDescription) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            result = OfflineBasemap.install(downloadedFile: location, job: job, httpStatus: status)
        } else {
            result = .failure(.badFile)
        }
        Task { @MainActor in OfflineMapStore.shared.finished(result) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if let data, let job = BasemapDownloadJob(encoded: task.taskDescription) {
            OfflineBasemap.saveResume(data, job: job)
        }
        let resumable = data != nil || OfflineBasemap.resume() != nil
        let cancelled = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
        let message = ns.localizedDescription
        Task { @MainActor in OfflineMapStore.shared.failed(message, cancelled: cancelled, resumable: resumable) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let store = OfflineMapStore.shared
            store.backgroundCompletion?()
            store.backgroundCompletion = nil
        }
    }
}

/// Arka planda biten indirme için iOS uygulamayı uyandırınca oturumu yeniden bağlar; ayrıca
/// bildirim merkezinin temsilcisi (AlertNotifier.swift: kilitliyken öndeki uyarı banner'ı).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == OfflineMapStore.sessionIdentifier else { completionHandler(); return }
        OfflineMapStore.shared.backgroundCompletion = completionHandler
    }
}
