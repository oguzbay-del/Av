import CoreLocation
import XCTest
@testable import AvHaritasi

/// Başarım ölçümleri: `Assessment.evaluate` (her konum güncellemesinde ana iş parçacığında çalışır)
/// ve `HuntingMap.nearest(within: 3000)` (güvenli daire ve "en yakın yasak alan" için).
///
/// Karar eşiği: CI simülatöründe değerlendirme başına > 8 ms ise değerlendirmeyi ana iş
/// parçacığından almak gerekir. Sonuçlar günlükte `BENCH` satırları olarak basılır.
final class PerformanceTests: XCTestCase {
    private let date = TestData.istanbul("2026-10-07T09:30")
    private let settings = EvaluationSettings()

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    /// Her nokta için `rounds` tekrar; nokta başına ortalama, en kötü nokta ve genel ortalama (ms).
    private func profile(rounds: Int, _ body: (CLLocationCoordinate2D) -> Void) -> (mean: Double, worst: Double, perPoint: [Double]) {
        let clock = ContinuousClock()
        for c in Points.benchmark { body(c) }   // ısınma (önbellekler, tembel yüklemeler)
        var perPoint: [Double] = []
        for c in Points.benchmark {
            let d = clock.measure { for _ in 0..<rounds { body(c) } }
            perPoint.append(Self.ms(d) / Double(rounds))
        }
        let mean = perPoint.reduce(0, +) / Double(perPoint.count)
        return (mean, perPoint.max() ?? 0, perPoint)
    }

    private func report(_ name: String, _ r: (mean: Double, worst: Double, perPoint: [Double])) {
        let list = zip(Points.benchmark, r.perPoint)
            .map { String(format: "%.5f,%.5f=%.2f", $0.0.latitude, $0.0.longitude, $0.1) }
            .joined(separator: " ")
        #if DEBUG
        let config = "Debug -Onone"
        #else
        let config = "Release"
        #endif
        print(String(format: "BENCH %@ [%@]: ortalama %.3f ms, en kötü nokta %.3f ms (20 nokta)", name, config, r.mean, r.worst))
        print("BENCH \(name) nokta başına (ms): \(list)")
        XCTContext.runActivity(named: String(format: "%@: ortalama %.3f ms, en kötü %.3f ms", name, r.mean, r.worst)) { _ in }
    }

    func testEvaluateTimings() throws {
        let ctx = try TestData.context()
        let r = profile(rounds: 5) { c in
            _ = Assessment.evaluate(c, accuracy: 10, at: date, context: ctx, settings: settings)
        }
        report("Assessment.evaluate", r)
        let verdict = r.worst > 8 ? "EŞİK AŞILDI (> 8 ms): ana iş parçacığından almak önerilir" : "eşiğin altında (≤ 8 ms)"
        print("BENCH karar: \(verdict)")
    }

    func testNearestTimings() throws {
        let map = try TestData.context().map
        let r = profile(rounds: 5) { c in
            _ = map.nearest(to: c, within: 3_000) { $0.status == .yasak }
        }
        report("HuntingMap.nearest(3000)", r)
    }

    func testMeasureEvaluate20Points() throws {
        let ctx = try TestData.context()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            for c in Points.benchmark {
                _ = Assessment.evaluate(c, accuracy: 10, at: date, context: ctx, settings: settings)
            }
        }
    }

    func testMeasureNearest20Points() throws {
        let map = try TestData.context().map
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            for c in Points.benchmark {
                _ = map.nearest(to: c, within: 3_000) { $0.status == .yasak }
            }
        }
    }
}
