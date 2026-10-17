import XCTest
@testable import AvHaritasi

/// Mevsim ön bilgisi (fotoğraf modeli olasılıklarının haftaya göre ağırlıklandırılması).
final class SeasonalPriorTests: XCTestCase {
    private let always = String(repeating: "1", count: 48)
    private let never = String(repeating: "0", count: 48)
    /// Yalnızca 11–38. haftalar (yaz göçmeni, ör. arıkuşu).
    private let summer = String(repeating: "0", count: 10) + String(repeating: "1", count: 28) + String(repeating: "0", count: 10)

    func testOccurrenceSmoothsAroundWeekAndWraps() {
        XCTAssertEqual(SeasonalPrior.occurrence(weeks: always, week: 1), 1)
        XCTAssertEqual(SeasonalPrior.occurrence(weeks: never, week: 20), 0)
        XCTAssertEqual(SeasonalPrior.occurrence(weeks: summer, week: 2), 0)
        XCTAssertEqual(SeasonalPrior.occurrence(weeks: summer, week: 24), 1)
        // 11. hafta göç sınırı: 9, 10 yok; 11, 12, 13 var → 3/5
        XCTAssertEqual(SeasonalPrior.occurrence(weeks: summer, week: 11) ?? -1, 0.6, accuracy: 1e-9)
        // Yıl döngüsü: 48. haftanın komşuları 1. ve 2. haftalar
        let lastWeeks = String(repeating: "0", count: 46) + "11"
        XCTAssertEqual(SeasonalPrior.occurrence(weeks: "1" + String(repeating: "0", count: 47), week: 48) ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(SeasonalPrior.occurrence(weeks: lastWeeks, week: 1) ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertNil(SeasonalPrior.occurrence(weeks: "101", week: 1), "48 karakter değilse ön bilgi yok")
    }

    func testOutOfSeasonIsDownWeightedButNeverRemoved() {
        let probs = ["a": 0.5, "b": 0.5]
        let out = SeasonalPrior.apply(probs) { $0 == "a" ? 1 : 0 }
        let a = out["a"] ?? 0, b = out["b"] ?? 0
        XCTAssertGreaterThan(a, b)
        XCTAssertGreaterThan(b, 0, "Mevsim dışı tür silinmez")
        XCTAssertEqual(b / a, SeasonalPrior.floor, accuracy: 1e-9)
        XCTAssertEqual(a + b, 1, accuracy: 1e-9, "Toplam korunur")
    }

    func testUnknownSpeciesAndUniformSeasonUnchanged() {
        let probs = ["a": 0.7, "b": 0.2, "c": 0.1]
        let unknown = SeasonalPrior.apply(probs) { _ in nil }
        let allIn = SeasonalPrior.apply(probs) { _ in 1 }
        for (k, v) in probs {
            XCTAssertEqual(unknown[k] ?? 0, v, accuracy: 1e-9)
            XCTAssertEqual(allIn[k] ?? 0, v, accuracy: 1e-9)
        }
        XCTAssertEqual(SeasonalPrior.apply([:]) { _ in 0 }, [:])
    }

    func testStrongOutOfSeasonPredictionCanStillWin() {
        // Model çok eminse mevsim dışı tür yine ilk sırada kalır (yumuşak ön bilgi)
        let out = SeasonalPrior.apply(["rare": 0.9, "common": 0.1]) { $0 == "rare" ? 0 : 1 }
        XCTAssertGreaterThan(out["rare"] ?? 0, out["common"] ?? 0)
    }

    func testIstanbulListBeeEaterIsSummerOnly() {
        // Uygulama paketindeki tür listesi: arıkuşu yazın var, ocakta yok; yeşilbaş her zaman
        let january = BirdNETWeek.week(for: TestData.istanbul("2027-01-10T09:00"))
        let july = BirdNETWeek.week(for: TestData.istanbul("2026-07-10T09:00"))
        XCTAssertEqual(IstanbulSpecies.occurrence("Merops apiaster", week: january), 0)
        XCTAssertEqual(IstanbulSpecies.occurrence("Merops apiaster", week: july), 1)
        XCTAssertEqual(IstanbulSpecies.occurrence("Anas platyrhynchos", week: january), 1)
        XCTAssertNil(IstanbulSpecies.occurrence("Yok yok", week: july))
    }
}

/// Videoda en iyi 10 sn'lik bölümün seçimi ve örnekleme.
final class VideoWindowSelectorTests: XCTestCase {
    private func frames(_ presence: [Double], sharp: Double = 100) -> [FrameQuality] {
        presence.enumerated().map { FrameQuality(time: Double($0.offset), presence: $0.element, sharpness: sharp) }
    }

    func testShortVideoStartsAtZero() {
        XCTAssertEqual(VideoWindowSelector.bestStart(frames([1, 1, 1]), duration: 8), 0)
        XCTAssertEqual(VideoWindowSelector.bestStart([], duration: 60), 0)
        XCTAssertEqual(VideoWindowSelector.clamp(start: 5, duration: 8), 0)
    }

    func testPicksWindowWithBird() {
        // 40 sn video; kuş 22–29. saniyelerde
        var p = [Double](repeating: 0, count: 40)
        for i in 22...29 { p[i] = 0.9 }
        let start = VideoWindowSelector.bestStart(frames(p), duration: 40)
        XCTAssertLessThanOrEqual(start, 22)
        XCTAssertGreaterThanOrEqual(start + VideoWindowSelector.window, 30)
    }

    func testWindowNeverRunsPastEnd() {
        var p = [Double](repeating: 0, count: 30)
        p[29] = 1
        let start = VideoWindowSelector.bestStart(frames(p), duration: 30)
        XCTAssertEqual(start, 20)
        XCTAssertEqual(VideoWindowSelector.clamp(start: 100, duration: 30), 20)
        XCTAssertEqual(VideoWindowSelector.clamp(start: -3, duration: 30), 0)
    }

    func testSharpnessBreaksTieBetweenBirdSegments() {
        // İki bölümde de kuş var; ikincisi keskin
        var f: [FrameQuality] = []
        for t in 0..<40 {
            let bird = (0..<10).contains(t) || (25..<35).contains(t)
            f.append(FrameQuality(time: Double(t), presence: bird ? 0.8 : 0, sharpness: t >= 25 ? 400 : 50))
        }
        XCTAssertEqual(VideoWindowSelector.bestStart(f, duration: 40), 25)
    }

    func testScanIsCappedAtFiveMinutes() {
        let times = VideoWindowSelector.scanTimes(duration: 3_600)
        XCTAssertEqual(times.count, 300)
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(VideoWindowSelector.clamp(start: 1_000, duration: 3_600), 290)
    }

    func testSampleTimesStayInsideWindow() {
        let t = VideoWindowSelector.sampleTimes(start: 12, duration: 60)
        XCTAssertEqual(t.count, 20) // 2 kare/sn
        XCTAssertTrue(t.allSatisfy { $0 >= 12 && $0 < 22 })
        let short = VideoWindowSelector.sampleTimes(start: 0, duration: 4)
        XCTAssertEqual(short.count, 8)
        XCTAssertTrue(short.allSatisfy { $0 < 4 })
    }

    func testBestFramesPrefersBirdAndSharpness() {
        let f = [FrameQuality(time: 0, presence: 0, sharpness: 500),
                 FrameQuality(time: 1, presence: 0.9, sharpness: 500),
                 FrameQuality(time: 2, presence: 0.9, sharpness: 50),
                 FrameQuality(time: 3, presence: 0.5, sharpness: 400)]
        let best = VideoWindowSelector.bestFrames(f, count: 2)
        XCTAssertEqual(best.map(\.frame.time), [1, 3], "Zamana göre sıralı en iyi iki kare")
        let s = VideoWindowSelector.scores(f)
        XCTAssertTrue(s.allSatisfy { $0 > 0 && $0 <= 1 })
    }
}

/// Keskinlik ölçüsü.
final class SharpnessTests: XCTestCase {
    func testFlatImageHasZeroAndEdgesIncrease() {
        let w = 16, h = 16
        let flat = [UInt8](repeating: 128, count: w * h)
        XCTAssertEqual(Sharpness.laplacianVariance(flat, width: w, height: h), 0)
        let checker = (0..<(w * h)).map { i -> UInt8 in ((i % w) + (i / w)) % 2 == 0 ? 255 : 0 }
        let soft = (0..<(w * h)).map { i -> UInt8 in UInt8((i % w) * 16) } // yumuşak geçiş
        let sharp = Sharpness.laplacianVariance(checker, width: w, height: h)
        XCTAssertGreaterThan(sharp, Sharpness.laplacianVariance(soft, width: w, height: h))
        XCTAssertEqual(Sharpness.laplacianVariance([], width: 0, height: 0), 0)
    }
}

/// Karelerin tahminlerinin birleştirilmesi.
final class FrameAggregatorTests: XCTestCase {
    private func p(_ label: String, _ prob: Double) -> BirdPrediction {
        BirdPrediction(label: label, scientificName: label, commonName: label, probability: prob, source: .speciesModel)
    }

    func testWeightedMeanTreatsMissingAsZero() {
        let out = FrameAggregator.aggregate([
            ([p("A", 0.8), p("B", 0.2)], 3),
            ([p("B", 0.9)], 1),
        ])
        XCTAssertEqual(out.map(\.label), ["A", "B"])
        XCTAssertEqual(out[0].probability, 0.6, accuracy: 1e-9)   // 0,8 · 3/4
        XCTAssertEqual(out[1].probability, 0.375, accuracy: 1e-9) // 0,2 · 3/4 + 0,9 · 1/4
    }

    func testZeroWeightsFallBackToEqualAndEmptyFramesIgnored() {
        let out = FrameAggregator.aggregate([([p("A", 0.4)], 0), ([p("A", 0.8)], 0), ([], 5)])
        XCTAssertEqual(out.first?.probability ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertTrue(FrameAggregator.aggregate([]).isEmpty)
    }

    func testMaxResults() {
        let out = FrameAggregator.aggregate([([p("A", 0.5), p("B", 0.3), p("C", 0.1), p("D", 0.05)], 1)], maxResults: 3)
        XCTAssertEqual(out.map(\.label), ["A", "B", "C"])
    }
}

/// Görüntü ve ses sonuçlarının birleştirilmesi.
final class VideoFusionTests: XCTestCase {
    private func img(_ sci: String?, _ prob: Double) -> BirdPrediction {
        BirdPrediction(label: sci ?? "bird", scientificName: sci, commonName: sci ?? "Kuş", probability: prob,
                       source: sci == nil ? .generalModel : .speciesModel)
    }

    private func snd(_ sci: String, _ conf: Double) -> BirdDetection {
        BirdDetection(scientificName: sci, commonName: sci, confidence: conf, start: 0, end: 3, source: .onDevice)
    }

    func testAgreementBoostsConfidence() {
        let f = VideoFusion.fuse(image: [img("Anas platyrhynchos", 0.6)], sound: [snd("Anas platyrhynchos", 0.7)])
        XCTAssertEqual(f.agreement, .agree)
        XCTAssertEqual(f.combined?.scientificName, "Anas platyrhynchos")
        XCTAssertEqual(f.combined?.probability ?? 0, 0.88, accuracy: 1e-9)
        XCTAssertEqual(f.combined?.source, .videoCombined)
        XCTAssertGreaterThan(f.combined?.probability ?? 0, 0.7)
    }

    func testDisagreementKeepsBothSeparate() {
        let f = VideoFusion.fuse(image: [img("Anas platyrhynchos", 0.8)], sound: [snd("Anser anser", 0.9)])
        XCTAssertEqual(f.agreement, .disagree)
        XCTAssertNil(f.combined)
        XCTAssertEqual(f.image.count, 1)
        XCTAssertEqual(f.sound.count, 1)
    }

    func testGeneralGroupNeverAgrees() {
        let f = VideoFusion.fuse(image: [img(nil, 0.9)], sound: [snd("Anas platyrhynchos", 0.9)])
        XCTAssertEqual(f.agreement, .disagree)
    }

    func testSingleSource() {
        XCTAssertEqual(VideoFusion.fuse(image: [img("Anas platyrhynchos", 0.8)], sound: []).agreement, .single)
        XCTAssertEqual(VideoFusion.fuse(image: [], sound: [snd("Anser anser", 0.9)]).agreement, .single)
        XCTAssertEqual(VideoFusion.combine(0, 0), 0)
        XCTAssertEqual(VideoFusion.combine(1, 0.2), 1)
    }
}
