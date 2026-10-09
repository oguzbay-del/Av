import LocalAuthentication
import SwiftUI
import UIKit

/// Uygulama kilidi (Face ID / Touch ID / Optic ID, yoksa cihaz parolası). Varsayılan kapalı.
///
/// GÜVENLİK: Kilit YALNIZCA bir arayüz örtüsüdür. Kilitliyken hiçbir şey durmaz ya da duraklamaz:
/// konum güncellemeleri, değerlendirme (Assessment), uyarılar ve bildirimler, güvenli daire (bölge
/// izleme), Live Activity ve Apple Watch eşitlemesi aynen çalışmaya devam eder. Bu sınıf AppModel'e,
/// LocationManager'a ya da herhangi bir arka plan işine dokunmaz; yalnızca ön plandaki pencerelerin
/// üstüne ayrı bir UIWindow (kilit ekranı) koyar. Ayrı pencere kullanılır çünkü SwiftUI `.overlay`
/// açık sayfaların (sheet / fullScreenCover) altında kalırdı. Kilitliyken gelen bir bildirime
/// dokunulursa içerik (ör. haritada odak) arka planda hazırlanır; önce kilit ekranı görünür, kilit
/// açılınca içerik görünür.
///
/// Uygulama değiştirici görüntüsü: kilit açıkken sahne `.inactive` / `.background` olduğu anda
/// (ve kilit kapalıyken hiçbir zaman) haritayı ve konumu gizleyen bir örtü gösterilir.
@Observable @MainActor
final class AppLock {
    static let shared = AppLock()

    static let enabledKey = "appLockEnabled"
    static let delayKey = "appLockDelay"

    /// Arka plana geçtikten sonra ne kadar süre geçince kilitlensin.
    enum Delay: Int, CaseIterable, Identifiable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .immediately: L("Hemen")
            case .oneMinute: L("1 dk sonra")
            case .fiveMinutes: L("5 dk sonra")
            case .fifteenMinutes: L("15 dk sonra")
            }
        }
    }

    /// Kimlik doğrulama yöntemi (etiketler ve kullanılabilirlik için).
    enum Method: Equatable {
        case faceID, touchID, opticID, passcode
        /// Ne biyometri ne de cihaz parolası ayarlı.
        case unavailable
    }

    enum AuthResult: Sendable, Equatable {
        case success
        /// Kullanıcı ya da sistem vazgeçti: sessizce kilitli kal.
        case cancelled
        /// Bu cihazda biyometri ve parola yok (ör. parola kaldırıldı).
        case unavailable
        case failed(String)
    }

    /// Kilit açık mı (Ayarlar › Gizlilik). Değiştirmek için `setEnabled(_:)` kimlik doğrulaması ister.
    private(set) var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { isLocked = false }
            updateWindows()
        }
    }

    var delay: Delay {
        didSet { UserDefaults.standard.set(delay.rawValue, forKey: Self.delayKey) }
    }

    /// Kilit ekranı görünüyor (kimlik doğrulanana kadar).
    private(set) var isLocked: Bool {
        didSet {
            if isLocked, !oldValue { autoPrompted = false }
            updateWindows()
        }
    }

    /// Sistem kimlik doğrulama penceresi açık (bu sırada sahne `.inactive` olur; örtü gösterilmez).
    private(set) var isAuthenticating = false {
        didSet { updateWindows() }
    }

    /// Kilit ekranındaki son hata (ör. "Doğrulanamadı").
    private(set) var errorMessage: String?

    /// Kullanıcıya bir kez gösterilecek not (ör. kilit kullanılamadığı için kapatıldı).
    var notice: String?

    private(set) var phase: ScenePhase = .active {
        didSet { updateWindows() }
    }

    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    @ObservationIgnored private var autoPrompted = false
    @ObservationIgnored private var windows: [ObjectIdentifier: UIWindow] = [:]

    private init() {
        let d = UserDefaults.standard
        let enabled = d.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        delay = Delay(rawValue: d.integer(forKey: Self.delayKey)) ?? .immediately
        // Soğuk açılışta (arka planda bölge izlemesiyle başlatılsa bile) kilitli başla
        isLocked = enabled
    }

    /// Kilit ekranı ya da gizlilik örtüsü görünmeli mi.
    var showsCover: Bool {
        isLocked || (isEnabled && phase != .active && !isAuthenticating)
    }

    // MARK: Sahne

    /// `scenePhase` değişiminde (AvHaritasiApp). Yalnızca arayüzü etkiler.
    func scenePhaseChanged(_ new: ScenePhase) {
        phase = new
        guard isEnabled else { return }
        switch new {
        case .background:
            guard !isLocked else { return }
            backgroundedAt = .now
            if delay == .immediately { isLocked = true }
        case .active:
            if let t = backgroundedAt {
                backgroundedAt = nil
                if ContinuousClock.now - t >= .seconds(delay.rawValue) { isLocked = true }
            }
            autoPromptIfNeeded()
        default:
            break
        }
    }

    /// Kilit ekranı görünür ve uygulama ön plandayken bir kez otomatik Face ID iste.
    func autoPromptIfNeeded() {
        guard isLocked, phase == .active, !autoPrompted, !isAuthenticating else { return }
        autoPrompted = true
        Task { await unlock() }
    }

    // MARK: Kimlik doğrulama

    /// Kilit ekranındaki "Kilidi aç".
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        errorMessage = nil
        switch await authenticate(reason: L("Av Haritası'nın kilidini açın")) {
        case .success:
            isLocked = false
        case .cancelled:
            break
        case .unavailable:
            // Kullanıcı dışarıda kalmasın: kilidi aç ve kapat
            isEnabled = false
            notice = L("Bu cihazda Face ID, Touch ID ya da cihaz parolası ayarlı olmadığı için uygulama kilidi kapatıldı.")
        case .failed(let message):
            errorMessage = message
        }
    }

    /// Kilidi açmak ya da kapatmak (her iki yönde de kimlik doğrulaması gerekir).
    func setEnabled(_ on: Bool) async {
        guard on != isEnabled else { return }
        let reason = on ? L("Uygulama kilidini açmak için kimliğinizi doğrulayın")
                        : L("Uygulama kilidini kapatmak için kimliğinizi doğrulayın")
        switch await authenticate(reason: reason) {
        case .success:
            isEnabled = on
            notice = nil
        case .unavailable:
            if !on { isEnabled = false }
            notice = L("Bu cihazda Face ID, Touch ID ya da cihaz parolası ayarlı değil.")
        case .cancelled, .failed:
            break
        }
    }

    /// Korunan işlemler (saha kaydını açma/kapatma, paylaşma, silme): kilit kapalıysa doğrudan izin verir.
    func authorize(_ reason: String) async -> Bool {
        guard isEnabled else { return true }
        return await authenticate(reason: reason) == .success
    }

    private func authenticate(reason: String) async -> AuthResult {
        guard !isAuthenticating else { return .cancelled }
        isAuthenticating = true
        defer { isAuthenticating = false }
        var result = await Self.evaluate(reason: reason)
        if result == .failed(Self.lockoutMarker) {
            // Biyometri kilitlendi (çok sayıda hatalı deneme): cihaz parolasıyla bir kez daha
            result = await Self.evaluate(reason: reason)
            if result == .failed(Self.lockoutMarker) {
                result = .failed(L("Face ID geçici olarak kilitlendi. Cihaz parolanızla tekrar deneyin."))
            }
        }
        return result
    }

    nonisolated private static let lockoutMarker = "biometryLockout"

    /// `.deviceOwnerAuthentication`: biyometri, olmazsa cihaz parolası. LAContext bu fonksiyonda
    /// oluşturulur ve dışarı çıkmaz (Sendable olmayan değer aktör sınırını geçmez).
    nonisolated private static func evaluate(reason: String) async -> AuthResult {
        let context = LAContext()
        context.localizedCancelTitle = L("Vazgeç")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                ? .success : .failed(L("Doğrulanamadı. Tekrar deneyin."))
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .systemCancel, .appCancel, .userFallback, .notInteractive:
                return .cancelled
            case .biometryLockout:
                return .failed(lockoutMarker)
            case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled:
                return .unavailable
            case .authenticationFailed:
                return .failed(L("Doğrulanamadı. Tekrar deneyin."))
            default:
                return .failed(e.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Cihazda kullanılabilen yöntem (Ayarlar'daki etiket ve kullanılabilirlik).
    static func availableMethod() -> Method {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            switch context.biometryType {
            case .faceID: return .faceID
            case .touchID: return .touchID
            case .opticID: return .opticID
            default: break
            }
        }
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) ? .passcode : .unavailable
    }

    // MARK: Kilit penceresi

    /// Kilit ekranı / örtü her sahnede, uygulamanın tüm pencere ve sayfalarının üstünde ayrı bir pencere.
    private func updateWindows() {
        let visible = showsCover
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            let id = ObjectIdentifier(scene)
            if visible {
                let window = windows[id] ?? makeWindow(scene)
                windows[id] = window
                window.isHidden = false
            } else {
                windows[id]?.isHidden = true
            }
        }
        if !visible { windows = [:] }
    }

    private func makeWindow(_ scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: LockScreenView(lock: self))
        host.view.backgroundColor = .systemBackground
        host.view.accessibilityViewIsModal = true
        window.rootViewController = host
        window.backgroundColor = .systemBackground
        return window
    }
}

/// Kilit ekranı (ve uygulama değiştirici örtüsü). Konum, harita ya da kişisel veri göstermez.
struct LockScreenView: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("LockIcon")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            Text("Av Haritası").font(.title2.bold())
            if lock.isLocked {
                Label("Av Haritası kilitli", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let message = lock.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Kilidi aç", systemImage: buttonImage)
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(lock.isAuthenticating)
                Text("Kilitliyken de konum takibi ve yasak alan uyarıları çalışmaya devam eder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear { lock.autoPromptIfNeeded() }
    }

    private var buttonImage: String {
        switch AppLock.availableMethod() {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcode, .unavailable: "lock.open"
        }
    }
}
