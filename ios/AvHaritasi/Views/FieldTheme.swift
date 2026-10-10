import CoreLocation
import SwiftUI

// MARK: - Saha modu ve gece (kırmızı) teması
//
// Saha modu: eldivenle kullanım için büyük dokunma alanları (≥ 60 pt), büyük durum yazısı, geniş aralıklar.
// Gece (kırmızı): koyu, kırmızı tonlu arayüz ve kısık kırmızı harita örtüsü (gece görüşü korunur).
// Görünümler `\.fieldMode` ve `\.nightRed` ortam değerlerini okur; kök `FieldThemeRoot` ile kurulur.

enum FieldTheme {
    static let fieldModeKey = "fieldMode"
    static let nightModeKey = "nightRedMode"
    /// Saha modunda dokunma alanı alt sınırı (eldiven).
    static let minTarget: CGFloat = 60
    /// Gece temasında vurgu ve yazı rengi (koyu arka planda okunur kırmızı).
    static let nightAccent = Color(rgb: 0xFF6B5E)
    static let nightText = Color(rgb: 0xFF9E94)
}

/// "Gece (kırmızı)" seçeneği.
enum NightRedMode: String, CaseIterable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return L("Otomatik")
        case .on: return L("Hep açık")
        case .off: return L("Kapalı")
        }
    }

    /// Otomatik: gün batımından 30 dk önce ile gün doğumundan 30 dk sonra arası gece sayılır.
    static func isNight(at date: Date, latitude: Double, longitude: Double, calendar: Calendar = .current) -> Bool {
        guard let t = Sun.times(on: date, latitude: latitude, longitude: longitude, calendar: calendar) else { return false }
        return date < t.sunrise.addingTimeInterval(30 * 60) || date > t.sunset.addingTimeInterval(-30 * 60)
    }
}

// MARK: - Durum şeridi renkleri (WCAG ≥ 4.5:1, ContrastTests ile denetlenir)

/// sRGB renk (0xRRGGBB); kontrast hesabı için SwiftUI'den bağımsız.
struct RGB: Equatable, Sendable {
    let hex: UInt32
    var r: Double { Double((hex >> 16) & 0xFF) / 255 }
    var g: Double { Double((hex >> 8) & 0xFF) / 255 }
    var b: Double { Double(hex & 0xFF) / 255 }

    /// WCAG 2.x göreli parlaklık.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Siyah örtüyle karartılmış renk (ör. şerit içindeki kural listesi zemini: %15 siyah).
    func darkened(_ amount: Double) -> RGB {
        func ch(_ v: Double) -> UInt32 { UInt32((v * (1 - amount) * 255).rounded()) }
        return RGB(hex: ch(r) << 16 | ch(g) << 8 | ch(b))
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    var color: Color { Color(rgb: hex) }
}

struct BannerPalette: Sendable {
    let background: RGB
    let foreground: RGB

    /// Gündüz: koyu kırmızı/yeşil/gri üzerinde beyaz, turuncu üzerinde siyah yazı.
    /// Gece: çok koyu zemin üzerinde soluk renkli yazı (göz kamaştırmaz; renk + simge + metin birlikte).
    static func of(_ level: Assessment.Level, night: Bool) -> BannerPalette {
        switch (level, night) {
        case (.danger, false): return .init(background: RGB(hex: 0xB3261E), foreground: RGB(hex: 0xFFFFFF))
        case (.caution, false): return .init(background: RGB(hex: 0xFF9F0A), foreground: RGB(hex: 0x000000))
        case (.safe, false): return .init(background: RGB(hex: 0x1E7B34), foreground: RGB(hex: 0xFFFFFF))
        case (.unknown, false): return .init(background: RGB(hex: 0x48484A), foreground: RGB(hex: 0xFFFFFF))
        case (.danger, true): return .init(background: RGB(hex: 0x4A0A0A), foreground: RGB(hex: 0xFF9E94))
        case (.caution, true): return .init(background: RGB(hex: 0x3D2600), foreground: RGB(hex: 0xFFB866))
        case (.safe, true): return .init(background: RGB(hex: 0x0E2E17), foreground: RGB(hex: 0x8FD9A0))
        case (.unknown, true): return .init(background: RGB(hex: 0x1F1F1F), foreground: RGB(hex: 0xD9A8A8))
        }
    }

    /// Şerit içindeki kural listesinin zemini (%15 siyah örtü).
    var checksBackground: RGB { background.darkened(0.15) }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

// MARK: - Ortam değerleri

private struct FieldModeKey: EnvironmentKey { static let defaultValue = false }
private struct NightRedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Saha modu (eldiven): büyük dokunma alanları ve yazı.
    var fieldMode: Bool {
        get { self[FieldModeKey.self] }
        set { self[FieldModeKey.self] = newValue }
    }
    /// Gece (kırmızı) teması şu an etkin mi.
    var nightRed: Bool {
        get { self[NightRedKey.self] }
        set { self[NightRedKey.self] = newValue }
    }
}

/// Kök görünüme uygulanır: ayarları okuyup ortam değerlerini, koyu/kırmızı temayı kurar.
@MainActor
struct FieldThemeRoot: ViewModifier {
    @Environment(AppModel.self) private var model
    @AppStorage(FieldTheme.fieldModeKey) private var fieldMode = false
    @AppStorage(FieldTheme.nightModeKey) private var nightRaw = NightRedMode.off.rawValue
    /// Otomatik gece kararı dakikada bir yenilenir.
    @State private var now = Date()

    private var isNight: Bool {
        switch NightRedMode(rawValue: nightRaw) ?? .off {
        case .on: return true
        case .off: return false
        case .auto:
            guard let c = model.location?.coordinate ?? model.map?.center else { return false }
            return NightRedMode.isNight(at: now, latitude: c.latitude, longitude: c.longitude)
        }
    }

    func body(content: Content) -> some View {
        let night = isNight
        content
            .environment(\.fieldMode, fieldMode)
            .environment(\.nightRed, night)
            .preferredColorScheme(night ? .dark : nil)
            .tint(night ? FieldTheme.nightAccent : nil)
            .foregroundStyle(night ? AnyShapeStyle(FieldTheme.nightText) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    now = Date()
                }
            }
            // Saha modunda ekran varsayılan olarak açık kalır (kullanıcı Ayarlar'dan kapatabilir)
            .onChange(of: fieldMode) { _, on in
                if on { model.keepScreenOn = true }
            }
    }
}

/// Gece temasında haritanın üstüne kısık kırmızı örtü (dokunmaları geçirir).
struct NightMapDim: View {
    var body: some View {
        Color(red: 0.22, green: 0, blue: 0).opacity(0.55)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Ayarlar ve Katmanlar sayfasında ortak saha modu denetimleri.
struct FieldModeControls: View {
    @AppStorage(FieldTheme.fieldModeKey) private var fieldMode = false
    @AppStorage(FieldTheme.nightModeKey) private var nightRaw = NightRedMode.off.rawValue

    var body: some View {
        Toggle(isOn: $fieldMode) {
            Label("Saha modu (eldiven)", systemImage: "hand.raised.fill")
        }
        Picker(selection: $nightRaw) {
            ForEach(NightRedMode.allCases) { Text($0.title).tag($0.rawValue) }
        } label: {
            Label("Gece (kırmızı)", systemImage: "moon.fill")
        }
    }
}
