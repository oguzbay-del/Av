import Foundation
import Network
import os

/// İnternet bağlantısı durumu (NWPathMonitor). Herhangi bir iş parçacığından okunabilir:
/// karo katmanı internet yokken zaman aşımı beklemeden önbelleği kullanır, hava durumu
/// boşuna denenmez. Arayüz için gözlenebilir kopya `OfflineMapStore`dadır.
final class NetworkState: @unchecked Sendable {
    static let shared = NetworkState()

    struct Status: Sendable, Equatable {
        /// Bağlantı var mı (ilk ölçüm gelene kadar var sayılır; boşuna "çevrimdışı" denmesin).
        var online = true
        /// Hücresel veri / kişisel erişim noktası gibi ücretli bağlantı.
        var expensive = false
    }

    private let state = OSAllocatedUnfairLock(initialState: Status())
    private let monitor = NWPathMonitor()
    private let observers = OSAllocatedUnfairLock<[@Sendable (Status) -> Void]>(initialState: [])

    var status: Status { state.withLock { $0 } }
    var isOnline: Bool { status.online }

    private init() {
        monitor.pathUpdateHandler = { [state, observers] path in
            let new = Status(online: path.status == .satisfied, expensive: path.isExpensive)
            let changed = state.withLock { s -> Bool in
                defer { s = new }
                return s != new
            }
            guard changed else { return }
            for o in observers.withLock({ $0 }) { o(new) }
        }
        monitor.start(queue: DispatchQueue(label: "av.ag-durumu", qos: .utility))
    }

    /// Durum değiştikçe çağrılır (izleme kuyruğunda).
    func observe(_ handler: @escaping @Sendable (Status) -> Void) {
        observers.withLock { $0.append(handler) }
        handler(status)
    }
}
