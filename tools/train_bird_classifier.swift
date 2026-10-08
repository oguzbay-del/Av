// Kuş fotoğrafı tür modeli (BirdClassifier.mlmodel) eğitimi — Create ML, yalnızca macOS 14+.
//
//   swift tools/train_bird_classifier.swift <veri klasörü> <çıktı klasörü>
//
// Veri: tools/fetch_bird_photos.py çıktısı (<Bilimsel ad>_<İngilizce ad>/*.jpg).
// Her türün %15'i test için ayrılır (eğitime hiç girmez); doğruluk ve tür bazında
// karışıklık metrikler.json'a yazılır.
//
// Model: Apple'ın cihazdaki özellik çıkarıcısı (Vision Scene Print) üzerine aktarım öğrenmesi.
// Özellik çıkarıcı iOS'ta zaten bulunduğu için model dosyası küçüktür (~1 MB).
// Çıktı biçimi: girdi "image" (299×299), çıktılar "classLabel" ve "classLabelProbs".
import CreateML
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("kullanım: swift train_bird_classifier.swift <veri> <çıktı>")
    exit(2)
}
let dataDir = URL(fileURLWithPath: args[1], isDirectory: true)
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

// Eğitim/test ayrımı (sabit sıralı, tekrarlanabilir)
let work = fm.temporaryDirectory.appendingPathComponent("kus_egitim_\(ProcessInfo.processInfo.processIdentifier)")
let trainDir = work.appendingPathComponent("egitim"), testDir = work.appendingPathComponent("test")
var classCount = 0
for cls in try fm.contentsOfDirectory(atPath: dataDir.path).sorted() {
    let src = dataDir.appendingPathComponent(cls)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else { continue }
    let images = try fm.contentsOfDirectory(atPath: src.path).filter { $0.lowercased().hasSuffix(".jpg") }.sorted()
    guard images.count >= 10 else { continue }
    classCount += 1
    let step = max(2, images.count / max(2, images.count * 15 / 100)) // her step. fotoğraf test için
    for (i, f) in images.enumerated() {
        let dst = (i % step == 0 ? testDir : trainDir).appendingPathComponent(cls)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        try fm.copyItem(at: src.appendingPathComponent(f), to: dst.appendingPathComponent(f))
    }
}
print("\(classCount) sınıf")

let parameters = MLImageClassifier.ModelParameters(
    validation: .split(strategy: .automatic),
    maxIterations: 100,
    augmentation: [.crop, .flip, .blur, .exposure, .rotation],
    algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2), classifier: .logisticRegressor)
)
let classifier = try MLImageClassifier(trainingData: .labeledDirectories(at: trainDir), parameters: parameters)
let evaluation = classifier.evaluation(on: .labeledDirectories(at: testDir))

let trainAcc = 1 - classifier.trainingMetrics.classificationError
let valAcc = 1 - classifier.validationMetrics.classificationError
let testAcc = 1 - evaluation.classificationError
print(String(format: "doğruluk — eğitim %.1f%%, doğrulama %.1f%%, test %.1f%%", trainAcc * 100, valAcc * 100, testAcc * 100))

// Karışıklık tablosu (koruma altındaki türün av türüyle karışması özellikle önemli)
try evaluation.confusion.writeCSV(to: outDir.appendingPathComponent("karisiklik.csv"))
try evaluation.precisionRecall.writeCSV(to: outDir.appendingPathComponent("tur_basari.csv"))

let metrics: [String: Any] = [
    "classes": classCount,
    "trainAccuracy": trainAcc, "validationAccuracy": valAcc, "testAccuracy": testAcc,
    "date": ISO8601DateFormatter().string(from: Date()),
]
try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("metrikler.json"))

let metadata = MLModelMetadata(
    author: "Av Haritası (eğitim: tools/train_bird_classifier.swift)",
    shortDescription: "Türkiye'deki av ve koruma altındaki kuş türleri — fotoğraftan tür tahmini. Eğitim verisi: iNaturalist (CC0 / CC BY / CC BY-NC; künye: kunye.csv).",
    license: "Ticari olmayan kullanım (CC BY-NC eğitim fotoğrafları içerir)",
    version: ISO8601DateFormatter().string(from: Date())
)
try classifier.write(to: outDir.appendingPathComponent("BirdClassifier.mlmodel"), metadata: metadata)
try? fm.removeItem(at: work)
print("yazıldı:", outDir.appendingPathComponent("BirdClassifier.mlmodel").path)
