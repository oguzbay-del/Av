import CoreGraphics
import XCTest
@testable import AvHaritasi

/// Kuş bulucu çıktısının çözümü (DetectionDecoder) ve birden fazla kuşun sonucu.
final class BirdDetectionTests: XCTestCase {
    private func assertRect(_ r: CGRect?, _ e: CGRect, accuracy: CGFloat = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        guard let r else { return XCTFail("kutu yok", file: file, line: line) }
        XCTAssertEqual(r.minX, e.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(r.minY, e.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(r.width, e.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(r.height, e.height, accuracy: accuracy, file: file, line: line)
    }

    func testLetterboxScaleMatchesConversionTool() {
        // 500×375 → 640×480 (tools/kus_bulucu/ortak.py ile aynı)
        let lb = DetectionDecoder.letterbox(width: 500, height: 375)
        XCTAssertEqual(lb.scale, 1.28, accuracy: 1e-9)
        XCTAssertEqual(lb.width, 640)
        XCTAssertEqual(lb.height, 480)
        let tall = DetectionDecoder.letterbox(width: 1000, height: 2000)
        XCTAssertEqual(tall.width, 320)
        XCTAssertEqual(tall.height, 640)
        XCTAssertEqual(DetectionDecoder.letterbox(width: 0, height: 10).scale, 0)
    }

    func testDecodeMapsLetterboxToVisionCoordinates() {
        // Kare görüntü: girdi karesi = görüntü; üst yarının ortasında kutu → Vision'da (sol alt köken) üstte
        let square = DetectionDecoder.decode(boxes: [0.5, 0.25, 0.2, 0.1], scores: [0.9], imageWidth: 640, imageHeight: 640)
        XCTAssertEqual(square.count, 1)
        assertRect(square.first?.rect, CGRect(x: 0.4, y: 0.7, width: 0.2, height: 0.1))
        XCTAssertEqual(square.first?.score ?? 0, 0.9, accuracy: 1e-6)

        // Yatay 2:1 görüntü: yalnızca girdinin üst yarısı görüntüdür → y ölçeği 2 kat
        let wide = DetectionDecoder.decode(boxes: [0.5, 0.25, 0.2, 0.1], scores: [0.9], imageWidth: 1280, imageHeight: 640)
        assertRect(wide.first?.rect, CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))

        // Dikey 1:2 görüntü: yalnızca sol yarı görüntüdür → x ölçeği 2 kat
        let tall = DetectionDecoder.decode(boxes: [0.25, 0.5, 0.1, 0.2], scores: [0.9], imageWidth: 320, imageHeight: 640)
        assertRect(tall.first?.rect, CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
    }

    func testDecodeThresholdClipsAndDropsInvalid() {
        let boxes: [Float] = [
            0.5, 0.5, 0.2, 0.2,   // eşik altı
            0.05, 0.5, 0.2, 0.2,  // sol kenardan taşar → kırpılır
            0.5, 0.5, 0, 0.2,     // genişlik 0
            .nan, 0.5, 0.2, 0.2,  // geçersiz
        ]
        let out = DetectionDecoder.decode(boxes: boxes, scores: [0.1, 0.8, 0.9, 0.9], imageWidth: 640, imageHeight: 640)
        XCTAssertEqual(out.count, 1)
        assertRect(out.first?.rect, CGRect(x: 0, y: 0.4, width: 0.15, height: 0.2))
        // Eksik/uyumsuz dizi çökmeye yol açmaz
        XCTAssertTrue(DetectionDecoder.decode(boxes: [0.5, 0.5], scores: [0.9], imageWidth: 10, imageHeight: 10).isEmpty)
        XCTAssertTrue(DetectionDecoder.decode(boxes: [], scores: [], imageWidth: 0, imageHeight: 0).isEmpty)
    }

    func testSuppressionKeepsBestOfOverlappingAndLimitsCount() {
        let boxes: [Float] = [
            0.30, 0.30, 0.2, 0.2,  // A
            0.31, 0.30, 0.2, 0.2,  // A ile neredeyse aynı, puanı daha yüksek
            0.70, 0.70, 0.1, 0.1,  // B
            0.10, 0.90, 0.1, 0.1,  // C
            0.90, 0.10, 0.1, 0.1,  // D (sınır: en çok 3)
        ]
        let out = DetectionDecoder.decode(boxes: boxes, scores: [0.6, 0.8, 0.7, 0.5, 0.4], imageWidth: 640, imageHeight: 640)
        XCTAssertEqual(out.map(\.score).map { ($0 * 10).rounded() / 10 }, [0.8, 0.7, 0.5])
        XCTAssertEqual(out.first?.rect.midX ?? 0, 0.31, accuracy: 1e-6)
        XCTAssertEqual(DetectionDecoder.decode(boxes: boxes, scores: [0.6, 0.8, 0.7, 0.5, 0.4], imageWidth: 640, imageHeight: 640,
                                               limit: 10).count, 4)
    }

    func testIoU() {
        let a = CGRect(x: 0, y: 0, width: 2, height: 2)
        XCTAssertEqual(DetectionDecoder.iou(a, a), 1, accuracy: 1e-9)
        XCTAssertEqual(DetectionDecoder.iou(a, CGRect(x: 1, y: 0, width: 2, height: 2)), 2.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(DetectionDecoder.iou(a, CGRect(x: 5, y: 5, width: 1, height: 1)), 0)
    }

    func testCropRectIsSquareInPixelsPaddedAndInside() throws {
        // 1000×500 görüntü, ortada 100×50 px kuş → 130×130 px kare (her yana %15)
        let box = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        let r = try XCTUnwrap(DetectionDecoder.cropRect(for: box, imageWidth: 1000, imageHeight: 500))
        XCTAssertEqual(r.width * 1000, 130, accuracy: 1e-6)
        XCTAssertEqual(r.height * 500, 130, accuracy: 1e-6)
        XCTAssertEqual(r.midX, 0.5, accuracy: 1e-6)
        XCTAssertEqual(r.midY, 0.5, accuracy: 1e-6)

        // Köşedeki kuş: kare korunur, görüntünün içine kaydırılır
        let corner = try XCTUnwrap(DetectionDecoder.cropRect(for: CGRect(x: 0, y: 0, width: 0.1, height: 0.2),
                                                              imageWidth: 1000, imageHeight: 500))
        XCTAssertEqual(corner.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(corner.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(corner.width * 1000, corner.height * 500, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(corner.maxX, 0.1)
        XCTAssertGreaterThanOrEqual(corner.maxY, 0.2)

        // Uzun kuş: kare görüntü yüksekliğini aşamaz
        let long = try XCTUnwrap(DetectionDecoder.cropRect(for: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5),
                                                            imageWidth: 1000, imageHeight: 500))
        XCTAssertEqual(long.height, 1, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(long.maxX, 1)

        // Kuş kadrajın çoğunu kaplıyorsa kırpma yok
        XCTAssertNil(DetectionDecoder.cropRect(for: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), imageWidth: 800, imageHeight: 600))
    }

    private func bird(_ label: String, _ p: Double, score: Double) -> DetectedBird {
        DetectedBird(box: BirdBox(rect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), score: score),
                     predictions: [BirdPrediction(label: label, scientificName: nil, commonName: label,
                                                  probability: p, source: .speciesModel)])
    }

    func testPrimaryBirdIsMostConfidentSpecies() {
        XCTAssertNil(DetectedBird.primaryIndex([]))
        XCTAssertEqual(DetectedBird.primaryIndex([bird("a", 0.4, score: 0.9), bird("b", 0.8, score: 0.5)]), 1)
        // Eşit tür olasılığında bulucu puanı yüksek olan
        XCTAssertEqual(DetectedBird.primaryIndex([bird("a", 0.5, score: 0.4), bird("b", 0.5, score: 0.7)]), 1)
    }

    func testBirdListShownOnlyForDifferentSpecies() {
        func result(_ birds: [DetectedBird]) -> BirdIdentificationResult {
            BirdIdentificationResult(predictions: birds.first?.predictions ?? [], focusRect: nil, birdPresence: 1,
                                     usedFallback: false, birds: birds)
        }
        XCTAssertFalse(result([bird("a", 0.9, score: 0.9)]).showsBirdList)
        XCTAssertFalse(result([bird("a", 0.9, score: 0.9), bird("a", 0.6, score: 0.5)]).showsBirdList, "Aynı tür: liste gerekmez")
        XCTAssertTrue(result([bird("a", 0.9, score: 0.9), bird("b", 0.6, score: 0.5)]).showsBirdList)
        XCTAssertFalse(BirdIdentificationResult(predictions: [], focusRect: nil, birdPresence: nil, usedFallback: true).showsBirdList)
    }
}
