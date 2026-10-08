import PDFKit
import UIKit
import Vision

/// İzin belgesinin metnini çıkarır: PDF'te doğrudan metin, görüntüde (ekran görüntüsü, fotoğraf)
/// Apple Vision ile cihazda OCR. Belge hiçbir sunucuya gönderilmez.
enum PermitImport {
    struct Extracted {
        let text: String
        let qrPayload: String?
        /// OCR'da her metin parçası ve kutusu (0-1, sol-alt orijin). PDF metninde boş.
        var items: [PermitParser.TextItem] = []
    }

    static func extract(image: UIImage) async throws -> Extracted {
        guard let cg = image.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        return try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: cg, orientation: .init(image.imageOrientation))
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false   // özel adlar ve sayılar düzeltilmesin
            let supported = (try? text.supportedRecognitionLanguages()) ?? []
            text.recognitionLanguages = ["tr-TR", "en-US"].filter { supported.contains($0) }
            let qr = VNDetectBarcodesRequest()
            qr.symbologies = [.qr]
            try handler.perform([text, qr])

            // Satırları yukarıdan aşağıya, soldan sağa diz (tablo hücreleri aynı satıra düşsün)
            let obs = (text.results ?? []).compactMap { o -> (CGRect, String)? in
                o.topCandidates(1).first.map { (o.boundingBox, $0.string) }
            }
            let lines = Self.group(obs)
            let qrResults = qr.results ?? []
            let payload = qrResults.compactMap(\.payloadStringValue).first
            // Karekodun üstüne düşen OCR "gürültüsünü" at
            let qrBoxes = qrResults.map(\.boundingBox)
            let items = obs.filter { o in !qrBoxes.contains { $0.insetBy(dx: -0.01, dy: -0.01).intersects(o.0) } }
                .map { PermitParser.TextItem(text: $0.1, box: $0.0) }
            return Extracted(text: lines.joined(separator: "\n"), qrPayload: payload, items: items)
        }.value
    }

    static func extract(pdf url: URL) async throws -> Extracted {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
        let text = doc.string ?? ""
        // Metni olmayan (taranmış / yazdırılmış görüntü) PDF: ilk sayfayı görüntüye çevirip OCR
        if text.count < 40, let page = doc.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: CGSize(width: box.width * 3, height: box.height * 3), for: .mediaBox)
            return try await extract(image: image)
        }
        return Extracted(text: text, qrPayload: nil)
    }

    static func extract(file url: URL) async throws -> Extracted {
        if url.pathExtension.lowercased() == "pdf" { return try await extract(pdf: url) }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let image = UIImage(contentsOfFile: url.path) else { throw CocoaError(.fileReadCorruptFile) }
        return try await extract(image: image)
    }

    /// Vision kutularını (sol-alt köşe orijinli, 0-1) metin satırlarına grupla.
    private static func group(_ obs: [(CGRect, String)]) -> [String] {
        let sorted = obs.sorted { $0.0.midY > $1.0.midY }
        var lines: [[(CGRect, String)]] = []
        for o in sorted {
            if let last = lines.last?.first, abs(last.0.midY - o.0.midY) < max(last.0.height, o.0.height) * 0.5 {
                lines[lines.count - 1].append(o)
            } else {
                lines.append([o])
            }
        }
        return lines.map { $0.sorted { $0.0.minX < $1.0.minX }.map(\.1).joined(separator: "  ") }
    }
}

private extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
