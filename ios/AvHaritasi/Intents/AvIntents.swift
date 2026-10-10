import AppIntents
import SwiftUI

/// Siri, Kısayollar, Spotlight ve Eylem düğmesi (Action button) için uygulama eylemleri.
/// Uygulama açılmadan, internetsiz çalışır: uygulama bellekteyse ve konum güncelse canlı
/// durum, değilse App Group'taki son durum (StatusSnapshot) okunur.
@MainActor
enum IntentStatus {
    /// Canlı model (konum güncelse) ya da kaydedilmiş son durum.
    static func current() -> StatusSnapshot? {
        if let m = AppLock.shared.model, m.location != nil, !m.locationStale, m.assessment.level != .unknown {
            return m.statusSnapshot
        }
        return StatusSnapshot.load()
    }

    /// Avlanma saatleri için: model haritayı yüklediyse (konum olmasa da) ondan hesapla.
    static func huntWindow(at now: Date) -> (start: Date, end: Date, active: Bool)? {
        if let m = AppLock.shared.model, m.regs != nil, m.referenceCoordinate != nil {
            return m.statusSnapshot.huntWindow(at: now)
        }
        return StatusSnapshot.load()?.huntWindow(at: now)
    }

    static func time(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.locale = AppLocale.current
        f.timeZone = TimeZone(identifier: "Europe/Istanbul")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = f.timeZone
        f.dateFormat = cal.isDate(d, inSameDayAs: now) ? "HH:mm" : "d MMMM EEEE HH:mm"
        return f.string(from: d)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        var cal = Calendar.current
        cal.locale = AppLocale.current
        f.calendar = cal
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .full
        return f.string(from: max(60, seconds)) ?? ""
    }

    static func ago(_ d: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = AppLocale.current
        return f.localizedString(for: d, relativeTo: now)
    }
}

struct AvDurumuIntent: AppIntent {
    static let title: LocalizedStringResource = "Burada avlanabilir miyim?"
    static let description = IntentDescription("Bulunduğunuz yerin av durumunu, gerekçesini ve en yakın ava yasak alanı söyler.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let now = AppClock.now()
        guard let s = IntentStatus.current() else {
            let text = L("Henüz av durumu yok. Av Haritası'nı bir kez açıp konum izni verin.")
            return .result(dialog: IntentDialog(stringLiteral: text), view: DurumSnippet(snapshot: nil, now: now))
        }
        var parts: [String] = []
        if s.isStale(at: now) { parts.append(L("Son bilinen durum (%@):", IntentStatus.ago(s.updated, now: now))) }
        parts.append(s.title + ".")
        if !s.reason.isEmpty { parts.append(s.reason) }
        if let m = s.nearestMeters { parts.append(L("En yakın yasak alan %@ uzakta.", Geo.formatDistance(m))) }
        let text = parts.joined(separator: " ")
        return .result(dialog: IntentDialog(stringLiteral: text), view: DurumSnippet(snapshot: s, now: now))
    }
}

struct AvSaatiIntent: AppIntent {
    static let title: LocalizedStringResource = "Av saati ne zaman bitiyor?"
    static let description = IntentDescription("Bugünkü avlanma saatinin ne zaman bittiğini ya da sıradaki av saatini söyler.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = AppClock.now()
        let text: String
        if let w = IntentStatus.huntWindow(at: now) {
            if w.active {
                text = L("Av saati %@ itibarıyla bitiyor (%@ kaldı).", IntentStatus.time(w.end, now: now),
                         IntentStatus.duration(w.end.timeIntervalSince(now)))
            } else {
                text = L("Şu an avlanma saati dışında. Sonraki av saati: %@ – %@.",
                         IntentStatus.time(w.start, now: now), IntentStatus.time(w.end, now: w.start))
            }
        } else {
            text = L("Av saati hesaplanamadı. Av Haritası'nı bir kez açın.")
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Siri ve Kısayollar'daki görsel yanıt.
struct DurumSnippet: View {
    let snapshot: StatusSnapshot?
    let now: Date

    var body: some View {
        let style = AvDurumStili(level: snapshot?.level ?? 0, stale: snapshot?.isStale(at: now) ?? true)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.symbol)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(style.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot?.title ?? L("Veri bekleniyor")).font(.headline)
                if let r = snapshot?.reason, !r.isEmpty {
                    Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let n = snapshot?.nearest {
                    Label(n, systemImage: "location.north.fill").font(.caption.bold()).foregroundStyle(.red)
                }
                if let w = snapshot?.huntWindow(at: now) {
                    Label(w.active ? L("Av saati bitişi %@", IntentStatus.time(w.end, now: now))
                                   : L("Sonraki av saati %@", IntentStatus.time(w.start, now: now)),
                          systemImage: "clock")
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}

/// Siri ifadeleri (İngilizcesi AppShortcuts.xcstrings'te; `tools/l10n.py` üretir).
/// Eylem düğmesinde "Kısayol" seçilince bu eylemler listede çıkar.
struct AvKisayollari: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AvDurumuIntent(),
            phrases: [
                "\(.applicationName) burada avlanabilir miyim",
                "\(.applicationName) av durumu",
                "\(.applicationName) ile av durumunu sor",
            ],
            shortTitle: "Av durumu",
            systemImageName: "checkmark.shield")
        AppShortcut(
            intent: AvSaatiIntent(),
            phrases: [
                "\(.applicationName) av saati ne zaman bitiyor",
                "\(.applicationName) av saati",
            ],
            shortTitle: "Av saati",
            systemImageName: "clock")
    }

    static var shortcutTileColor: ShortcutTileColor { .lime }
}
