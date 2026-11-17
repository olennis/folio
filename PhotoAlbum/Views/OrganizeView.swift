import Photos
import SwiftData
import SwiftUI

/// 정리: 아직 어느 앨범에도 없는 사진만 모아 보여 주고, 골라서 앨범에 넣는다.
struct OrganizeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var photos: [Photo]
    @ObservedObject private var access = PhotoAccess.shared

    @State private var libraryIDs: [String] = []
    @State private var loaded = false
    @State private var selected: Set<String> = []
    @State private var showAlbums = false
    @State private var addedCount = 0

    /// 사진 보관함에는 있지만 어느 앨범에도 없는 사진. 최근 사진이 먼저.
    private var unsorted: [String] {
        let used = Set(photos.map(\.assetIdentifier))
        return libraryIDs.filter { !used.contains($0) }
    }

    var body: some View {
        let items = unsorted
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
                    ContentUnavailableView {
                        Label("모두 정리했습니다", systemImage: "checkmark.circle")
                    } description: {
                        Text("사진 보관함의 모든 사진이 앨범에 들어 있습니다.")
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
            .task(id: access.status.rawValue) { load() }
            .onAppear { if loaded { load() } }
        }
    }

    private func grid(_ items: [String]) -> some View {
        ScrollView {
            Text("미정리 사진 \(items.count.formatted())장 · 아직 어느 앨범에도 없는 사진")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier("unsorted-count")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(items, id: \.self) { id in
                    cell(id, isOn: selected.contains(id))
                }
            }
            .animation(reduceMotion ? Motion.reduced : Motion.settle, value: items)
        }
    }

    private func cell(_ id: String, isOn: Bool) -> some View {
        let traits: AccessibilityTraits = isOn ? .isSelected : []
        return Button {
            if isOn { selected.remove(id) } else { selected.insert(id) }
        } label: {
            AssetImage(id: id, pixels: 320)
                .aspectRatio(1, contentMode: .fit)
                .overlay { if isOn { Color.white.opacity(0.28) } }
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
        .accessibilityLabel(Text("미정리 사진"))
        .accessibilityAddTraits(traits)
    }

    private func load() {
        guard access.status == .authorized || access.status == .limited else {
            loaded = access.status != .notDetermined
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var ids: [String] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        libraryIDs = ids
        selected.formIntersection(ids)
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
                if let id = album.coverIdentifier {
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
                Text(detail ?? "사진 \(album.orderedLinks.count.formatted())장")
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
