import SwiftData
import SwiftUI

/// 보관함: 앨범이 카드 더미로 쌓여 있다. 위아래로 넘기면 순서가 돌고, 앞 카드를 누르면 열린다.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: [SortDescriptor(\Album.sortIndex), SortDescriptor(\Album.createdAt, order: .reverse)])
    private var allAlbums: [Album]
    @Namespace private var zoom

    /// 걸러 볼 종류. nil이면 전체.
    @State private var filter: AlbumKind?
    /// 지금 필터에 맞는 앨범. 카드 더미는 이것만 쌓는다.
    private var albums: [Album] {
        guard let filter else { return allAlbums }
        return allAlbums.filter { $0.kind == filter }
    }

    @State private var path: [Album] = []
    @State private var front = 0
    @State private var drag: CGFloat = 0
    /// 끄는 중에는 손을 떼도 카드가 눌린 것으로 치지 않는다.
    @State private var isDragging = false

    @State private var showCreate = false
    @State private var renaming: Album?
    @State private var deleting: Album?
    @State private var draftTitle = ""

    private var store: AlbumStore { AlbumStore(context: context) }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 8) {
                AccessBanner()
                if !allAlbums.isEmpty {
                    Picker("종류", selection: $filter) {
                        Text("전체").tag(AlbumKind?.none)
                        ForEach([AlbumKind.year, .person, .place]) { kind in
                            Text(kind.label).tag(AlbumKind?.some(kind))
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                }
                if let filter, albums.isEmpty, !allAlbums.isEmpty {
                    ContentUnavailableView {
                        Label("\(filter.label) 앨범이 없습니다", systemImage: filter.symbol)
                    } description: {
                        Text("앨범을 길게 눌러 종류를 바꾸거나, 여기서 새 앨범을 만들면 \(filter.label) 앨범이 됩니다.")
                    } actions: {
                        Button("새로운 \(filter.label) 앨범") { beginCreate() }
                            .buttonStyle(.borderedProminent)
                    }
                } else if albums.isEmpty {
                    ContentUnavailableView {
                        Label("앨범이 없습니다", systemImage: "rectangle.stack")
                    } description: {
                        Text("연도, 인물, 여행처럼 묶고 싶은 단위로 첫 앨범을 만들어 보세요.")
                    } actions: {
                        Button("새로운 앨범") { beginCreate() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    GeometryReader { geo in deck(in: geo.size) }
                    if albums.count > 1 {
                        Text(verbatim: "\(front % albums.count + 1) / \(albums.count)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.bottom, 8)
                            .accessibilityIdentifier("deck-position")
                    }
                }
            }
            .navigationTitle("보관함")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("새로운 앨범", systemImage: "plus", action: beginCreate)
                }
            }
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView(album: album)
                    .zoomDestination(id: album.id, in: zoom)
            }
            .alert("새로운 앨범", isPresented: $showCreate) {
                TextField("앨범 이름", text: $draftTitle)
                Button("취소", role: .cancel) {}
                Button("만들기") {
                    // 종류를 걸러 보는 중이면 그 종류의 앨범으로 만든다.
                    store.createAlbum(title: draftTitle, kind: filter)
                    withAnimation(animation(Motion.settle)) { front = 0 }
                }
            }
            .alert("이름 변경", isPresented: isPresenting($renaming)) {
                TextField("앨범 이름", text: $draftTitle)
                Button("취소", role: .cancel) {}
                Button("저장") { if let renaming { store.rename(renaming, to: draftTitle) } }
            }
            .confirmationDialog(
                "‘\(deleting?.title ?? "")’ 앨범을 삭제할까요?",
                isPresented: isPresenting($deleting),
                titleVisibility: .visible
            ) {
                Button("앨범 삭제", role: .destructive) {
                    if let deleting {
                        withAnimation(animation(Motion.settle)) {
                            store.delete(deleting)
                            front = 0
                        }
                    }
                }
            } message: {
                Text("사진 원본과 다른 앨범에 들어 있는 사진은 지워지지 않습니다.")
            }
            // 카드가 제자리에 들어가는 그 순간에만 울린다.
            .sensoryFeedback(.selection, trigger: front)
            .onChange(of: filter) { _, _ in
                drag = 0
                withAnimation(animation(Motion.settle)) { front = 0 }
            }
            #if DEBUG
            .task {
                // 캡처용 실행 옵션. 보관함으로 돌아올 때 다시 열리지 않도록 한 번만 실행한다.
                let arguments = CommandLine.arguments
                if DebugLaunch.consumeOpenAlbum(), arguments.contains("-openAlbum") || arguments.contains("-openViewer") {
                    try? await Task.sleep(for: .seconds(1))
                    if let first = allAlbums.first { path = [first] }
                }
            }
            #endif
        }
    }

    // MARK: 카드 더미

    private func deck(in size: CGSize) -> some View {
        let count = albums.count
        let current = front % count
        let items = deckItems(in: size, current: current)

        return ZStack(alignment: .top) {
            ForEach(items) { item in
                Button {
                    tap(item, current: current, count: count)
                } label: {
                    AlbumCard(album: item.album, frontness: item.frontness)
                }
                .buttonStyle(PressableStyle(scale: item.index == 0 ? 0.98 : 0.96))
                .zoomSource(id: item.album.id, in: zoom, cornerRadius: 24)
                .frame(width: item.size.width, height: item.size.height)
                .scaleEffect(item.scale, anchor: .top)
                .opacity(item.opacity)
                .offset(y: item.offset)
                .zIndex(Double(-item.index))
                // 더미에서 빠지고 들어올 때 같은 길로 오간다.
                .transition(.opacity.combined(with: .offset(y: 120)))
                .contextMenu { cardMenu(item.album) }
                .accessibilityLabel(Text(verbatim: "\(item.album.title), 사진 \(item.album.orderedLinks.count)장"))
                .accessibilityAction(named: "다음 앨범") { front = (current + 1) % count }
                .accessibilityAction(named: "이전 앨범") { front = (current - 1 + count) % count }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    isDragging = true
                    drag = value.translation.height
                }
                .onEnded { value in release(value, current: current, count: count) }
        )
    }

    /// 카드마다 놓일 자리를 계산한다. 아래로 끄는 만큼 뒤 카드가 손가락을 따라 앞으로 나온다.
    private func deckItems(in size: CGSize, current: Int) -> [DeckItem] {
        let count = albums.count
        let visible = min(count, 4)
        let backs = CGFloat(visible - 1)
        let peek: CGFloat = 44
        let backHeight: CGFloat = 150
        let frontWidth = size.width - 40
        let frontHeight = max(200, min(size.height - backs * peek - 8, frontWidth * 1.3))
        let canFlip = count > 1
        let advance: CGFloat = canFlip ? min(max(drag / 260, 0), 1) : 0
        // 넘길 수 있는 방향(아래)은 손가락과 1:1, 그 밖에는 탄성 저항.
        let pull: CGFloat = (canFlip && drag > 0) ? drag : Motion.rubberBand(drag, dimension: frontHeight)

        return (0..<visible).map { index in
            let isFront = index == 0
            let depth: CGFloat = isFront ? 0 : CGFloat(index) - advance
            let height: CGFloat = depth < 1 ? frontHeight + (backHeight - frontHeight) * depth : backHeight
            return DeckItem(
                index: index,
                album: albums[(current + index) % count],
                frontness: isFront ? 1 : max(0, 1 - depth),
                size: CGSize(width: frontWidth * (1 - 0.13 * depth), height: height),
                offset: (backs - depth) * peek + (isFront ? pull : 0),
                scale: isFront ? 1 - 0.05 * advance : 1,
                opacity: isFront ? 1 - 0.45 * advance : 1
            )
        }
    }

    private func tap(_ item: DeckItem, current: Int, count: Int) {
        guard !isDragging else { return }
        if item.index == 0 {
            path.append(item.album)
        } else {
            withAnimation(animation(Motion.settle)) { front = (current + item.index) % count }
        }
    }

    /// 손을 뗀 지점이 아니라 손가락이 가던 곳(예상 도착점)을 보고 넘길지 정한다.
    private func release(_ value: DragGesture.Value, current: Int, count: Int) {
        let distance = value.translation.height
        let projected = value.predictedEndTranslation.height
        withAnimation(animation(Motion.flick)) {
            if count > 1, distance > 90 || projected > 260 {
                front = (current + 1) % count
            } else if count > 1, distance < -70 || projected < -220 {
                front = (current - 1 + count) % count
            }
            drag = 0
        }
        DispatchQueue.main.async { isDragging = false }
    }

    @ViewBuilder
    private func cardMenu(_ album: Album) -> some View {
        Button("이름 변경", systemImage: "pencil") {
            draftTitle = album.title
            renaming = album
        }
        KindPicker(album: album)
        Button("앨범 삭제", systemImage: "trash", role: .destructive) { deleting = album }
    }

    private func animation(_ base: Animation) -> Animation {
        reduceMotion ? Motion.reduced : base
    }

    private func beginCreate() {
        draftTitle = ""
        showCreate = true
    }

    private func isPresenting<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// 카드 더미에서 카드 한 장이 놓일 자리.
private struct DeckItem: Identifiable {
    let index: Int
    let album: Album
    let frontness: CGFloat
    let size: CGSize
    let offset: CGFloat
    let scale: CGFloat
    let opacity: CGFloat
    var id: UUID { album.id }
}

/// 카드 더미의 카드 한 장. `frontness`가 1이면 맨 앞(유리 라벨), 0이면 뒤(위쪽 띠에 이름).
struct AlbumCard: View {
    let album: Album
    var frontness: CGFloat

    private var count: Int { album.orderedLinks.count }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 24, style: .continuous) }

    var body: some View {
        cover
            .overlay { Color.black.opacity(0.22 * (1 - frontness)) }
            .overlay(alignment: .top) {
                HStack(spacing: 6) {
                    Text(album.title).font(.headline).lineLimit(1)
                    Text(count.formatted()).font(.footnote.weight(.semibold)).opacity(0.85)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .opacity(1 - frontness)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 2) {
                    Text(album.title).font(.title2.bold()).lineLimit(1)
                    Text("사진 \(count.formatted())장").font(.footnote.weight(.semibold)).opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .labelGlass(cornerRadius: 20)
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .opacity(frontness)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.18), radius: 10, y: -2)
            .contentShape(shape)
    }

    @ViewBuilder
    private var cover: some View {
        if let id = album.coverIdentifier {
            AssetImage(id: id, pixels: 1200)
        } else {
            Color(.systemGray)
                .overlay {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.7 * frontness))
                }
        }
    }
}

/// 앨범의 종류를 고르는 메뉴 항목. 카드와 앨범 화면의 메뉴가 같이 쓴다.
struct KindPicker: View {
    @Environment(\.modelContext) private var context
    let album: Album

    var body: some View {
        let kind = Binding<AlbumKind>(
            get: { album.kind },
            set: { AlbumStore(context: context).setKind(album, to: $0) }
        )
        Picker(selection: kind) {
            ForEach(AlbumKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
        } label: {
            Label("종류", systemImage: "tag")
        }
        .pickerStyle(.menu)
    }
}
