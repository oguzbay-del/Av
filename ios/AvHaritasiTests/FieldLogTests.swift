import LocalAuthentication
import XCTest
import UserNotifications
@testable import AvHaritasi

final class FieldLogTests: XCTestCase {
    private var root: URL!
    private var wasEnabled = false

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FieldLogTests-\(UUID().uuidString)", isDirectory: true)
        wasEnabled = UserDefaults.standard.bool(forKey: FieldLog.enabledKey)
        UserDefaults.standard.set(true, forKey: FieldLog.enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(wasEnabled, forKey: FieldLog.enabledKey)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeLog() -> FieldLog {
        FieldLog(directory: root.appendingPathComponent("tani", isDirectory: true),
                 exportDirectory: root.appendingPathComponent("paylasim", isDirectory: true),
                 observeNetwork: false)
    }

    func testExportKeepsSiblingFormat() async throws {
        let log = makeLog()
        log.log(.weatherOK)
        let txt = try await log.export(.text)
        let jsonl = try await log.export(.jsonl)
        XCTAssertNotEqual(txt, jsonl)
        XCTAssertTrue(FileManager.default.fileExists(atPath: txt.path), "jsonl dışa aktarımı .txt dosyasını silmemeli")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonl.path))
        // Aynı biçimin yeniden üretilmesi diğerini silmez
        _ = try await log.export(.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonl.path))
    }

    func testClearLeavesRingEmpty() async throws {
        let log = makeLog()
        log.log(.weatherOK)
        log.log(.staleEnd)
        XCTAssertFalse(log.recentEntries.isEmpty)
        log.clear()
        // Seri kuyruk: dışa aktarma, clear()'ın disk işinden sonra çalışır
        let url = try await log.export(.jsonl)
        XCTAssertTrue(log.recentEntries.isEmpty)
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.isEmpty, "silinen olaylar dışa aktarımda görünmemeli")
    }

    func testAlertPostsWhenBackgroundOrLocked() {
        XCTAssertTrue(AlertNotifier.shouldPost(appActive: false, locked: false))
        XCTAssertTrue(AlertNotifier.shouldPost(appActive: false, locked: true))
        XCTAssertTrue(AlertNotifier.shouldPost(appActive: true, locked: true), "öndeyken kilitliyse bildirim de gelmeli")
        XCTAssertFalse(AlertNotifier.shouldPost(appActive: true, locked: false))
    }

    func testForegroundPresentationOnlyWhenLocked() {
        XCTAssertEqual(AlertNotifier.foregroundPresentation(locked: true), [.banner, .sound, .list])
        XCTAssertEqual(AlertNotifier.foregroundPresentation(locked: false), [])
    }

    func testOnlyMissingPasscodeDisablesAppLock() {
        XCTAssertEqual(AppLock.canEvaluateFailure(LAError(.passcodeNotSet)), .unavailable)
        for code in [LAError.Code.biometryNotAvailable, .biometryNotEnrolled, .biometryLockout] {
            if case .failed = AppLock.canEvaluateFailure(LAError(code)) { continue }
            XCTFail("\(code.rawValue) kilidi kapatmamalı")
        }
    }
}
