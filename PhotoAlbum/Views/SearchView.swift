import SwiftData
import SwiftUI

/// 검색: 앨범을 이름으로 찾는다. 검색어가 없으면 모든 앨범을 목록으로 보여 준다.
struct SearchView: View {
    @Query(sort: [SortDescriptor(\Album.sortIndex), SortDescriptor(\Album.createdAt, order: .reverse)])
    private var albums: [Album]
    @State private var query = ""

    private var results: [Album] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? albums : albums.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        let found = results
        NavigationStack {
            List(found, id: \.id) { album in
                NavigationLink(value: album) { AlbumRow(album: album) }
            }
            .listStyle(.plain)
            .overlay {
                if albums.isEmpty {
                    ContentUnavailableView {
                        Label("앨범이 없습니다", systemImage: "rectangle.stack")
                    } description: {
                        Text("보관함에서 첫 앨범을 만들면 여기서 이름으로 찾을 수 있습니다.")
                    }
                } else if found.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("검색")
            .searchable(text: $query, prompt: "앨범 이름")
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
        }
    }
}
