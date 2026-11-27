import CoreGraphics
import Foundation
import SwiftData

/// 사진에서 찾은 얼굴 하나. 임베딩과 상자는 기기 안에만 둔다.
@Model
final class Face {
    @Attribute(.unique) var id: UUID
    var assetLocalIdentifier: String
    /// 얼굴 상자. 사진 크기에 대한 비율(0~1), 왼쪽 위가 원점.
    var boxX: Double
    var boxY: Double
    var boxWidth: Double
    var boxHeight: Double
    /// 128차원 Float32 임베딩.
    var embedding: Data
    var quality: Float
    var person: Person?
    /// "이 사람 아님"으로 뺀 사람. 다시 묶을 때 이 사람에게는 붙지 않는다.
    var excludedPersonIDs: [UUID] = []
    var createdAt: Date

    init(assetLocalIdentifier: String, box: CGRect, embedding: [Float], quality: Float) {
        id = UUID()
        self.assetLocalIdentifier = assetLocalIdentifier
        boxX = box.minX
        boxY = box.minY
        boxWidth = box.width
        boxHeight = box.height
        self.embedding = FaceVector.data(embedding)
        self.quality = quality
        createdAt = .now
    }

    var box: CGRect { CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight) }
    var vector: [Float] { FaceVector.vector(embedding) }
}

/// 같은 사람으로 묶인 얼굴들.
@Model
final class Person {
    @Attribute(.unique) var id: UUID
    var name: String?
    @Relationship(deleteRule: .nullify, inverse: \Face.person) var faces: [Face] = []
    /// 목록에 보여 줄 얼굴. 품질이 가장 좋은 얼굴을 고른다.
    var representativeFaceID: UUID?
    var isHidden: Bool = false
    /// 사용자가 이름을 붙이거나 합쳐서 확정한 사람. 다시 묶을 때 이 사람의 얼굴은 고정점이 된다.
    var isConfirmed: Bool = false
    var createdAt: Date

    init(name: String? = nil) {
        id = UUID()
        self.name = name
        createdAt = .now
    }

    var representativeFace: Face? {
        faces.first { $0.id == representativeFaceID } ?? faces.max { $0.quality < $1.quality }
    }

    /// 이 사람이 나온 사진(중복 없이).
    var assetIDs: [String] {
        var seen = Set<String>()
        return faces.sorted { $0.createdAt < $1.createdAt }.compactMap { seen.insert($0.assetLocalIdentifier).inserted ? $0.assetLocalIdentifier : nil }
    }
}

/// 얼굴을 찾아 본 사진. 중단된 뒤 다시 시작할 때 이미 본 사진을 건너뛴다.
@Model
final class IndexedAsset {
    @Attribute(.unique) var assetLocalIdentifier: String
    var faceCount: Int
    var indexedAt: Date

    init(assetLocalIdentifier: String, faceCount: Int) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.faceCount = faceCount
        indexedAt = .now
    }
}

/// 얼굴 데이터 저장소. 앨범 저장소와 다른 파일이라 기능을 끄면 파일째 지운다.
enum FaceStoreContainer {
    static let models: [any PersistentModel.Type] = [Face.self, Person.self, IndexedAsset.self]

    static var url: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("people.store")
    }

    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = inMemory
            ? ModelConfiguration("people", isStoredInMemoryOnly: true)
            : ModelConfiguration("people", url: url)
        return try ModelContainer(for: Schema(models), configurations: configuration)
    }

    /// 저장된 얼굴·사람·기록을 모두 지운다. 파일과 곁다리 파일(-wal, -shm)까지.
    static func deleteFiles() {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}

/// 얼굴 저장소를 다루는 일. 백그라운드에서 돌도록 자기 컨텍스트를 가진다.
@ModelActor
actor FaceStore {
    // MARK: 기록

    func indexedAssetIDs() -> Set<String> {
        var descriptor = FetchDescriptor<IndexedAsset>()
        descriptor.propertiesToFetch = [\.assetLocalIdentifier]
        return Set(((try? modelContext.fetch(descriptor)) ?? []).map(\.assetLocalIdentifier))
    }

    /// 사진 한 장에서 찾은 얼굴을 넣는다. 얼굴이 없어도 "본 사진"으로 기록한다.
    /// 넣은 얼굴은 바로 가장 가까운 사람에게 붙인다(증분). 붙일 사람이 없으면 다음 재묶음까지 기다린다.
    @discardableResult
    func add(assetID: String, faces: [(box: CGRect, embedding: [Float], quality: Float)], clusterer: ChineseWhispersClusterer) -> Int {
        let centroids = personCentroids()
        var assigned = 0
        for item in faces {
            let face = Face(assetLocalIdentifier: assetID, box: item.box, embedding: item.embedding, quality: item.quality)
            modelContext.insert(face)
            if let id = clusterer.nearest(item.embedding, among: centroids), let person = person(id) {
                face.person = person
                assigned += 1
                centroidCache[id] = nil
            }
        }
        modelContext.insert(IndexedAsset(assetLocalIdentifier: assetID, faceCount: faces.count))
        return assigned
    }

    func save() {
        try? modelContext.save()
    }

    /// 보관함에서 사라진 사진의 얼굴과 기록을 지운다. 얼굴이 하나도 남지 않은 사람도 지운다.
    func remove(assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }
        let faces = (try? modelContext.fetch(FetchDescriptor<Face>())) ?? []
        for face in faces where assetIDs.contains(face.assetLocalIdentifier) { modelContext.delete(face) }
        let records = (try? modelContext.fetch(FetchDescriptor<IndexedAsset>())) ?? []
        for record in records where assetIDs.contains(record.assetLocalIdentifier) { modelContext.delete(record) }
        // 지운 얼굴이 사람의 faces에서 빠지는 것은 저장할 때라 먼저 저장한다.
        save()
        dropEmptyPeople()
        centroidCache = [:]
        save()
    }

    // MARK: 묶기

    /// 사람마다의 중심. 증분으로 붙일 때 쓴다.
    private var centroidCache: [UUID: [Float]] = [:]

    private func personCentroids() -> [(id: UUID, centroid: [Float])] {
        let people = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        return people.compactMap { person in
            if let cached = centroidCache[person.id] { return (person.id, cached) }
            guard !person.faces.isEmpty else { return nil }
            let centroid = FaceVector.mean(person.faces.map(\.vector))
            centroidCache[person.id] = centroid
            return (person.id, centroid)
        }
    }

    private func person(_ id: UUID) -> Person? {
        try? modelContext.fetch(FetchDescriptor<Person>(predicate: #Predicate { $0.id == id })).first
    }

    /// 사람에 아직 안 붙은 얼굴 수. 많이 쌓이면 다시 묶는다.
    func unassignedCount() -> Int {
        // 선택 관계를 nil과 비교하는 Predicate는 iOS 17에서 믿기 어려워 불러와서 센다.
        ((try? modelContext.fetch(FetchDescriptor<Face>())) ?? []).filter { $0.person == nil }.count
    }

    /// 모든 얼굴을 처음부터 다시 묶는다. 확정한 사람의 얼굴은 고정점으로 두고, 다른 묶음은 겹치는 얼굴이
    /// 가장 많은 기존 사람을 이어받아 이름·숨김을 지킨다. `minimumFaces`보다 작은 묶음은 사람으로 만들지 않는다.
    func recluster(using clusterer: ChineseWhispersClusterer, minimumFaces: Int = 2) {
        let faces = (try? modelContext.fetch(FetchDescriptor<Face>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        guard !faces.isEmpty else { return }
        let people = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []

        // 확정한 사람마다 고정 번호.
        let confirmed = people.filter(\.isConfirmed)
        let anchorLabel = Dictionary(uniqueKeysWithValues: confirmed.enumerated().map { ($1.id, $0) })
        var anchors: [Int: Int] = [:]
        var forbidden: [Int: Set<Int>] = [:]
        for (index, face) in faces.enumerated() {
            if let id = face.person?.id, let label = anchorLabel[id] { anchors[index] = label }
            let banned = Set(face.excludedPersonIDs.compactMap { anchorLabel[$0] })
            if !banned.isEmpty { forbidden[index] = banned }
        }

        let labels = clusterer.cluster(faces.map(\.vector), anchors: anchors, forbidden: forbidden)
        var groups: [Int: [Face]] = [:]
        for (face, label) in zip(faces, labels) { groups[label, default: []].append(face) }

        var used = Set<UUID>()
        for (label, members) in groups.sorted(by: { $0.key < $1.key }) {
            if label < confirmed.count {
                // 확정한 사람: 고정점에 새로 붙은 얼굴까지. 그 사람을 뺀 얼굴은 붙이지 않는다.
                let person = confirmed[label]
                for face in members where !face.excludedPersonIDs.contains(person.id) { face.person = person }
                used.insert(person.id)
                continue
            }
            guard members.count >= minimumFaces else {
                for face in members where !(face.person?.isConfirmed ?? false) { face.person = nil }
                continue
            }
            // 확정하지 않은 사람 가운데 이 묶음과 가장 많이 겹치는 사람을 이어받는다.
            var counts: [UUID: Int] = [:]
            for face in members { if let p = face.person, !p.isConfirmed, !used.contains(p.id) { counts[p.id, default: 0] += 1 } }
            let keep = counts.max { $0.value < $1.value }.flatMap { best in people.first { $0.id == best.key } }
            let person = keep ?? {
                let new = Person()
                modelContext.insert(new)
                return new
            }()
            used.insert(person.id)
            for face in members where !face.excludedPersonIDs.contains(person.id) { face.person = person }
        }
        dropEmptyPeople()
        refreshRepresentatives()
        centroidCache = [:]
        save()
    }

    private func dropEmptyPeople() {
        for person in (try? modelContext.fetch(FetchDescriptor<Person>())) ?? [] where person.faces.allSatisfy(\.isDeleted) {
            modelContext.delete(person)
        }
    }

    private func refreshRepresentatives() {
        for person in (try? modelContext.fetch(FetchDescriptor<Person>())) ?? [] {
            if !person.faces.contains(where: { $0.id == person.representativeFaceID }) {
                person.representativeFaceID = person.faces.max { $0.quality < $1.quality }?.id
            }
        }
    }

    // MARK: 사용자 보정

    func rename(_ personID: UUID, to name: String) {
        guard let person = person(personID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        person.name = trimmed.isEmpty ? nil : trimmed
        person.isConfirmed = true
        save()
    }

    /// `source`의 얼굴을 모두 `target`으로 옮기고 `source`를 지운다.
    func merge(_ sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID, let source = person(sourceID), let target = person(targetID) else { return }
        for face in source.faces {
            face.person = target
            face.excludedPersonIDs.removeAll { $0 == targetID }
        }
        if target.name == nil { target.name = source.name }
        target.isHidden = target.isHidden && source.isHidden
        target.isConfirmed = true
        modelContext.delete(source)
        centroidCache = [:]
        save()
    }

    /// "이 사람 아님": 얼굴을 사람에게서 떼고 다시는 그 사람에게 붙지 않게 한다.
    func exclude(faceIDs: Set<UUID>, from personID: UUID) {
        let faces = (try? modelContext.fetch(FetchDescriptor<Face>())) ?? []
        for face in faces where faceIDs.contains(face.id) && face.person?.id == personID {
            face.person = nil
            if !face.excludedPersonIDs.contains(personID) { face.excludedPersonIDs.append(personID) }
        }
        if let person = person(personID) {
            // 남은 얼굴이 이 사람이라는 것은 사용자가 확인한 셈이다.
            person.isConfirmed = true
            if person.faces.isEmpty { modelContext.delete(person) }
        }
        dropEmptyPeople()
        refreshRepresentatives()
        centroidCache = [:]
        save()
    }

    func setHidden(_ personID: UUID, _ hidden: Bool) {
        person(personID)?.isHidden = hidden
        save()
    }
}
