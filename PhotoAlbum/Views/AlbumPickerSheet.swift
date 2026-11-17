import SwiftData
import SwiftUI

/// 사진 한 장이 속할 앨범을 여러 개 고른다.
struct AlbumPickerSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var albums: [Album]

    let photo: Photo
    @State private var selected: Set<UUID>
    private let original: Set<UUID>

    init(photo: Photo) {
        self.photo = photo
        let current = Set(photo.links.compactMap { $0.album?.id })
        _selected = State(initialValue: current)
        original = current
    }

    var body: some View {
        NavigationStack {
            AlbumChoiceList(
                selected: $selected,
                signatures: [PhotoSignature(photo)],
                excluded: original,
                footer: selected.isEmpty
                    ? "앨범을 하나 이상 고르세요. 이 앨범에서만 빼려면 사진 메뉴의 ‘이 앨범에서 빼기’를 쓰세요."
                    : "한 사진을 여러 앨범에 넣을 수 있어요 · \(selected.count)개 선택됨"
            )
            .navigationTitle("앨범 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        AlbumStore(context: context).setAlbums(albums.filter { selected.contains($0.id) }, for: photo)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 앨범을 여러 개 고르는 목록. 위에 추천을 먼저 꺼내 놓고, 이름으로 찾을 수 있다.
struct AlbumChoiceList: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Album.sortIndex), SortDescriptor(\Album.createdAt, order: .reverse)])
    private var albums: [Album]

    @Binding var selected: Set<UUID>
    /// 넣으려는 사진들의 날짜와 위치. 추천을 고르는 단서.
    let signatures: [PhotoSignature]
    /// 추천에서 뺄 앨범(이미 들어 있는 앨범).
    var excluded: Set<UUID> = []
    let footer: String

    @State private var query = ""
    @State private var suggestions: [AlbumSuggestion] = []
    @State private var showCreate = false
    @State private var draftTitle = ""

    private var store: AlbumStore { AlbumStore(context: context) }

    private var found: [Album] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? albums : albums.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let results = found
        List {
            if !searching {
                Section {
                    Button {
                        draftTitle = ""
                        showCreate = true
                    } label: {
                        Label("새로운 앨범…", systemImage: "plus")
                    }
                }
                if !suggestions.isEmpty {
                    Section("추천") {
                        ForEach(suggestions) { item in
                            choice(item.album, detail: item.reason)
                        }
                    }
                }
            }
            Section {
                ForEach(results, id: \.id) { choice($0, detail: nil) }
            } header: {
                Text(searching ? "검색 결과" : "모든 앨범")
            } footer: {
                Text(footer)
            }
        }
        .overlay {
            if searching, results.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "앨범 검색")
        .task(id: signatures) {
            let found = await BackgroundQueries.suggestions(
                container: context.container, signatures: signatures, excluding: excluded
            )
            suggestions = found.compactMap { item in
                albums.first { $0.id == item.albumID }.map { AlbumSuggestion(album: $0, reason: item.reason) }
            }
        }
        .alert("새로운 앨범", isPresented: $showCreate) {
            TextField("앨범 이름", text: $draftTitle)
            Button("취소", role: .cancel) {}
            Button("만들기") { selected.insert(store.createAlbum(title: draftTitle).id) }
        }
    }

    private func choice(_ album: Album, detail: String?) -> some View {
        Button {
            if selected.contains(album.id) { selected.remove(album.id) } else { selected.insert(album.id) }
        } label: {
            AlbumRow(album: album, isOn: selected.contains(album.id), detail: detail)
        }
        .buttonStyle(.plain)
    }
}
