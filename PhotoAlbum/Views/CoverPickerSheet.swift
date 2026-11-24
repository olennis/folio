import SwiftData
import SwiftUI

/// 앨범 표지를 고른다. 앨범의 사진을 격자로 보여 주고, 누른 사진이 바로 표지가 된다.
struct CoverPickerSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let album: Album
    @State private var linkCache = OrderedLinksCache()
    @State private var changed = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        let links = linkCache.links(of: album)
        let current = album.coverIdentifier
        NavigationStack {
            ScrollView {
                if album.coverAssetIdentifier != nil {
                    Button("첫 사진으로 되돌리기", systemImage: "arrow.uturn.backward") { choose(nil) }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("cover-reset")
                }
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                        cell(link, index: index, isCover: link.photo?.assetIdentifier == current)
                    }
                }
            }
            .navigationTitle("표지 고르기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
            .overlay {
                if links.isEmpty {
                    ContentUnavailableView("사진이 없습니다", systemImage: "photo.on.rectangle",
                                           description: Text("앨범에 사진을 넣으면 그중 하나를 표지로 고를 수 있어요."))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.selection, trigger: changed)
    }

    private func cell(_ link: AlbumPhoto, index: Int, isCover: Bool) -> some View {
        let traits: AccessibilityTraits = isCover ? .isSelected : []
        return Button {
            choose(link.photo)
        } label: {
            AssetImage(id: link.photo?.assetIdentifier ?? "", pixels: 320)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if isCover {
                        Rectangle().strokeBorder(Color.accentColor, lineWidth: 4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isCover {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.3), radius: 2)
                            .padding(6)
                    }
                }
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .accessibilityLabel(Text(verbatim: "표지 사진 \(index + 1)"))
        .accessibilityAddTraits(traits)
    }

    /// 표지를 바꾸고 닫는다. nil이면 직접 고른 표지를 지우고 첫 사진으로 돌아간다.
    private func choose(_ photo: Photo?) {
        AlbumStore(context: context).setCover(album, to: photo)
        changed += 1
        dismiss()
    }
}
