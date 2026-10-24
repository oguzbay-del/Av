#if DEBUG
import CoreLocation
import Foundation

/// Yalnızca DEBUG derlemesi: App Store ekran görüntüleri için açılış argümanları
/// (tools/appstore_screenshots.sh). App Store derlemesinde bu dosya derlenmez.
///
/// - `-demoIsaretler`: demo yürüyüşünün (Sarıkavak) yakınına örnek işaretler: Araç, Pusu, Av düştü
/// - `-acYonlendir <tür>`: o türdeki işarete tam ekran yönlendirmeyi aç (`arac`, `pusu`, `avDustu`, `su`, `not`)
/// - Saha modu ve gece teması kaydedilmeden, UserDefaults argüman alanıyla açılır: `-fieldMode YES -nightRedMode on`
///   (uygulamanın kendisi yazsaydı simülatörde `defaults write` ile geri alınamıyor, sonraki sahneler koyu kalıyordu)
/// - `-demoHassasiyet <m>`: demo yürüyüşünün GPS hassasiyeti (varsayılan 5 m)
/// - `-demoDurak <adım>`: demo yürüyüşü bu adımda durur (adım ~20 m, saniyede bir)
/// - `-haritaAcikligi <m>`: haritanın konuma ilk yakınlaşması (varsayılan 6000 m)
/// - `-kusDemo foto|video`: Kuş Tanı sekmesi fotoğraf ekranında açılır ve hazır sonuç gösterir
///   (`Documents/ekran_demo/` içindeki örnek görüntüyle; simülatörde kamera/galeri seçimi yok)
/// - `-tanitimSayfa <n>`: ilk açılış tanıtımı bu sayfadan başlar (0'dan)
/// - `-sorgula <enlem,boylam>`: haritada bu nokta sorgulanmış olarak açılır (uzun basma kartı)
/// - `-demoCipiGizle`: haritadaki "Demo konumu · kapat" çipi gizlenir (demo yalnızca sahneyi kurar)
/// - `-demoKonumYasi <sn>`: demo yürüyüşünün konumları bu kadar eski gelir ("Konum güncel değil" uyarısı)
/// - `-ayarlarKaydir <kimlik>`: Ayarlar bu satıra kaydırılmış açılır (`takip`, `cevrimici`, `istatistik`)
/// - `-yardimAc`: Ayarlar sekmesi Yardım (kullanım kılavuzu) ekranıyla açılır
/// Kılavuz sahneleri (web sitesi görselleri) için `KUME=kilavuz tools/appstore_screenshots.sh`.
enum ScreenshotArguments {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func has(_ flag: String) -> Bool { arguments.contains(flag) }

    static func value(_ flag: String) -> String? {
        let a = arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count, !a[i + 1].hasPrefix("-") else { return nil }
        return a[i + 1]
    }

    static func double(_ flag: String) -> Double? { value(flag).flatMap(Double.init) }

    static var birdDemo: String? { value("-kusDemo") }

    static var guideKind: Waypoint.Kind? { value("-acYonlendir").flatMap(Waypoint.Kind.init(rawValue:)) }

    /// Örnek işaretler: sabit koordinatlar (demo yürüyüşü 41.02446, 29.65804'den güneybatıya).
    static let sampleWaypoints: [(Waypoint.Kind, Double, Double)] = [
        (.arac, 41.02680, 29.66250),
        (.pusu, 41.02310, 29.65520),
        (.avDustu, 41.02205, 29.65880),
    ]

    /// `-sorgula 41.1,29.5` → koordinat.
    static var inspectCoordinate: CLLocationCoordinate2D? {
        guard let parts = value("-sorgula")?.split(separator: ",").compactMap({ Double($0) }), parts.count == 2 else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }

    @MainActor
    static func apply(to model: AppModel) {
        if let c = inspectCoordinate { model.inspectedCoordinate = c }
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
