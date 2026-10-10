import CoreLocation
import Foundation
import WidgetKit

/// Av durumunu App Group'a (araçlar, Siri kısayolları) yazar ve araç zaman çizelgelerini
/// seyrek yeniletir: seviye ya da av saati değişince en çok 15 sn'de bir, diğer
/// değişikliklerde 10 dk'da bir, içerik aynıyken de 25 dk'da bir ("güncel değil" görünmesin).
@MainActor
final class StatusPublisher {
    static let shared = StatusPublisher()

    private var last: StatusSnapshot?
    private var lastSaved = Date.distantPast
    private var lastReload = Date.distantPast
    private var reloadTask: Task<Void, Never>?

    private init() {
        last = StatusSnapshot.load()
    }

    func publish(_ s: StatusSnapshot) {
        let old = last
        let changed = old.map { !s.sameContent(as: $0) } ?? true
        let now = Date()
        guard changed || now.timeIntervalSince(lastSaved) >= 60 else { return }
        last = s
        lastSaved = now
        s.save()

        let urgent = old.map { $0.level != s.level || $0.huntEnd != s.huntEnd || $0.nextHuntStart != s.nextHuntStart } ?? true
        let interval: TimeInterval = urgent ? 15 : changed ? 10 * 60 : 25 * 60
        scheduleReload(after: interval)
    }

    private func scheduleReload(after interval: TimeInterval) {
        let wait = interval - Date().timeIntervalSince(lastReload)
        if wait <= 0 {
            reloadTask?.cancel()
            reloadTask = nil
            reload()
            return
        }
        // Bekleyen daha erken bir yenileme varsa o yeterli
        guard reloadTask == nil || interval <= 15 else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.reloadTask = nil
            self?.reload()
        }
    }

    private func reload() {
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension AppModel {
    /// Şu anki ya da sıradaki iki av günündeki avlanma saatleri (konuma göre).
    func huntWindows(at now: Date) -> [(start: Date, end: Date)] {
        guard let regs, let c = referenceCoordinate else { return [] }
        return regs.upcomingHuntingDays(from: now, count: 3)
            .compactMap { regs.huntingWindow(on: $0.date.addingTimeInterval(12 * 3600), at: c) }
            .filter { $0.end > now }
            .prefix(2)
            .map { $0 }
    }

    /// Paylaşılan (App Group) av durumu.
    var statusSnapshot: StatusSnapshot {
        let a = assessment, near = nearestForbidden, now = AppClock.now()
        let w = huntWindows(at: now)
        return StatusSnapshot(
            level: a.level.rawValue, title: a.title,
            reason: a.checks.first { $0.level == a.level }?.detail ?? a.detail,
            nearest: near.map { L("Yasak alan %@ · %@", Geo.formatDistance($0.distance), Compass.name($0.bearing)) },
            nearestMeters: near?.distance,
            huntStart: w.first?.start, huntEnd: w.first?.end,
            nextHuntStart: w.dropFirst().first?.start, nextHuntEnd: w.dropFirst().first?.end,
            updated: now)
    }
}
