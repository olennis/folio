import SwiftData
import SwiftUI

/// 사진 한 장을 크게 본다. 좌우로 넘기고, 확대하고, 화면을 누르면 막대가 숨는다.
struct PhotoViewerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: Album
    /// 앨범 화면의 캐러셀과 같은 값을 쓴다. 닫을 때 보던 사진 자리로 돌아간다.
    @Binding var currentID: UUID?
    let removed: RemovedPhoto?
    let onRemove: (AlbumPhoto) -> Void
    let onUndo: () -> Void

    @State private var chromeHidden = false
    @State private var editingAlbumsOf: Photo?
    /// 슬라이드쇼가 돌고 있는지.
    @State private var playing = false

    private var store: AlbumStore { AlbumStore(context: context) }
    private var links: [AlbumPhoto] {
        (album.isDeleted || album.modelContext == nil) ? [] : album.orderedLinks
    }

    var body: some View {
        let links = links
        let index = links.firstIndex { $0.id == currentID } ?? 0
        let current = links.indices.contains(index) ? links[index] : nil

        NavigationStack {
            TabView(selection: $currentID) {
                ForEach(links, id: \.id) { link in
                    ZoomablePhoto(id: link.photo?.assetIdentifier ?? "", onSingleTap: toggleChrome)
                        .ignoresSafeArea()
                        .tag(Optional(link.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if !chromeHidden {
                    VStack(spacing: 10) {
                        if removed != nil {
                            UndoBanner(message: "앨범에서 뺐습니다", undo: onUndo)
                        }
                        if let photo = current?.photo { memberships(of: photo) }
                    }
                    .transition(.opacity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .principal) { title(current) }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("앨범 선택", systemImage: "rectangle.stack.badge.plus") {
                        editingAlbumsOf = current?.photo
                    }
                    Spacer()
                    Button("이전 사진", systemImage: "chevron.left") { step(-1) }
                        .disabled(index == 0)
                    Text(verbatim: "\(index + 1) / \(links.count)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .accessibilityIdentifier("viewer-position")
                    Button("다음 사진", systemImage: "chevron.right") { step(1) }
                        .disabled(index >= links.count - 1)
                    Spacer()
                    Button("슬라이드쇼", systemImage: "play.fill", action: startSlideshow)
                        .disabled(links.count < 2)
                    Button("이 앨범에서 빼기", systemImage: "minus.circle") {
                        if let current { onRemove(current) }
                    }
                }
            }
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        }
        .statusBarHidden(chromeHidden)
        .environment(\.colorScheme, .dark)
        .sheet(item: $editingAlbumsOf) { AlbumPickerSheet(photo: $0) }
        .onChange(of: links.isEmpty) { _, isEmpty in
            // 마지막 사진까지 빠지면 닫는다. 실행 취소는 앨범 화면에서 이어서 할 수 있다.
            if isEmpty { dismiss() }
        }
        .onChange(of: current?.photo?.assetIdentifier, initial: true) { _, identifier in
            // 미니 바가 돌아올 자리.
            if let identifier { ViewingSession.shared.record(album: album, assetIdentifier: identifier) }
        }
        .task(id: playing) { await runSlideshow() }
    }

    private func title(_ current: AlbumPhoto?) -> some View {
        let photo = current?.photo
        let date = photo?.takenAt?.formatted(date: .long, time: .omitted)
        let name = photo?.displayTitle
        // 이름이 있으면 윗줄은 이름, 아랫줄은 날짜. 없으면 날짜와 시각.
        var parts: [String] = []
        if name != nil, let date {
            parts.append(date)
        } else if let time = photo?.takenAt?.formatted(date: .omitted, time: .shortened) {
            parts.append(time)
        }
        if let place = photo?.placeName, !place.isEmpty { parts.append(place) }
        let detail = parts.isEmpty ? album.title : parts.joined(separator: " · ")
        return VStack(spacing: 1) {
            Text(name ?? date ?? "날짜 정보 없음")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(verbatim: detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func toggleChrome() {
        // 슬라이드쇼 중에 화면을 누르면 멈추고 막대를 돌려준다.
        if playing {
            playing = false
            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = false }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
        }
    }

    // MARK: 넘기기

    private func step(_ delta: Int) {
        let links = links
        guard let index = links.firstIndex(where: { $0.id == currentID }) ?? links.indices.first else { return }
        let target = index + delta
        guard links.indices.contains(target) else { return }
        withAnimation(reduceMotion ? nil : Motion.settle) { currentID = links[target].id }
    }

    private func startSlideshow() {
        withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = true }
        playing = true
    }

    /// 3초마다 다음 사진으로 넘긴다. 끝에 닿으면 처음으로 돌아간다.
    private func runSlideshow() async {
        guard playing else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, playing else { return }
            let links = links
            guard links.count > 1 else {
                playing = false
                return
            }
            let index = links.firstIndex { $0.id == currentID } ?? -1
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) {
                currentID = links[(index + 1) % links.count].id
            }
        }
    }

    /// 이 사진이 속한 앨범들.
    private func memberships(of photo: Photo) -> some View {
        let albums = store.albums(containing: photo)
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Text("속한 앨범 \(albums.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(albums, id: \.id) { item in
                    Text(item.title)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 8)
    }
}

/// 앨범 화면을 거치지 않고 뷰어만 띄울 때 쓴다(미니 바에서 돌아올 때).
struct ViewerHost: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: Album
    @State private var currentID: UUID?
    @State private var removed: RemovedPhoto?

    init(album: Album, startID: UUID?) {
        self.album = album
        _currentID = State(initialValue: startID)
    }

    private var store: AlbumStore { AlbumStore(context: context) }
    private var settle: Animation { reduceMotion ? Motion.reduced : Motion.settle }

    var body: some View {
        PhotoViewerView(album: album, currentID: $currentID, removed: removed, onRemove: remove, onUndo: undo)
            .task(id: removed?.token) {
                guard removed != nil else { return }
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { withAnimation(settle) { removed = nil } }
            }
    }

    private func remove(_ link: AlbumPhoto) {
        let links = album.orderedLinks
        let index = links.firstIndex { $0.id == link.id } ?? 0
        let neighbor = links.indices.contains(index + 1) ? links[index + 1] : (index > 0 ? links[index - 1] : nil)
        withAnimation(settle) {
            removed = store.remove(link)
            currentID = neighbor?.id
        }
    }

    private func undo() {
        guard let removed else { return }
        withAnimation(settle) {
            if let link = store.restore(removed, to: album) { currentID = link.id }
            self.removed = nil
        }
    }
}
