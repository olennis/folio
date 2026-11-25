import SwiftData
import SwiftUI

enum AppTab: Hashable {
    case home, library, organize, search
}

/// 하단 탭 바와 그 위의 미니 바. 탭마다 자기 내비게이션 스택을 가진다.
struct RootView: View {
    @Query private var albums: [Album]
    @ObservedObject private var session = ViewingSession.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.home
    @State private var resuming: ResumeTarget?

    /// 미니 바가 돌아갈 자리. 앨범이 지워졌거나 사진이 빠졌으면 없다.
    private var target: ResumeTarget? {
        guard let albumID = session.albumID, let assetIdentifier = session.assetIdentifier,
              // 비밀 앨범의 사진은 미니 바에 띄우지 않는다.
              let album = albums.first(where: { $0.id == albumID }), !album.isLocked,
              let link = album.orderedLinks.first(where: { $0.photo?.assetIdentifier == assetIdentifier }),
              let photo = link.photo
        else { return nil }
        return ResumeTarget(album: album, photo: photo, linkID: link.id)
    }

    var body: some View {
        tabs
            .fullScreenCover(item: $resuming) { ViewerHost(album: $0.album, startID: $0.linkID) }
            // 앱을 떠나면 열어 둔 비밀 앨범을 모두 다시 잠근다.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { SecretLock.shared.lockAll() }
            }
    }

    @ViewBuilder
    private var tabs: some View {
        let target = target
        if #available(iOS 26.1, *) {
            // 음악 앱의 미니 플레이어 자리. 탭 바 위에 시스템이 유리 재질로 띄운다.
            modernTabs.tabViewBottomAccessory(isEnabled: target != nil) {
                if let target { MiniBar(target: target) { resuming = target } }
            }
        } else if #available(iOS 18.0, *) {
            modernTabs.overlay(alignment: .bottom) { floatingBar(target) }
        } else {
            TabView(selection: $tab) {
                HomeView(openLibrary: openLibrary)
                    .tabItem { Label("홈", systemImage: "house.fill") }
                    .tag(AppTab.home)
                LibraryView()
                    .tabItem { Label("보관함", systemImage: "rectangle.stack.fill") }
                    .tag(AppTab.library)
                OrganizeView()
                    .tabItem { Label("정리", systemImage: "tray.full.fill") }
                    .tag(AppTab.organize)
                SearchView()
                    .tabItem { Label("검색", systemImage: "magnifyingglass") }
                    .tag(AppTab.search)
            }
            .overlay(alignment: .bottom) { floatingBar(target) }
        }
    }

    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: $tab) {
            Tab("홈", systemImage: "house.fill", value: AppTab.home) {
                HomeView(openLibrary: openLibrary)
            }
            Tab("보관함", systemImage: "rectangle.stack.fill", value: AppTab.library) {
                LibraryView()
            }
            Tab("정리", systemImage: "tray.full.fill", value: AppTab.organize) {
                OrganizeView()
            }
            Tab("검색", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
    }

    /// 시스템 미니 바 자리가 없는 OS에서는 탭 바 바로 위에 직접 띄운다.
    @ViewBuilder
    private func floatingBar(_ target: ResumeTarget?) -> some View {
        if let target {
            MiniBar(target: target) { resuming = target }
                .frame(height: 48)
                .labelGlass(cornerRadius: 24)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .padding(.horizontal, 20)
                .padding(.bottom, 58)
        }
    }

    private func openLibrary() { tab = .library }
}

/// 미니 바가 가리키는 사진.
struct ResumeTarget: Identifiable {
    let album: Album
    let photo: Photo
    let linkID: UUID
    var id: UUID { linkID }
}

/// 보던 사진으로 돌아가는 막대. 누르면 그 사진이 뷰어로 열린다.
struct MiniBar: View {
    let target: ResumeTarget
    let action: () -> Void

    private var title: String {
        target.photo.displayTitle
            ?? target.photo.takenAt?.formatted(date: .long, time: .omitted)
            ?? "날짜 정보 없음"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AssetImage(id: target.photo.assetIdentifier, pixels: 120)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(target.album.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("보던 사진으로 돌아가기, \(title), \(target.album.title)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("mini-bar")
    }
}
