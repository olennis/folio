import SwiftData
import SwiftUI

/// 정리 탭 맨 위의 "자동 분류". Pro는 제안 카드, 무료는 제안이 있을 때만 잠긴 줄을 본다.
struct AutoClassifySection: View {
    @ObservedObject private var model = AutoClassifyModel.shared
    @ObservedObject private var pro = ProStore.shared
    @State private var reviewing: AutoSuggestion?
    @State private var paywall: ProPaywall.Reason?

    var body: some View {
        let items = model.suggestions
        Group {
            if !items.isEmpty || (pro.isPro && model.sceneProgress != nil) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("자동 분류")
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if pro.isPro, let progress = model.sceneProgress {
                            Text("사진 살펴보는 중 \(progress.done.formatted())/\(progress.total.formatted())")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 20)

                    if pro.isPro {
                        cards(items)
                    } else {
                        Button { paywall = .autoClassify } label: {
                            LockedRow(
                                title: "자동으로 묶을 앨범 \(items.count)개",
                                detail: "Folio Pro에서 연도·여행·장면별로 묶어 드려요"
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .accessibilityIdentifier("locked-auto")
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .sheet(item: $reviewing) { AutoSuggestionSheet(suggestion: $0) }
        .sheet(item: $paywall) { ProPaywall(reason: $0) }
    }

    private func cards(_ items: [AutoSuggestion]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    Button { reviewing = item } label: { SuggestionCard(suggestion: item) }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("auto-suggestion")
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollIndicators(.hidden)
    }
}

/// 제안 카드 한 장: 대표 사진, 앨범 이름, 설명.
private struct SuggestionCard: View {
    let suggestion: AutoSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumCover(identifier: suggestion.assetIDs.first, pixels: 500)
                .frame(width: 180, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Image(systemName: suggestion.symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .labelGlass(cornerRadius: 14)
                        .environment(\.colorScheme, .dark)
                        .padding(8)
                }
            Text(suggestion.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(suggestion.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 180, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// 제안을 확인하는 화면. 사진을 빼고, 새 앨범이면 이름을 고친 뒤 넣는다.
struct AutoSuggestionSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = AutoClassifyModel.shared
    let suggestion: AutoSuggestion

    @State private var selected: Set<String>
    @State private var title: String
    @State private var applied = 0

    init(suggestion: AutoSuggestion) {
        self.suggestion = suggestion
        _selected = State(initialValue: Set(suggestion.assetIDs))
        _title = State(initialValue: suggestion.title)
    }

    private var isNew: Bool { suggestion.targetAlbumID == nil }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if isNew {
                        TextField("앨범 이름", text: $title)
                            .font(.title2.bold())
                            .submitLabel(.done)
                            .accessibilityIdentifier("auto-title")
                    } else {
                        Text(title).font(.title2.bold())
                    }
                    Text("\(suggestion.reason) · \(suggestion.detail)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("빼고 싶은 사진은 눌러서 선택을 풀어 주세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(suggestion.assetIDs, id: \.self) { id in
                        cell(id, isOn: selected.contains(id))
                    }
                }
            }
            .navigationTitle("자동 분류")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("이 제안 숨기기", systemImage: "eye.slash") {
                            model.dismiss(suggestion)
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("더 보기")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: apply) {
                    Text(actionTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(selected.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
                .accessibilityIdentifier("auto-apply")
            }
        }
        .sensoryFeedback(.success, trigger: applied)
    }

    private var actionTitle: String {
        isNew ? "앨범 만들기 · \(selected.count.formatted())장" : "‘\(title)’에 \(selected.count.formatted())장 넣기"
    }

    private func cell(_ id: String, isOn: Bool) -> some View {
        let traits: AccessibilityTraits = isOn ? .isSelected : []
        return Button {
            if isOn { selected.remove(id) } else { selected.insert(id) }
        } label: {
            AssetImage(id: id, pixels: 320)
                .aspectRatio(1, contentMode: .fit)
                .opacity(isOn ? 1 : 0.45)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isOn ? Color.accentColor : Color.clear)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .padding(6)
                }
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .accessibilityLabel(Text("제안 사진"))
        .accessibilityAddTraits(traits)
    }

    private func apply() {
        let ids = suggestion.assetIDs.filter(selected.contains)
        model.apply(suggestion, title: title, assetIDs: ids, context: context)
        applied += 1
        dismiss()
    }
}
