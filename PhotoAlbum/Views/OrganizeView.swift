import Photos
import SwiftData
import SwiftUI

/// 정리: 아직 어느 앨범에도 없는 사진을 모아 보여 주고, 골라서 앨범에 넣는다.
/// "모든 사진"으로 바꾸면 이미 앨범에 든 사진도 보여서 한 사진을 여러 앨범(2024년, 제주 여행)에 넣을 수 있다.
struct OrganizeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var photos: [Photo]
    @ObservedObject private var access = PhotoAccess.shared
    @ObservedObject private var pro = ProStore.shared

    @Environment(\.modelContext) private var context
    /// 미정리 사진. 보관함 전체를 훑어야 해서 백그라운드에서 구한다.
    @State private var libraryIDs: [String] = []
    /// 이미 앨범에 들어 있는 사진.
    @State private var sortedIDs: Set<String> = []
    @AppStorage("organizeShowsAll") private var showsAll = false
    @State private var reloadToken = 0
    @State private var loaded = false
    @State private var selected: Set<String> = []
    @State private var showAlbums = false
    @State private var addedCount = 0

    // 꾹 눌러 끌어 고르기. 손가락이 있는 곳은 화면 전체 좌표로 받고, 격자 위치를 빼서 칸을 찾는다.
    @State private var isPressing = false
    @State private var drag: GridSelection.Drag?
    @State private var dragLocation: CGPoint?
    @State private var gridFrame = CGRect.zero
    @State private var viewport = CGRect.zero
    @State private var autoScroll: Task<Void, Never>?
    @State private var autoScrollDirection = 0
    @State private var dragTicks = 0
    /// 끌어서 고른 직후 손을 뗄 때 같은 칸의 탭이 한 번 더 눌리지 않게 막는다.
    @State private var ignoreTapsUntil = Date.distantPast
    private static let gridColumns = 3
    private static let gridSpacing: CGFloat = 2

    /// 다시 구해야 하는 때: 권한이 바뀌거나, 앨범에 든 사진 수가 바뀌거나, 탭에 다시 들어왔을 때.
    private struct LoadKey: Equatable {
        let status: Int
        let photoCount: Int
        let token: Int
    }

    var body: some View {
        let items = showsAll ? libraryIDs : libraryIDs.filter { !sortedIDs.contains($0) }
        NavigationStack {
            Group {
                if access.status == .denied || access.status == .restricted {
                    ContentUnavailableView {
                        Label("사진에 접근할 수 없습니다", systemImage: "lock")
                    } description: {
                        Text("설정에서 Folio의 사진 접근을 허용하면 정리할 사진이 여기에 보입니다.")
                    } actions: {
                        Button("설정 열기") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } else if !loaded {
                    ProgressView()
                } else if items.isEmpty {
                    ScrollView {
                        AutoClassifySection()
                        scopePicker
                        if showsAll {
                            ContentUnavailableView("사진이 없습니다", systemImage: "photo")
                        } else {
                            ContentUnavailableView {
                                Label("모두 정리했습니다", systemImage: "checkmark.circle")
                            } description: {
                                Text("사진 보관함의 모든 사진이 앨범에 들어 있습니다. 다른 앨범에도 넣으려면 ‘모든 사진’을 보세요.")
                            }
                        }
                    }
                } else {
                    grid(items)
                }
            }
            .navigationTitle(selected.isEmpty ? "정리" : "\(selected.count)장 선택됨")
            .toolbar {
                if !selected.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("취소") { selected = [] }
                    }
                }
                if !items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(selected.count == items.count ? "선택 해제" : "전체 선택") {
                            selected = selected.count == items.count ? [] : Set(items)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    Button {
                        showAlbums = true
                    } label: {
                        Text("\(selected.count)장 앨범에 넣기")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .offset(y: 16)))
                }
            }
            .animation(reduceMotion ? Motion.reduced : Motion.settle, value: selected.isEmpty)
            .sheet(isPresented: $showAlbums) {
                AddToAlbumsSheet(assetIDs: items.filter { selected.contains($0) }) {
                    selected = []
                    addedCount += 1
                }
            }
            // 사진이 앨범에 들어간 그 순간에만 알린다.
            .sensoryFeedback(.success, trigger: addedCount)
            .task(id: LoadKey(status: access.status.rawValue, photoCount: photos.count, token: reloadToken)) {
                await load()
                refreshAuto()
            }
            .onChange(of: pro.isPro) { _, _ in refreshAuto() }
            // 보이지 않게 된 사진이 선택에 남아 같이 들어가지 않게 한다.
            .onChange(of: showsAll) { _, _ in selected.formIntersection(items) }
            // 다른 앱에서 사진이 늘었을 수 있으니 탭에 들어올 때마다 다시 본다.
            .onAppear { if loaded { reloadToken += 1 } }
        }
    }

    private func grid(_ items: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                gridContent(items, proxy: proxy)
            }
            // 끌어서 고르는 동안에는 손가락이 화면을 밀지 않는다. 끝으로 가면 대신 저절로 넘긴다.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewport = $0 }
            .sensoryFeedback(.selection, trigger: dragTicks)
        }
    }

    private func gridContent(_ items: [String], proxy: ScrollViewProxy) -> some View {
        // 스크롤 뷰가 원래 내용을 쌓던 기본 간격 그대로.
        VStack {
            AutoClassifySection()
            scopePicker
            Text(showsAll
                 ? "사진 \(items.count.formatted())장 · 앨범에 든 사진도 다른 앨범에 넣을 수 있어요"
                 : "미정리 사진 \(items.count.formatted())장 · 아직 어느 앨범에도 없는 사진")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier("unsorted-count")
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing), count: Self.gridColumns),
                spacing: Self.gridSpacing
            ) {
                ForEach(items, id: \.self) { id in
                    cell(id, isOn: selected.contains(id)).id(id)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { gridFrame = $0 }
            .background {
                ScrollLongPress(
                    shouldBegin: { gridFrame.contains($0) },
                    onChange: { location in
                        isPressing = true
                        dragLocation = location
                        extend(items)
                        followEdge(items, proxy: proxy)
                    },
                    onEnd: endDrag
                )
            }
            .accessibilityIdentifier("unsorted-grid")
            .animation(reduceMotion ? Motion.reduced : Motion.settle, value: items)
        }
    }

    // MARK: 꾹 눌러 끌어 고르기

    private var layout: GridSelection.Layout {
        GridSelection.Layout(columns: Self.gridColumns, spacing: Self.gridSpacing, width: gridFrame.width)
    }

    /// 손가락이 있는 칸까지 선택을 넓히거나 줄인다.
    private func extend(_ items: [String]) {
        guard let location = dragLocation, !items.isEmpty else { return }
        let point = CGPoint(x: location.x - gridFrame.minX, y: location.y - gridFrame.minY)
        guard let index = layout.index(at: point, count: items.count) else { return }
        if drag == nil { drag = GridSelection.Drag(anchor: index, items: items, selected: selected) }
        guard let drag else { return }
        let next = drag.selection(to: index, in: items)
        if next != selected {
            selected = next
            dragTicks += 1
        }
    }

    /// 손가락이 화면 위·아래 끝에 있으면 그쪽으로 한 줄씩 넘기며 계속 고른다.
    private func followEdge(_ items: [String], proxy: ScrollViewProxy) {
        guard let y = dragLocation?.y else { return }
        let edge: CGFloat = 80
        let direction = y > viewport.maxY - edge ? 1 : (y < viewport.minY + edge ? -1 : 0)
        guard direction != autoScrollDirection else { return }
        autoScroll?.cancel()
        autoScrollDirection = direction
        guard direction != 0 else {
            autoScroll = nil
            return
        }
        autoScroll = Task { @MainActor in
            while !Task.isCancelled, isPressing {
                // 지금 화면 끝에 걸친 줄의 한 줄 너머를 끝에 맞춘다.
                let edgeY = (direction > 0 ? viewport.maxY : viewport.minY) - gridFrame.minY
                let row = layout.row(at: edgeY) + direction
                let target = min(max(row * Self.gridColumns, 0), items.count - 1)
                withAnimation(.linear(duration: 0.15)) {
                    proxy.scrollTo(items[target], anchor: direction > 0 ? .bottom : .top)
                }
                try? await Task.sleep(for: .milliseconds(150))
                extend(items)
            }
        }
    }

    private func endDrag() {
        isPressing = false
        autoScroll?.cancel()
        autoScroll = nil
        autoScrollDirection = 0
        if drag != nil { ignoreTapsUntil = .now.addingTimeInterval(0.4) }
        drag = nil
        dragLocation = nil
    }

    private var scopePicker: some View {
        Picker("보기", selection: $showsAll) {
            Text("미정리").tag(false)
            Text("모든 사진").tag(true)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .accessibilityIdentifier("organize-scope")
    }

    private func cell(_ id: String, isOn: Bool) -> some View {
        let inAlbum = sortedIDs.contains(id)
        let traits: AccessibilityTraits = isOn ? .isSelected : []
        return Button {
            guard Date.now >= ignoreTapsUntil else { return }
            if isOn { selected.remove(id) } else { selected.insert(id) }
        } label: {
            AssetImage(id: id, pixels: 320)
                .aspectRatio(1, contentMode: .fit)
                .overlay { if isOn { Color.white.opacity(0.28) } }
                .overlay(alignment: .topLeading) {
                    // 모든 사진에서 이미 앨범에 든 사진을 구분한다.
                    if showsAll, inAlbum {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 2)
                            .padding(6)
                    }
                }
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
        .accessibilityLabel(Text(inAlbum ? "앨범에 든 사진" : "미정리 사진"))
        .accessibilityIdentifier("unsorted-photo")
        .accessibilityAddTraits(traits)
    }

    /// 자동 분류 제안을 다시 구한다. Pro면 장면 분석도 이어 간다.
    private func refreshAuto() {
        guard access.status == .authorized || access.status == .limited else { return }
        let model = AutoClassifyModel.shared
        model.refresh(container: context.container)
        if pro.isPro { model.startSceneAnalysis(container: context.container) }
    }

    private func load() async {
        guard access.status == .authorized || access.status == .limited else {
            loaded = access.status != .notDetermined
            return
        }
        let container = context.container
        let (library, used) = await Task.detached(priority: .userInitiated) { () -> ([String], Set<String>) in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            var library: [String] = []
            PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
                library.append(asset.localIdentifier)
            }
            var descriptor = FetchDescriptor<Photo>()
            descriptor.propertiesToFetch = [\.assetIdentifier]
            let used = Set(((try? ModelContext(container).fetch(descriptor)) ?? []).map(\.assetIdentifier))
            return (library, used)
        }.value
        guard !Task.isCancelled else { return }
        libraryIDs = library
        sortedIDs = used
        selected.formIntersection(showsAll ? library : library.filter { !used.contains($0) })
        loaded = true
    }
}

/// 고른 사진들을 넣을 앨범을 여러 개 고른다.
struct AddToAlbumsSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var albums: [Album]

    let assetIDs: [String]
    let onDone: () -> Void

    @State private var selected: Set<UUID> = []
    @State private var signatures: [PhotoSignature] = []

    var body: some View {
        NavigationStack {
            AlbumChoiceList(
                selected: $selected,
                signatures: signatures,
                footer: "사진 \(assetIDs.count)장 · 한 사진을 여러 앨범에 넣을 수 있어요"
            )
            .navigationTitle("앨범에 넣기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료", action: add).disabled(selected.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        // 추천은 고른 사진 앞쪽 일부만 보고 정한다.
        .task { signatures = PhotoLibrary.signatures(for: Array(assetIDs.prefix(60))) }
    }

    private func add() {
        let store = AlbumStore(context: context)
        let dates = PhotoLibrary.creationDates(for: assetIDs)
        let assets = assetIDs.map { (id: $0, takenAt: dates[$0]) }
        for album in albums where selected.contains(album.id) {
            store.add(assets, to: album)
        }
        let context = context
        Task { await PhotoMetadata.refresh(context: context) }
        dismiss()
        onDone()
    }
}

/// 목록에서 앨범 한 줄. `isOn`을 주면 선택 표시가 붙는다.
struct AlbumRow: View {
    let album: Album
    var isOn: Bool?
    /// 사진 수 대신 보여 줄 설명(추천 이유 등).
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if album.isLocked {
                    Color(.tertiarySystemFill)
                        .overlay { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                } else if let id = album.coverIdentifier {
                    AssetImage(id: id, pixels: 200)
                } else {
                    Color(.tertiarySystemFill)
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                Text(detail ?? "사진 \(album.photoCount.formatted())장")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let isOn {
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn == true ? .isSelected : [])
    }
}
