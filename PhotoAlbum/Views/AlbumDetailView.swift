import PhotosUI
import SwiftData
import SwiftUI

/// 앨범 안: 사진을 가로 캐러셀로 넘겨 본다.
struct AlbumDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var zoom
    let album: Album

    @State private var currentID: UUID?
    /// 아래 사진 줄에서 가운데 온 사진. 끌어서 바꾸면 `currentID`가 따라간다.
    @State private var stripID: UUID?
    @State private var scrubTicks = 0
    /// 위 캐러셀의 위치. 사용자가 넘기면 `currentID`가 따라가고, 다른 곳에서 바뀌면 이쪽이 따라간다.
    @State private var carouselID: UUID?
    /// 캐러셀·줄이 스스로 따라 움직이는 중인 횟수. 그동안 알려 오는 위치는 사용자가 고른 것이 아니다.
    /// 빠르게 여러 번 바뀌면 움직임이 겹치므로 참거짓 대신 센다.
    @State private var syncingCarousel = 0
    @State private var syncingStrip = 0
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showViewer = false
    @State private var editingAlbumsOf: Photo?
    @State private var showRename = false
    @State private var confirmDelete = false
    @State private var draftTitle = ""
    /// 방금 뺀 사진. 잠깐 동안 실행 취소할 수 있다.
    @State private var removed: RemovedPhoto?
    @State private var linkCache = OrderedLinksCache()
    @State private var titling: Photo?
    @State private var draftPhotoTitle = ""

    private var store: AlbumStore { AlbumStore(context: context) }
    private var settle: Animation { reduceMotion ? Motion.reduced : Motion.settle }

    var body: some View {
        // 삭제된 앨범의 속성을 읽지 않도록 막는다(삭제 후 뒤로 가는 동안 잠깐 그려질 수 있다).
        if album.isDeleted || album.modelContext == nil {
            Color.clear
        } else {
            content
        }
    }

    private var content: some View {
        let links = linkCache.links(of: album)
        let current = links.first { $0.id == currentID } ?? links.first

        return VStack(spacing: 0) {
            Text(album.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier("album-summary")
            AccessBanner().padding(.bottom, 8)
            if links.isEmpty {
                ContentUnavailableView {
                    Label("사진이 없습니다", systemImage: "photo.on.rectangle")
                } description: {
                    Text("사진 보관함에서 이 앨범에 넣을 사진을 고르세요. 같은 사진을 다른 앨범에도 넣을 수 있습니다.")
                } actions: {
                    picker { Text("사진 추가") }.buttonStyle(.borderedProminent)
                }
            } else {
                carousel(links)
                caption(current, in: links)
                filmstrip(links, current: current)
            }
        }
        .overlay(alignment: .bottom) { undoBanner.padding(.bottom, 84) }
        .onChange(of: currentID) { _, id in follow(id) }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                picker { Image(systemName: "plus") }
                    .accessibilityLabel("사진 추가")
                Menu {
                    if let current {
                        Section("이 사진") { photoActions(current, in: links) }
                    }
                    Section("앨범") {
                        Button("이름 변경", systemImage: "pencil") {
                            draftTitle = album.title
                            showRename = true
                        }
                        KindPicker(album: album)
                        Button("앨범 삭제", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("더 보기")
            }
        }
        .onChange(of: pickerItems) { _, items in addPicked(items) }
        .fullScreenCover(isPresented: $showViewer) {
            PhotoViewerView(album: album, currentID: $currentID, removed: removed, onRemove: remove, onUndo: undo)
                .zoomDestination(id: currentID, in: zoom)
        }
        .sheet(item: $editingAlbumsOf) { AlbumPickerSheet(photo: $0) }
        .alert("이름 변경", isPresented: $showRename) {
            TextField("앨범 이름", text: $draftTitle)
            Button("취소", role: .cancel) {}
            Button("저장") { store.rename(album, to: draftTitle) }
        }
        .alert("사진 이름", isPresented: Binding(get: { titling != nil }, set: { if !$0 { titling = nil } })) {
            TextField("예: 성산일출봉의 아침", text: $draftPhotoTitle)
            Button("취소", role: .cancel) {}
            Button("저장") { if let titling { store.setTitle(titling, to: draftPhotoTitle) } }
        } message: {
            Text("이름은 사진에 붙어서 다른 앨범에서도 똑같이 보입니다. 비워 두면 촬영 날짜를 보여 줍니다.")
        }
        .task {
            // 홈의 최근 본 앨범과 자주 보는 인물이 이 기록을 쓴다.
            store.markOpened(album)
        }
        .confirmationDialog("이 앨범을 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("앨범 삭제", role: .destructive) {
                let target = album
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    store.delete(target)
                }
            }
        } message: {
            Text("사진 원본과 다른 앨범에 들어 있는 사진은 지워지지 않습니다.")
        }
        .task(id: removed?.token) {
            // 실행 취소 안내는 잠깐만 보여 준다.
            guard removed != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { withAnimation(settle) { removed = nil } }
        }
        #if DEBUG
        .task {
            if DebugLaunch.consumeOpenViewer(), CommandLine.arguments.contains("-openViewer") {
                try? await Task.sleep(for: .seconds(1))
                open(linkCache.links(of: album).first)
            }
        }
        #endif
    }

    @ViewBuilder
    private var undoBanner: some View {
        if removed != nil, !showViewer {
            UndoBanner(message: "앨범에서 뺐습니다", undo: undo)
        }
    }

    // MARK: 캐러셀

    private func carousel(_ links: [AlbumPhoto]) -> some View {
        GeometryReader { geo in
            let width = max(geo.size.width - 128, 120)
            let height = max(geo.size.height - 28, 120)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                        carouselCard(link, index: index, in: links)
                            .frame(width: width, height: height)
                    }
                }
                .scrollTargetLayout()
                .frame(height: geo.size.height)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $carouselID)
            .safeAreaPadding(.horizontal, 64)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .onAppear { carouselID = currentID ?? links.first?.id }
        .onChange(of: carouselID) { _, id in
            guard syncingCarousel == 0, let id, id != currentID else { return }
            currentID = id
        }
    }

    private func carouselCard(_ link: AlbumPhoto, index: Int, in links: [AlbumPhoto]) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let reduceMotion = reduceMotion
        return Button {
            open(link)
        } label: {
            AssetImage(id: link.photo?.assetIdentifier ?? "", pixels: 1200)
                .clipShape(shape)
                .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .zoomSource(id: Optional(link.id), in: zoom, cornerRadius: 20)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
        .scrollTransition(.interactive) { view, phase in
            view.scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.88)
                .opacity(phase.isIdentity ? 1 : 0.75)
        }
        .contextMenu { photoActions(link, in: links) }
        .accessibilityLabel(Text(verbatim: "사진 \(index + 1) 크게 보기"))
        .accessibilityIdentifier("carousel-photo-\(index + 1)")
    }

    private func caption(_ current: AlbumPhoto?, in links: [AlbumPhoto]) -> some View {
        let index = links.firstIndex { $0.id == current?.id } ?? 0
        let memberships = current?.photo?.links.count ?? 1
        let photo = current?.photo
        let date = photo?.takenAt?.formatted(date: .long, time: .omitted)
        let name = photo?.displayTitle
        var parts = ["\(index + 1) / \(links.count)"]
        // 이름이 제목 자리를 차지하면 날짜는 아랫줄로 내려간다.
        if name != nil, let date { parts.append(date) }
        if let place = photo?.placeName, !place.isEmpty { parts.append(place) }
        if memberships > 1 { parts.append("앨범 \(memberships)곳에 속함") }
        let detail = parts.joined(separator: " · ")
        return VStack(spacing: 3) {
            Text(name ?? date ?? "날짜 정보 없음")
                .font(.headline)
                .lineLimit(1)
                .accessibilityIdentifier("photo-title")
            Text(verbatim: detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("album-position")
        }
        .padding(.top, 4)
    }

    /// 사진 앱의 스크러버처럼 동작한다. 끌면 가운데 온 사진이 지금 사진이 되고, 위 캐러셀이 따라간다.
    /// 캐러셀을 넘기면 반대로 이 줄이 따라온다. 누르면 그 사진으로 건너뛴다.
    private func filmstrip(_ links: [AlbumPhoto], current: AlbumPhoto?) -> some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                LazyHStack(spacing: Self.thumbSpacing) {
                    ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                        thumb(link, index: index, isCurrent: link.id == current?.id)
                    }
                }
                .scrollTargetLayout()
            }
            // 썸네일 하나가 정확히 가운데 오도록 양옆을 비운다.
            .contentMargins(.horizontal, max((geo.size.width - Self.thumbWidth) / 2, 0), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $stripID, anchor: .center)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("filmstrip")
        }
        .frame(height: 52)
        .padding(.vertical, 8)
        .onAppear { stripID = currentID ?? links.first?.id }
        // 줄을 끌어 가운데 사진이 바뀌면 그 사진을 고른다.
        .onChange(of: stripID) { _, id in
            guard syncingStrip == 0, let id, id != currentID else { return }
            scrubTicks += 1
            currentID = id
        }
        .sensoryFeedback(.selection, trigger: scrubTicks)
    }

    private static let thumbWidth: CGFloat = 34
    private static let thumbSpacing: CGFloat = 4

    /// 지금 사진이 바뀌면 캐러셀과 아래 줄을 그 사진으로 옮긴다. 이미 그 자리인 쪽은 두고, 움직이는 동안의 위치 소식은 무시한다.
    private func follow(_ id: UUID?) {
        if carouselID != id {
            syncingCarousel += 1
            withAnimation(settle) { carouselID = id } completion: { syncingCarousel -= 1 }
        }
        if stripID != id {
            syncingStrip += 1
            withAnimation(settle) { stripID = id } completion: { syncingStrip -= 1 }
        }
    }

    private func thumb(_ link: AlbumPhoto, index: Int, isCurrent: Bool) -> some View {
        let traits: AccessibilityTraits = isCurrent ? .isSelected : []
        let shape = RoundedRectangle(cornerRadius: isCurrent ? 5 : 3, style: .continuous)
        return Button {
            withAnimation(settle) { currentID = link.id }
        } label: {
            // 크기는 모두 같게 두고 지금 사진만 키워 보인다. 끄는 도중에 줄의 길이가 바뀌면 덜컹거린다.
            AssetImage(id: link.photo?.assetIdentifier ?? "", pixels: 160)
                .frame(width: Self.thumbWidth, height: 44)
                .clipShape(shape)
                .overlay { if isCurrent { shape.strokeBorder(Color.accentColor, lineWidth: 2) } }
                .opacity(isCurrent ? 1 : 0.8)
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .scaleEffect(isCurrent ? 1.18 : 1)
        .zIndex(isCurrent ? 1 : 0)
        .animation(settle, value: isCurrent)
        .id(link.id)
        .accessibilityLabel(Text(verbatim: "사진 \(index + 1)"))
        .accessibilityAddTraits(traits)
    }

    // MARK: 동작

    @ViewBuilder
    private func photoActions(_ link: AlbumPhoto, in links: [AlbumPhoto]) -> some View {
        let index = links.firstIndex { $0.id == link.id } ?? 0
        Button("다른 앨범에도 넣기…", systemImage: "rectangle.stack.badge.plus") {
            editingAlbumsOf = link.photo
        }
        Button(link.photo?.displayTitle == nil ? "사진 이름 붙이기…" : "사진 이름 바꾸기…", systemImage: "pencil") {
            draftPhotoTitle = link.photo?.title ?? ""
            titling = link.photo
        }
        Button("앨범 표지로 설정", systemImage: "photo") {
            store.setCover(album, to: link.photo)
        }
        Button("앞으로 옮기기", systemImage: "arrow.left") {
            withAnimation(settle) { store.move(link, by: -1) }
        }
        .disabled(index == 0)
        Button("뒤로 옮기기", systemImage: "arrow.right") {
            withAnimation(settle) { store.move(link, by: 1) }
        }
        .disabled(index == links.count - 1)
        Button("이 앨범에서 빼기", systemImage: "minus.circle", role: .destructive) { remove(link) }
    }

    /// 확인 창 없이 바로 빼고, 대신 실행 취소를 준다. 원본은 그대로라 되돌릴 수 있는 동작이다.
    private func remove(_ link: AlbumPhoto) {
        let links = linkCache.links(of: album)
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

    private func open(_ link: AlbumPhoto?) {
        guard let link else { return }
        currentID = link.id
        showViewer = true
    }

    private func picker<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        PhotosPicker(selection: $pickerItems, matching: .images, photoLibrary: .shared(), label: label)
    }

    private func addPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let ids = items.compactMap(\.itemIdentifier)
        pickerItems = []
        Task {
            await PhotoAccess.shared.requestIfNeeded()
            let dates = PhotoLibrary.creationDates(for: ids)
            let added = store.add(ids.map { (id: $0, takenAt: dates[$0]) }, to: album)
            let context = context
            Task { await PhotoMetadata.refresh(context: context) }
            if let first = added.first {
                withAnimation(settle) { currentID = first.id }
            }
        }
    }
}
