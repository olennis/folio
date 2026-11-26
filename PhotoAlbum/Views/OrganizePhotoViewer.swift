import SwiftUI

/// 정리 탭에서 사진을 크게 본다. 좌우로 넘기고, 확대하고, 보면서 고를 수 있다.
///
/// 보관함 전체(수천 장)를 넘길 수 있게 가로 스크롤을 게으르게 그린다.
struct OrganizePhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let items: [String]
    /// 사진이 든 앨범 이름. 앨범에 없는 사진은 빠져 있다.
    let albumNames: [String: [String]]
    @Binding var selected: Set<String>
    @State var currentID: String?

    @State private var chromeHidden = false

    var body: some View {
        let id = currentID ?? items.first
        let index = id.flatMap { items.firstIndex(of: $0) } ?? 0
        let isOn = id.map(selected.contains) ?? false

        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(items, id: \.self) { item in
                            ZoomablePhoto(id: item) {
                                withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
                            }
                            .containerRelativeFrame([.horizontal, .vertical])
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID)
                .scrollIndicators(.hidden)
                // 누른 사진에서 시작한다. 멀리 있는 사진은 게으른 목록이 아직 그리지 않아 직접 옮긴다.
                .onAppear { if let id { proxy.scrollTo(id) } }
                .ignoresSafeArea()
                .background(Color.black.ignoresSafeArea())
                .safeAreaInset(edge: .bottom) {
                    if !chromeHidden, let id, let names = albumNames[id] {
                        Text(names.isEmpty ? "앨범에 든 사진" : names.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(.bottom, 8)
                            .accessibilityIdentifier("organize-viewer-albums")
                            .transition(.opacity)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("닫기", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .principal) {
                        Text(date(of: id))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Text(verbatim: "\(index + 1) / \(items.count)")
                            .font(.subheadline)
                            .monospacedDigit()
                            .fixedSize()
                            .accessibilityIdentifier("organize-viewer-position")
                        Spacer()
                        Button {
                            guard let id else { return }
                            if isOn { selected.remove(id) } else { selected.insert(id) }
                        } label: {
                            Label(isOn ? "선택됨" : "선택", systemImage: isOn ? "checkmark.circle.fill" : "circle")
                                .labelStyle(.titleAndIcon)
                        }
                        .accessibilityIdentifier("organize-viewer-select")
                    }
                }
                .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
                .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            }
        }
        .statusBarHidden(chromeHidden)
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.selection, trigger: selected.count)
    }

    private func date(of id: String?) -> String {
        guard let id, let date = PhotoLibrary.asset(id)?.creationDate else { return "날짜 정보 없음" }
        return date.formatted(date: .long, time: .omitted)
    }
}
