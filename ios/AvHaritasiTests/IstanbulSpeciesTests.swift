import CoreML
import XCTest
@testable import AvHaritasi

/// Fotoğraf modeli ve çevrimiçi tanıma etiketlerinin MAK adına ve Türkçe ada çevrilmesi.
final class IstanbulSpeciesTests: XCTestCase {
    func testMAKAliasIsUsedForLegalLookup() {
        // BirdNET listesinde "Streptopelia senegalensis", MAK'ta "Spilopelia senegalensis"
        XCTAssertEqual(IstanbulSpecies.lawName("Streptopelia senegalensis"), "Spilopelia senegalensis")
        XCTAssertEqual(IstanbulSpecies.lawName("Pica pica"), "Pica pica")
        XCTAssertEqual(IstanbulSpecies.lawName("Bilinmeyen tur"), "Bilinmeyen tur")
    }

    func testTurkishNameForNonGameSpecies() {
        XCTAssertEqual(IstanbulSpecies.turkishName("Erithacus rubecula"), "Kızılgerdan")
        XCTAssertNil(IstanbulSpecies.turkishName("Bilinmeyen tur"))
    }

    func testBundledSpeciesModelLabelsMatchSpeciesList() throws {
        // Tür modeli pakette olmalı ve her etiketi İstanbul listesinde bulunmalı
        let url = try XCTUnwrap(Bundle.main.url(forResource: CoreMLBirdClassifier.modelName, withExtension: "mlmodelc"))
        let model = try MLModel(contentsOf: url)
        let labels = try XCTUnwrap(model.modelDescription.classLabels as? [String])
        XCTAssertEqual(labels.count, 331)
        for label in labels {
            let sci = try XCTUnwrap(BirdLabel.parse(label).scientific, label)
            XCTAssertNotNil(IstanbulSpecies.turkishName(sci), label)
        }
    }
}
