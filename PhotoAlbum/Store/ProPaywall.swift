import StoreKit
import SwiftUI

/// Folio Pro 결제 화면. 어디서 열렸는지에 따라 첫 문장만 바뀐다.
struct ProPaywall: View {
    enum Reason: String, Identifiable {
        case albumLimit, suggestions, memories, autoClassify, upgrade
        var id: String { rawValue }

        var headline: String {
            switch self {
            case .albumLimit:
                "무료로는 앨범을 \(ProStore.freeAlbumLimit)개까지 만들 수 있어요. Pro로 앨범을 제한 없이 만드세요."
            case .suggestions:
                "사진을 넣을 때 날짜와 장소가 맞는 앨범을 골라 드려요."
            case .memories:
                "몇 년 전 오늘 찍은 사진이 든 앨범을 홈에 꺼내 드려요."
            case .autoClassify:
                "사진을 연도·여행·장면별로 알아서 묶어 앨범을 제안해 드려요."
            case .upgrade:
                "앨범을 제한 없이 만들고, 앨범 추천과 지난 오늘을 받아 보세요."
            }
        }
    }

    let reason: Reason
    @ObservedObject private var store = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?
    @State private var unlockedCount = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    features
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) { actions }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", systemImage: "xmark") { dismiss() }
                }
            }
            .alert("Folio Pro", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
        }
        .sensoryFeedback(.success, trigger: unlockedCount)
        .task { if store.product == nil { await store.loadProduct() } }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: store.isPro ? "checkmark.seal.fill" : "rectangle.stack.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
            Text("Folio Pro")
                .font(.largeTitle.bold())
            Text(store.isPro ? "Pro를 쓰고 있어요. 고맙습니다." : reason.headline)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("paywall-headline")
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 18) {
            row("rectangle.stack.badge.plus", "앨범 무제한", "연도, 인물, 여행마다 앨범을 원하는 만큼 만드세요.")
            row("wand.and.stars", "자동 분류", "연도, 여행, 반려동물·음식·바다·산 사진을 알아서 묶어 드려요. 분석은 기기 안에서만 해요.")
            row("sparkles", "앨범 추천", "사진을 넣을 때 날짜와 장소가 맞는 앨범을 먼저 보여 드려요.")
            row("clock.arrow.circlepath", "지난 오늘과 자주 보는 인물", "몇 년 전 오늘의 앨범과 자주 여는 인물 앨범을 홈에 꺼내 드려요.")
            row("checkmark.seal", "한 번 결제", "구독이 아니에요. 가족 공유로 가족과 함께 쓸 수 있어요.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actions: some View {
        // 모든 버튼은 같은 높이의 전체 너비 캡슐이다. 주된 동작만 채운 색, 나머지는 옅은 배경.
        VStack(spacing: 10) {
            if store.isPro {
                Button { dismiss() } label: { ActionLabel("완료") }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            } else {
                if store.productState == .unavailable {
                    Text("가격을 불러오지 못했어요. 인터넷 연결을 확인해 주세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // 살 수 없을 때 죽은 구매 버튼 대신, 주 버튼이 다시 불러온다.
                    Button { Task { await store.loadProduct() } } label: { ActionLabel("다시 불러오기") }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("paywall-reload")
                } else {
                    Button(action: buy) { ActionLabel(purchaseTitle, working: store.isWorking) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(store.product == nil || store.isWorking)
                        .accessibilityIdentifier("paywall-buy")
                }
                Button(action: restore) { ActionLabel("구매 복원") }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(store.isWorking)
                    .accessibilityIdentifier("paywall-restore")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // 회색 막대 위에서는 보조 버튼의 옅은 배경이 묻힌다. 화면 바탕색 위에 둔다.
        .background(Color(.systemBackground))
    }

    private var purchaseTitle: String {
        store.product.map { "\($0.displayPrice)에 Pro 열기" } ?? "가격을 불러오는 중…"
    }

    private func buy() {
        Task {
            switch await store.purchase() {
            case .purchased:
                unlockedCount += 1
            case .cancelled:
                break
            case .pending:
                notice = "구매 승인을 기다리고 있어요. 승인되면 Pro가 자동으로 열립니다."
            case .failed(let message):
                notice = message
            }
        }
    }

    private func restore() {
        Task {
            if await store.restore() {
                unlockedCount += 1
            } else {
                notice = "이 Apple 계정으로 산 Folio Pro를 찾지 못했어요."
            }
        }
    }
}

/// 결제 화면 버튼의 안쪽. 모든 버튼이 같은 높이(50pt)와 전체 너비를 갖게 한다.
private struct ActionLabel: View {
    let title: String
    var working = false

    init(_ title: String, working: Bool = false) {
        self.title = title
        self.working = working
    }

    var body: some View {
        ZStack {
            Text(title).font(.headline).opacity(working ? 0 : 1)
            if working { ProgressView() }
        }
        .frame(maxWidth: .infinity, minHeight: 36)
    }
}
