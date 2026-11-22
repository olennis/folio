import StoreKit
import SwiftUI

/// Folio Pro 구매 상태. 한 번 결제하는 비소모성 상품 하나만 다룬다.
///
/// - 구매 여부의 근거는 StoreKit의 `Transaction.currentEntitlements`다. 마지막으로 확인한 값은
///   앱을 켤 때 잠깐 잠금 화면이 번쩍이지 않도록 기기에 기억해 두고, 실행할 때마다 다시 확인한다.
/// - 다른 기기에서 산 것, 환불, 가족 공유는 `Transaction.updates`로 들어온다.
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()

    /// App Store Connect의 상품 ID와 같아야 한다.
    nonisolated static let productID = "folio.pro"
    /// 무료로 만들 수 있는 앨범 수. 이미 더 많이 가진 앨범은 그대로 쓸 수 있다.
    nonisolated static let freeAlbumLimit = 5

    enum ProductState: Equatable {
        case loading, loaded, unavailable
    }

    enum PurchaseOutcome: Equatable {
        case purchased, cancelled, pending, failed(String)
    }

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var productState = ProductState.loading
    /// 구매나 복원이 진행 중인지. 버튼을 두 번 누르지 못하게 한다.
    @Published private(set) var isWorking = false

    private let defaults: UserDefaults
    private let productID: String
    /// 캡처와 UI 테스트용 강제 값(DEBUG의 `-forcePro YES|NO`). 있으면 StoreKit 결과로 바꾸지 않는다.
    private let forced: Bool?
    private var updates: Task<Void, Never>?
    private static let cacheKey = "pro.unlocked"
    private static let verifiedAtKey = "pro.verifiedAt"
    /// 막 산 직후에는 StoreKit의 권리 목록에 구매가 늦게 나타날 수 있다(테스트 환경에서 약 0.6초).
    /// 이 시간 안에는 목록에 없다는 이유만으로 Pro를 거두지 않는다. 환불은 이 시간과 상관없이 바로 반영한다.
    static let purchaseGrace: TimeInterval = 5 * 60

    init(defaults: UserDefaults = .standard, productID: String = ProStore.productID) {
        self.defaults = defaults
        self.productID = productID
        #if DEBUG
        // 실행 인자 `-forcePro YES`는 문자열로 들어오므로 bool(forKey:)로 읽는다.
        // 실기기에서 한 번 이 인자로 켜면 기억해 두어, 홈 화면에서 다시 열어도 유지한다(`-forcePro CLEAR`로 지움).
        let savedKey = "debug.forcePro"
        if let argument = defaults.string(forKey: "forcePro") {
            if argument == "CLEAR" {
                defaults.removeObject(forKey: savedKey)
                forced = nil
            } else {
                forced = defaults.bool(forKey: "forcePro")
                defaults.set(forced, forKey: savedKey)
            }
        } else {
            forced = defaults.object(forKey: savedKey) as? Bool
        }
        #else
        forced = nil
        #endif
        isPro = forced ?? defaults.bool(forKey: Self.cacheKey)
    }

    deinit { updates?.cancel() }

    /// 앱을 켤 때 한 번 부른다. 거래 소식을 듣기 시작하고, 구매 여부와 가격을 불러온다.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.apply(result)
            }
        }
        Task {
            await refresh()
            await loadProduct()
        }
    }

    func canCreateAlbum(currentCount: Int) -> Bool {
        isPro || currentCount < Self.freeAlbumLimit
    }

    /// 지금 가진 권리를 StoreKit에 다시 묻는다.
    func refresh() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == productID,
               transaction.revocationDate == nil {
                setPro(true)
                return
            }
        }
        // 목록에 없다. 환불된 기록이 있으면 바로 거둔다.
        if case .verified(let latest)? = await Transaction.latest(for: productID), latest.revocationDate != nil {
            setPro(false)
            return
        }
        // 방금 산 구매가 아직 목록에 안 올라왔을 수 있다. 그동안은 그대로 둔다.
        if let verifiedAt = defaults.object(forKey: Self.verifiedAtKey) as? Date,
           Date.now.timeIntervalSince(verifiedAt) < Self.purchaseGrace {
            return
        }
        setPro(false)
    }

    func loadProduct() async {
        productState = .loading
        do {
            product = try await Product.products(for: [productID]).first
            productState = product == nil ? .unavailable : .loaded
        } catch {
            product = nil
            productState = .unavailable
        }
    }

    func purchase() async -> PurchaseOutcome {
        guard let product else { return .failed("상품 정보를 불러오지 못했습니다. 잠시 뒤 다시 시도해 주세요.") }
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                defaults.set(Date.now, forKey: Self.verifiedAtKey)
                setPro(transaction.revocationDate == nil)
                return .purchased
            case .success(.unverified):
                return .failed("구매를 확인하지 못했습니다. 구매 복원을 눌러 다시 확인해 주세요.")
            case .userCancelled:
                return .cancelled
            case .pending:
                // 보호자 승인(구매 요청) 같은 경우. 승인되면 `Transaction.updates`로 들어온다.
                return .pending
            @unknown default:
                return .failed("구매를 마치지 못했습니다.")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 구매 복원. App Store와 거래 기록을 맞춘 뒤 권리를 다시 확인한다.
    @discardableResult
    func restore() async -> Bool {
        isWorking = true
        defer { isWorking = false }
        try? await AppStore.sync()
        await refresh()
        return isPro
    }

    private func apply(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if transaction.productID == productID {
            setPro(transaction.revocationDate == nil)
        }
        await transaction.finish()
    }

    private func setPro(_ value: Bool) {
        guard forced == nil else { return }
        isPro = value
        defaults.set(value, forKey: Self.cacheKey)
    }
}
