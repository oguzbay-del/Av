import Foundation

/// Kullanıcının tüfekleri (en çok 6). Yalnızca bu cihazda: Application Support/tufekler.json,
/// iCloud/iTunes yedeğinden hariç (`isExcludedFromBackup`), dosya koruması "ilk kilit açmadan sonra".
/// Hiçbir sunucuya gönderilmez; kullanım istatistiğinde yalnızca özelliğin açıldığı sayılır (`tufek_onerisi`).
@MainActor
final class FirearmStore: ObservableObject {
    static let maxCount = 6

    enum StoreError: Error, Equatable {
        case limitReached
        case invalid
    }

    @Published private(set) var items: [Firearm] = []

    let fileURL: URL

    /// Uygulama: Application Support/tufekler.json.
    convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(directory: dir)
    }

    /// Testler için ayrı klasör.
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("tufekler.json")
        if let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([Firearm].self, from: data) {
            items = Array(list.prefix(Self.maxCount))
        }
    }

    /// Yeni tüfek eklenebilir mi (en çok 6).
    static func canAdd(count: Int) -> Bool { count < maxCount }

    var canAdd: Bool { Self.canAdd(count: items.count) }

    /// Ekler ya da aynı kimlikli tüfeği günceller.
    func save(_ firearm: Firearm) throws {
        guard firearm.isValid else { throw StoreError.invalid }
        var f = firearm
        f.name = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = items.firstIndex(where: { $0.id == f.id }) {
            items[i] = f
        } else {
            guard canAdd else { throw StoreError.limitReached }
            items.append(f)
        }
        persist()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Yalnızca DEBUG ekran görüntüleri ve testler: listeyi bütünüyle değiştir.
    func replaceAll(_ list: [Firearm]) {
        items = Array(list.prefix(Self.maxCount))
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            // Disk hatası: bellekteki liste korunur, bir sonraki kayıtta yeniden denenir
        }
    }
}
