import LocalAuthentication
import SwiftUI

/// 비밀 앨범을 열어 둔 상태. 앨범마다 Face ID(안 되면 기기 암호)로 열고, 앱이 백그라운드로 가면 모두 다시 잠근다.
///
/// - 잠그기는 Pro에서만 할 수 있다. Pro가 사라져도 이미 잠근 앨범은 잠긴 채로 두고, 열거나 풀 수는 있다.
/// - 기기 암호를 지워 확인할 방법이 없으면 앨범에 갇히지 않도록 그냥 연다. 암호 없는 기기는 어차피 누구나 연다.
@MainActor
final class SecretLock: ObservableObject {
    static let shared = SecretLock()

    enum Failure: Error, Equatable {
        case cancelled, failed
    }

    /// 본인 확인 결과. `unavailable`은 기기에 암호가 없어 확인할 수 없다는 뜻.
    enum Check: Equatable {
        case passed, unavailable, failed(Failure)
    }

    /// 이번에 열어 둔 잠긴 앨범.
    @Published private(set) var opened: Set<UUID> = []
    private let check: (String) async -> Check

    init(check: @escaping (String) async -> Check = SecretLock.deviceOwner) {
        self.check = check
    }

    func isOpen(_ album: Album) -> Bool {
        !album.isLocked || opened.contains(album.id)
    }

    /// 본인을 확인하고 앨범을 연다. 이미 열려 있으면 묻지 않는다.
    @discardableResult
    func open(_ album: Album) async -> Result<Void, Failure> {
        if isOpen(album) { return .success(()) }
        switch await check("‘\(album.title)’ 앨범을 엽니다") {
        case .passed, .unavailable:
            opened.insert(album.id)
            return .success(())
        case .failed(let failure):
            return .failure(failure)
        }
    }

    /// 보고 있던 앨범을 잠글 때. 잠그자마자 눈앞에서 닫히지 않게 열린 채로 둔다.
    func keepOpen(_ album: Album) {
        opened.insert(album.id)
    }

    func lockAll() {
        opened.removeAll()
    }

    /// 기기에 암호가 있어 잠글 수 있는지.
    static var canLock: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "secretAutoUnlock") { return true }
        #endif
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// 버튼에 쓸 확인 방법 이름. "Face ID", "Touch ID", 그 밖에는 "암호".
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "암호"
        }
    }

    nonisolated static func deviceOwner(_ reason: String) async -> Check {
        #if DEBUG
        // 시뮬레이터 캡처와 UI 테스트용(`-secretAutoUnlock YES`).
        if UserDefaults.standard.bool(forKey: "secretAutoUnlock") { return .passed }
        #endif
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return .unavailable }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .passed : .failed(.failed)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return .failed(.cancelled)
        } catch {
            return .failed(.failed)
        }
    }
}

/// 잠긴 앨범을 아직 열지 않았을 때 앨범 화면 자리에 놓는다. 나타나면 바로 본인 확인을 묻는다.
struct SecretGate: View {
    let album: Album
    @ObservedObject private var lock = SecretLock.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var failed = false

    var body: some View {
        ContentUnavailableView {
            Label("잠긴 앨범", systemImage: "lock.fill")
        } description: {
            Text(failed ? "확인하지 못했어요. 다시 시도해 주세요." : "\(SecretLock.methodName)로 확인하면 사진을 볼 수 있어요.")
        } actions: {
            Button("\(SecretLock.methodName)로 열기") { Task { await open() } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("secret-open")
        }
        .navigationTitle(album.title)
        // 앱이 앞에 있을 때만 묻는다. 백그라운드에서 돌아오면 다시 묻는다.
        .task(id: scenePhase) {
            if scenePhase == .active { await open() }
        }
    }

    private func open() async {
        if case .failure(let failure) = await lock.open(album) {
            failed = failure == .failed
        }
    }
}

/// 잠긴 앨범을 보는 동안 앱 전환기 화면에 사진이 찍히지 않게 가린다.
struct SecretShield: ViewModifier {
    let album: Album
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            if album.isLocked, scenePhase != .active {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
                    .overlay { Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }
    }
}

extension View {
    func secretShield(_ album: Album) -> some View { modifier(SecretShield(album: album)) }
}

/// 앨범 메뉴의 "앨범 잠그기" / "잠금 해제". 보관함 카드와 앨범 화면이 같이 쓴다.
struct SecretLockButton: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var pro = ProStore.shared
    let album: Album
    /// 앨범 안에서 잠글 때는 보던 화면을 그대로 둔다.
    var keepsOpen = false
    let needPro: () -> Void
    let notice: (String) -> Void

    var body: some View {
        if album.isLocked {
            Button("잠금 해제", systemImage: "lock.open") {
                Task {
                    guard case .success = await SecretLock.shared.open(album) else { return }
                    AlbumStore(context: context).setLocked(album, false)
                }
            }
        } else {
            Button("앨범 잠그기", systemImage: "lock") {
                guard pro.isPro else { return needPro() }
                guard SecretLock.canLock else {
                    return notice("앨범을 잠그려면 먼저 설정에서 기기 암호를 켜 주세요.")
                }
                if keepsOpen { SecretLock.shared.keepOpen(album) }
                AlbumStore(context: context).setLocked(album, true)
            }
        }
    }
}
