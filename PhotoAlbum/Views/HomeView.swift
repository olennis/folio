import SwiftData
import SwiftUI

/// 홈: 예전 이맘때의 앨범, 자주 보는 인물, 최근 본 앨범을 먼저 꺼내 놓는다.
struct HomeView: View {
    @Query(sort: [SortDescriptor(\Album.sortIndex), SortDescriptor(\Album.createdAt, order: .reverse)])
    private var albums: [Album]
    @Environment(\.modelContext) private var context
    @Namespace private var zoom
    /// 몇 년 전 오늘의 앨범. 모든 사진을 훑어야 해서 백그라운드에서 구해 둔다.
    @State private var memories: [BackgroundQueries.MemoryResult] = []
    @ObservedObject private var pro = ProStore.shared
    @State private var paywall: ProPaywall.Reason?
    let openLibrary: () -> Void

    /// 앨범이 늘거나 줄거나 사진이 바뀌면 달라지는 값. 이때만 다시 구한다.
    private var albumsKey: [Int] {
        albums.map(\.revision) + [albums.count, albums.filter(\.isLocked).count]
    }

    var body: some View {
        let features = features
        let recent = HomeFeed.recent(in: albums)
        NavigationStack {
            Group {
                if features.isEmpty && recent.isEmpty {
                    ContentUnavailableView {
                        Label("아직 꺼내 놓을 것이 없습니다", systemImage: "sparkles")
                    } description: {
                        Text("앨범을 열어 보면 최근 본 앨범이 여기에 모입니다. 예전 이맘때 찍은 사진이 있으면 그 앨범도 꺼내 드립니다.")
                    } actions: {
                        Button("보관함 열기", action: openLibrary)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if let first = features.first {
                                // 무료일 때는 첫 추천만 흐리게 보여 주고 Pro로 안내한다.
                                if pro.isPro { featured(features) } else { lockedFeature(first) }
                            }
                            if !recent.isEmpty { recents(recent) }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("홈")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        paywall = .upgrade
                    } label: {
                        Label(pro.isPro ? "Folio Pro 사용 중" : "Folio Pro",
                              systemImage: pro.isPro ? "checkmark.seal.fill" : "sparkles")
                    }
                    .accessibilityIdentifier("pro-button")
                }
            }
            .sheet(item: $paywall) { ProPaywall(reason: $0) }
            .task(id: albumsKey) {
                memories = await BackgroundQueries.memories(container: context.container, today: AppClock.today)
            }
            .navigationDestination(for: HomeRoute.self) { route in
                AlbumDetailView(album: route.album)
                    .zoomDestination(id: route.source, in: zoom)
            }
        }
    }

    /// 추천 앨범: 몇 년 전 오늘의 앨범이 먼저, 그다음 자주 보는 인물.
    private var features: [Feature] {
        var used: Set<UUID> = []
        var result: [Feature] = []
        for memory in memories {
            guard let album = albums.first(where: { $0.id == memory.albumID }), !album.isLocked else { continue }
            used.insert(album.id)
            result.append(Feature(
                headline: memory.headline,
                symbol: "clock.arrow.circlepath",
                album: album,
                coverIdentifier: memory.coverIdentifier
            ))
        }
        for album in HomeFeed.frequentPeople(in: albums) where !used.contains(album.id) {
            used.insert(album.id)
            result.append(Feature(
                headline: "자주 보는 인물",
                symbol: "person.crop.circle",
                album: album,
                coverIdentifier: album.coverIdentifier
            ))
        }
        return result
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.title2.bold())
            .padding(.horizontal, 20)
            .accessibilityAddTraits(.isHeader)
    }

    private func featured(_ items: [Feature]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("추천 앨범")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(value: HomeRoute(album: item.album, source: item.id)) {
                            FeatureCard(feature: item)
                                .containerRelativeFrame(.horizontal) { width, _ in max(width - 72, 200) }
                                .frame(height: 380)
                        }
                        .buttonStyle(PressableStyle(scale: 0.98))
                        .zoomSource(id: item.id, in: zoom, cornerRadius: 22)
                        .accessibilityLabel(Text("\(item.headline), \(item.album.title), \(item.album.summary)"))
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func lockedFeature(_ item: Feature) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            header("추천 앨범")
            Button { paywall = .memories } label: {
                AlbumCover(identifier: item.coverIdentifier, pixels: 400)
                    .blur(radius: 18)
                    .overlay { Color.black.opacity(0.2) }
                    .overlay {
                        VStack(spacing: 10) {
                            Label(item.headline, systemImage: item.symbol)
                                .font(.headline)
                            Text("Folio Pro로 열어 보기")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .labelGlass(cornerRadius: 16)
                        }
                        .foregroundStyle(.white)
                        .environment(\.colorScheme, .dark)
                    }
                    .frame(height: 220)
                    .clipShape(shape)
                    .contentShape(shape)
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .padding(.horizontal, 20)
            .accessibilityLabel(Text("\(item.headline), Folio Pro로 열어 보기"))
            .accessibilityIdentifier("locked-feature")
        }
    }

    private func recents(_ items: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("최근 본 앨범")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items, id: \.id) { album in
                        let source = "recent-\(album.id.uuidString)"
                        NavigationLink(value: HomeRoute(album: album, source: source)) {
                            VStack(alignment: .leading, spacing: 6) {
                                AlbumCover(identifier: album.coverIdentifier, pixels: 500)
                                    .frame(width: 150, height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .zoomSource(id: source, in: zoom, cornerRadius: 12)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(album.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(album.periodText() ?? "사진 \(album.photoCount.formatted())장")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 150, alignment: .leading)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("recent-album")
                    }
                }
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }
}

struct HomeRoute: Hashable {
    let album: Album
    /// 줌 전환이 시작될 카드.
    let source: String
}

/// 홈의 큰 추천 카드 하나.
struct Feature: Identifiable {
    let headline: String
    let symbol: String
    let album: Album
    let coverIdentifier: String?
    var id: String { "feature-\(album.id.uuidString)" }
}

struct FeatureCard: View {
    let feature: Feature

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        AlbumCover(identifier: feature.coverIdentifier, pixels: 1000)
            .overlay(alignment: .topLeading) {
                Label(feature.headline, systemImage: feature.symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .labelGlass(cornerRadius: 16)
                    .environment(\.colorScheme, .dark)
                    .padding(14)
            }
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.album.title)
                        .font(.title3.bold())
                        .lineLimit(1)
                    Text(feature.album.summary)
                        .font(.footnote.weight(.medium))
                        .opacity(0.9)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .labelGlass(cornerRadius: 18)
                .environment(\.colorScheme, .dark)
                .padding(12)
            }
            .clipShape(shape)
            .contentShape(shape)
            .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
    }
}

/// 앨범 표지. 사진이 없으면 빈 틀을 그린다.
struct AlbumCover: View {
    let identifier: String?
    var pixels: CGFloat = 600

    var body: some View {
        if let identifier {
            AssetImage(id: identifier, pixels: pixels)
        } else {
            Color(.tertiarySystemFill)
                .overlay { Image(systemName: "photo").font(.title2).foregroundStyle(.secondary) }
        }
    }
}
