import Photos
import SwiftData
import SwiftUI

/// 정리 탭의 "인물". Pro는 찾은 사람을 얼굴로 보고, 무료는 잠긴 줄을 본다. 켜지 않았으면 켜는 카드를 본다.
struct PeopleSection: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var pro = ProStore.shared
    @ObservedObject private var indexer = PeopleIndexer.shared
    @AppStorage(PeopleSettings.enabledKey) private var enabled = false
    @State private var people: [PersonSummary] = []
    @State private var consent = false
    @State private var paywall: ProPaywall.Reason?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("인물")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if pro.isPro, enabled, let progress = indexer.progress {
                    Text("얼굴 찾는 중 \(progress.done.formatted())/\(progress.total.formatted())")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("people-progress")
                } else if pro.isPro, enabled, !people.isEmpty {
                    NavigationLink("모두 보기") { PeopleView() }
                        .font(.subheadline)
                        .accessibilityIdentifier("people-all")
                }
            }
            .padding(.horizontal, 20)

            if !pro.isPro {
                Button { paywall = .people } label: {
                    LockedRow(title: "인물별로 묶기", detail: "Folio Pro에서 같은 사람이 나온 사진을 찾아 앨범으로 묶어 드려요")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("locked-people")
            } else if !enabled {
                Button { consent = true } label: {
                    LockedRow(title: "인물 찾기 켜기", detail: "같은 사람이 나온 사진을 찾아요. 얼굴 분석은 기기 안에서만 해요", symbol: "person.crop.circle.badge.plus", badge: "켜기")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("people-enable")
            } else if people.isEmpty {
                Text(indexer.progress == nil ? "아직 찾은 사람이 없어요. 사진이 늘면 다시 찾아요." : "사진을 살펴보며 사람을 찾고 있어요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                faces
            }
        }
        .padding(.bottom, 16)
        .sheet(item: $paywall) { ProPaywall(reason: $0) }
        .sheet(isPresented: $consent) { PeopleConsentView() }
        .task(id: "\(indexer.revision)#\(enabled)") { reload() }
        // 다 살펴보면 인물 앨범 제안을 새로 구한다.
        .onChange(of: indexer.progress == nil) { _, idle in
            if idle, enabled, pro.isPro { AutoClassifyModel.shared.refresh(container: context.container) }
        }
    }

    private var faces: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(people.prefix(12)) { person in
                    NavigationLink { PersonDetailView(personID: person.id) } label: {
                        VStack(spacing: 6) {
                            FaceThumbnail(assetID: person.faceAssetID, box: person.faceBox, size: 68)
                            Text(person.displayName)
                                .font(.caption)
                                .foregroundStyle(person.name == nil ? .secondary : .primary)
                                .lineLimit(1)
                        }
                        .frame(width: 76)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(person.displayName), 사진 \(person.photoCount)장")
                    .accessibilityIdentifier("person-chip")
                }
            }
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollIndicators(.hidden)
    }

    private func reload() {
        guard enabled, let container = indexer.container else {
            people = []
            return
        }
        people = PeopleQuery.people(in: container)
    }
}

/// 찾은 사람 전체. 얼굴 격자에 이름과 사진 수를 붙인다.
struct PeopleView: View {
    @ObservedObject private var indexer = PeopleIndexer.shared
    @ObservedObject private var access = PhotoAccess.shared
    @State private var people: [PersonSummary] = []
    @State private var showHidden = false
    @State private var renaming: PersonSummary?
    @State private var merging: PersonSummary?
    @State private var settings = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        ScrollView {
            if access.status == .limited { LimitedAccessBanner().padding(.horizontal, 20) }
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(people) { person in
                    NavigationLink { PersonDetailView(personID: person.id) } label: { cell(person) }
                        .buttonStyle(PressableStyle())
                        .contextMenu { menu(person) }
                        .accessibilityIdentifier("person-cell")
                }
            }
            .padding(20)
            if people.isEmpty {
                ContentUnavailableView("찾은 사람이 없어요", systemImage: "person.2", description: Text(showHidden ? "숨긴 사람도 없어요." : "사진을 살펴보면 여기에 사람이 모여요."))
            }
        }
        .navigationTitle("인물")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("숨긴 사람 보기", systemImage: "eye.slash", isOn: $showHidden)
                    Button("인물 설정", systemImage: "gearshape") { settings = true }
                    #if DEBUG
                    NavigationLink { FaceAlignmentDebugView() } label: { Label("정렬 디버그", systemImage: "ladybug") }
                    #endif
                } label: {
                    Label("더 보기", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $settings) { PeopleSettingsView() }
        .sheet(item: $merging) { MergePeopleSheet(source: $0) }
        .modifier(RenamePersonAlert(person: $renaming))
        .task(id: "\(indexer.revision)#\(showHidden)") { reload() }
    }

    private func cell(_ person: PersonSummary) -> some View {
        VStack(spacing: 6) {
            FaceThumbnail(assetID: person.faceAssetID, box: person.faceBox, size: 88)
                .opacity(person.isHidden ? 0.45 : 1)
            Text(person.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(person.name == nil ? .secondary : .primary)
                .lineLimit(1)
            Text("사진 \(person.photoCount.formatted())장")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func menu(_ person: PersonSummary) -> some View {
        Button("이름 지정", systemImage: "pencil") { renaming = person }
        Button("다른 사람과 합치기", systemImage: "person.2") { merging = person }
        Button(person.isHidden ? "숨김 해제" : "숨기기", systemImage: person.isHidden ? "eye" : "eye.slash") {
            Task { await indexer.setHidden(person.id, !person.isHidden) }
        }
    }

    private func reload() {
        guard let container = indexer.container else { return }
        people = PeopleQuery.people(in: container, includeHidden: showHidden)
    }
}

/// 한 사람이 나온 사진. 고르면 "이 사람 아님"으로 뺄 수 있고, 앨범으로 만들 수 있다.
struct PersonDetailView: View {
    let personID: UUID
    @Environment(\.modelContext) private var albums
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var indexer = PeopleIndexer.shared
    @State private var person: PersonSummary?
    @State private var faces: [FaceSummary] = []
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var viewing: String?
    @State private var renaming: PersonSummary?
    @State private var naming = false
    @State private var merging: PersonSummary?
    @State private var notice: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            if let person {
                header(person)
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(person.assetIDs, id: \.self) { cell($0) }
                }
            }
        }
        .navigationTitle(person?.displayName ?? "인물")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if selecting, !selected.isEmpty {
                Button(role: .destructive) { excludeSelected() } label: {
                    Text("이 사람 아님 (\(selected.count)장)").font(.headline).frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier("person-not-this")
            }
        }
        .fullScreenCover(item: Binding(get: { viewing.map(ViewingID.init) }, set: { viewing = $0?.id })) { item in
            OrganizePhotoViewer(items: person?.assetIDs ?? [], albumNames: [:], selected: .constant([]), currentID: item.id)
        }
        .sheet(item: $merging) { MergePeopleSheet(source: $0) }
        .modifier(RenamePersonAlert(person: $renaming))
        .modifier(RenamePersonAlert(person: Binding(get: { naming ? person : nil }, set: { if $0 == nil { naming = false } }),
                                    then: { name in makeAlbum(named: name) }))
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인", role: .cancel) {}
        }
        .task(id: indexer.revision) { reload() }
    }

    private struct ViewingID: Identifiable { let id: String }

    private func header(_ person: PersonSummary) -> some View {
        VStack(spacing: 8) {
            FaceThumbnail(assetID: person.faceAssetID, box: person.faceBox, size: 96)
            Text("사진 \(person.photoCount.formatted())장")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if person.isHidden {
                Label("숨긴 사람", systemImage: "eye.slash").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func cell(_ id: String) -> some View {
        let isOn = selected.contains(id)
        return Button {
            if selecting {
                if isOn { selected.remove(id) } else { selected.insert(id) }
            } else {
                viewing = id
            }
        } label: {
            AssetImage(id: id, pixels: 320)
                .aspectRatio(1, contentMode: .fit)
                .overlay { if isOn { Color.white.opacity(0.28) } }
                .overlay(alignment: .bottomTrailing) {
                    if selecting {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isOn ? Color.accentColor : Color.clear)
                            .shadow(color: .black.opacity(0.35), radius: 2)
                            .padding(6)
                    }
                }
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .accessibilityLabel(Text("\(person?.displayName ?? "") 사진"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("person-photo")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(selecting ? "완료" : "선택") {
                selecting.toggle()
                selected = []
            }
            .accessibilityIdentifier("person-select")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let person, !selecting {
                Menu {
                    Button("앨범으로 만들기", systemImage: "rectangle.stack.badge.plus") {
                        if let name = person.name { makeAlbum(named: name) } else { naming = true }
                    }
                    Button("이름 지정", systemImage: "pencil") { renaming = person }
                    Button("다른 사람과 합치기", systemImage: "person.2") { merging = person }
                    Button(person.isHidden ? "숨김 해제" : "숨기기", systemImage: person.isHidden ? "eye" : "eye.slash") {
                        Task { await indexer.setHidden(person.id, !person.isHidden) }
                    }
                } label: {
                    Label("더 보기", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("person-menu")
            }
        }
    }

    private func reload() {
        guard let container = indexer.container else { return }
        person = PeopleQuery.people(in: container, includeHidden: true, minimumPhotos: 0).first { $0.id == personID }
        faces = PeopleQuery.faces(of: personID, in: container)
        // 합쳐져 사라진 사람이면 목록으로 돌아간다.
        if person == nil { dismiss() }
    }

    private func excludeSelected() {
        let ids = Set(faces.filter { selected.contains($0.assetID) }.map(\.id))
        selected = []
        selecting = false
        Task { await indexer.exclude(faces: ids, from: personID) }
    }

    /// 이 사람의 사진으로 인물 앨범을 만든다. 같은 이름의 인물 앨범이 있으면 빠진 사진만 채운다.
    private func makeAlbum(named name: String) {
        guard let person else { return }
        let store = AlbumStore(context: albums)
        let existing = (try? albums.fetch(FetchDescriptor<Album>()))?.first { $0.kind == .person && $0.title == name }
        let album = existing ?? store.createAlbum(title: name, kind: .person)
        let dates = PhotoLibrary.creationDates(for: person.assetIDs)
        let added = store.add(person.assetIDs.map { (id: $0, takenAt: dates[$0]) }, to: album)
        Task { await PhotoMetadata.refresh(context: albums) }
        notice = existing == nil ? "‘\(name)’ 앨범을 만들었어요" : "‘\(name)’ 앨범에 사진 \(added.count)장을 채웠어요"
    }
}

/// 사람 이름 붙이기. `then`이 있으면 이름을 붙인 뒤 이어서 부른다(앨범 만들기).
struct RenamePersonAlert: ViewModifier {
    @Binding var person: PersonSummary?
    var then: ((String) -> Void)?
    @State private var text = ""

    func body(content: Content) -> some View {
        content.alert(then == nil ? "이름 지정" : "앨범 이름", isPresented: Binding(get: { person != nil }, set: { if !$0 { person = nil } })) {
            TextField("이름", text: $text)
            Button("취소", role: .cancel) { person = nil }
            Button(then == nil ? "저장" : "만들기") {
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = person?.id, !name.isEmpty {
                    Task {
                        await PeopleIndexer.shared.rename(id, to: name)
                        then?(name)
                    }
                }
                person = nil
            }
        } message: {
            Text(then == nil ? "이름을 붙이면 다시 묶어도 이 사람으로 남아요." : "이름을 붙이고 이 사람의 사진으로 앨범을 만들어요.")
        }
        .onChange(of: person?.id) { _, _ in text = person?.name ?? "" }
    }
}

/// 다른 사람과 합치기. 고른 사람 쪽으로 얼굴을 모두 옮긴다.
struct MergePeopleSheet: View {
    let source: PersonSummary
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var indexer = PeopleIndexer.shared
    @State private var people: [PersonSummary] = []
    @State private var target: PersonSummary?

    var body: some View {
        NavigationStack {
            List(people) { person in
                Button { target = person } label: {
                    HStack(spacing: 12) {
                        FaceThumbnail(assetID: person.faceAssetID, box: person.faceBox, size: 44)
                        VStack(alignment: .leading) {
                            Text(person.displayName).foregroundStyle(.primary)
                            Text("사진 \(person.photoCount.formatted())장").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("merge-target")
            }
            .navigationTitle("누구와 합칠까요?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
            .confirmationDialog("‘\(source.displayName)’을 ‘\(target?.displayName ?? "")’에 합칠까요?",
                                isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                                titleVisibility: .visible) {
                Button("합치기") {
                    if let target { Task { await indexer.merge(source.id, into: target.id); dismiss() } }
                }
            } message: {
                Text("두 사람의 사진이 한 사람으로 모여요.")
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            guard let container = indexer.container else { return }
            people = PeopleQuery.people(in: container, includeHidden: true).filter { $0.id != source.id }
        }
    }
}

/// 사진 접근이 "일부만 허용"이면 찾지 못한 사람이 있을 수 있음을 알리고 다시 고르게 한다.
struct LimitedAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("일부 사진만 허용되어 있어요. 허용한 사진에서만 사람을 찾아요.")
                .font(.footnote)
            Spacer(minLength: 0)
            Button("다시 고르기") {
                guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first
                else { return }
                var top = root
                while let next = top.presentedViewController { top = next }
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
            }
            .font(.footnote.weight(.semibold))
            .accessibilityIdentifier("people-reselect")
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
