import StoreKit
import StoreKitTest
import XCTest
@testable import PhotoAlbum

/// 실제 App Store 대신 `Folio.storekit`로 구매·환불·무료 한도를 확인한다.
@MainActor
final class ProStoreTests: XCTestCase {
    private var session: SKTestSession!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        let configuration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Folio.storekit")
        session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defaults = UserDefaults(suiteName: "ProStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
    }

    func testProductLoadsWithLocalPrice() async {
        let store = ProStore(defaults: defaults)
        await store.loadProduct()
        XCTAssertEqual(store.productState, .loaded)
        XCTAssertEqual(store.product?.id, ProStore.productID)
        XCTAssertEqual(store.product?.type, .nonConsumable)
        XCTAssertEqual(store.product?.displayName, "Folio Pro")
    }

    func testPurchaseUnlocksProAndIsRememberedForNextLaunch() async {
        let store = ProStore(defaults: defaults)
        await store.refresh()
        XCTAssertFalse(store.isPro)

        await store.loadProduct()
        let outcome = await store.purchase()
        XCTAssertEqual(outcome, .purchased)
        XCTAssertTrue(store.isPro)

        // 다시 켠 앱: 확인 전에도 기억해 둔 값으로 시작하고, 확인한 뒤에도 Pro다.
        let relaunched = ProStore(defaults: defaults)
        XCTAssertTrue(relaunched.isPro)
        // 막 산 구매는 StoreKit 목록에 늦게 오를 수 있다. 그 사이에 확인해도 Pro를 거두지 않아야 한다.
        await relaunched.refresh()
        XCTAssertTrue(relaunched.isPro)
    }

    func testAccountWithoutPurchaseIsNotPro() async {
        // 예전에 이 기기에서 Pro였다고 기억하지만, 지금 계정에는 구매가 없다(계정을 바꾼 경우).
        defaults.set(true, forKey: "pro.unlocked")
        let store = ProStore(defaults: defaults)
        XCTAssertTrue(store.isPro)
        await store.refresh()
        XCTAssertFalse(store.isPro)
    }

    func testRefundTakesProAway() async throws {
        // 앱처럼 거래 소식을 듣는 상태에서 산다.
        let store = ProStore(defaults: defaults)
        store.start()
        await store.loadProduct()
        _ = await store.purchase()
        XCTAssertTrue(store.isPro)

        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == ProStore.productID })
        try session.refundTransaction(identifier: UInt(transaction.identifier))
        // 환불은 `Transaction.updates`로 들어와 바로 Pro를 거둔다(막 산 직후의 유예와 상관없이).
        let revoked = await eventually { !store.isPro }
        XCTAssertTrue(revoked, "환불 소식이 오면 Pro가 꺼져야 한다")

        // 다시 켠 앱이 확인해도 꺼진 채다.
        let relaunched = ProStore(defaults: defaults)
        XCTAssertFalse(relaunched.isPro)
        await relaunched.refresh()
        XCTAssertFalse(relaunched.isPro)
    }

    /// 조건이 3초 안에 참이 되는지 본다. StoreKit 소식은 조금 늦게 도착한다.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<30 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    func testRestoreFindsEarlierPurchase() async throws {
        // 다른 기기나 예전에 산 것처럼, 앱 밖에서 구매를 만든다.
        try await session.buyProduct(identifier: ProStore.productID)
        let store = ProStore(defaults: defaults)
        XCTAssertFalse(store.isPro)
        let restored = await store.restore()
        XCTAssertTrue(restored)
        XCTAssertTrue(store.isPro)
    }

    func testFreeTierAllowsFiveAlbums() {
        let store = ProStore(defaults: defaults)
        XCTAssertTrue(store.canCreateAlbum(currentCount: 0))
        XCTAssertTrue(store.canCreateAlbum(currentCount: ProStore.freeAlbumLimit - 1))
        XCTAssertFalse(store.canCreateAlbum(currentCount: ProStore.freeAlbumLimit))
        XCTAssertFalse(store.canCreateAlbum(currentCount: 12))
    }
}
