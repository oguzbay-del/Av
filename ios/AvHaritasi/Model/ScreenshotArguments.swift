#if DEBUG
import CoreLocation
import Foundation

/// Yalnızca DEBUG derlemesi: App Store ekran görüntüleri için açılış argümanları
/// (tools/appstore_screenshots.sh). App Store derlemesinde bu dosya derlenmez.
///
/// - `-demoIsaretler`: demo yürüyüşünün (Sarıkavak) yakınına örnek işaretler: Araç, Pusu, Av düştü
/// - `-acYonlendir <tür>`: o türdeki işarete tam ekran yönlendirmeyi aç (`arac`, `pusu`, `avDustu`, `su`, `not`)
/// - `-sahaModu`, `-geceKirmizi`: saha modunu ve gece (kırmızı) temasını aç (ayar olarak kaydedilir)
/// - `-demoHassasiyet <m>`: demo yürüyüşünün GPS hassasiyeti (varsayılan 5 m)
/// - `-demoDurak <adım>`: demo yürüyüşü bu adımda durur (adım ~20 m, saniyede bir)
/// - `-haritaAcikligi <m>`: haritanın konuma ilk yakınlaşması (varsayılan 6000 m)
enum ScreenshotArguments {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func has(_ flag: String) -> Bool { arguments.contains(flag) }

    static func value(_ flag: String) -> String? {
        let a = arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count, !a[i + 1].hasPrefix("-") else { return nil }
        return a[i + 1]
    }

    static func double(_ flag: String) -> Double? { value(flag).flatMap(Double.init) }

    static var guideKind: Waypoint.Kind? { value("-acYonlendir").flatMap(Waypoint.Kind.init(rawValue:)) }

    /// Örnek işaretler: sabit koordinatlar (demo yürüyüşü 41.02446, 29.65804'den güneybatıya).
    static let sampleWaypoints: [(Waypoint.Kind, Double, Double)] = [
        (.arac, 41.02680, 29.66250),
        (.pusu, 41.02310, 29.65520),
        (.avDustu, 41.02205, 29.65880),
    ]

    @MainActor
    static func apply(to model: AppModel) {
        let d = UserDefaults.standard
        if has("-sahaModu") { d.set(true, forKey: FieldTheme.fieldModeKey) }
        if has("-geceKirmizi") { d.set(NightRedMode.on.rawValue, forKey: FieldTheme.nightModeKey) }
        if has("-demoIsaretler") { seed(model.waypoints) }
        if let k = guideKind, let w = model.waypoints.items.first(where: { $0.kind == k }) {
            model.waypoints.guidingID = w.id
        }
    }

    /// Önceki açılışlarda eklenen örnekleri (aynı koordinat) kaldırıp güncel dilde yeniden ekler.
    @MainActor
    private static func seed(_ store: WaypointStore) {
        for w in store.items where sampleWaypoints.contains(where: { $0.1 == w.lat && $0.2 == w.lon }) {
            store.delete(w.id)
        }
        let base = Date().addingTimeInterval(-3 * 3_600)
        for (i, s) in sampleWaypoints.enumerated() {
            store.add(kind: s.0, name: s.0.title, coordinate: CLLocationCoordinate2D(latitude: s.1, longitude: s.2),
                      date: base.addingTimeInterval(Double(i) * 1_800))
        }
    }
}
#endif
