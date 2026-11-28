import SwiftUI

/// 인물 찾기를 처음 켤 때 보여 주는 동의 화면. 무엇을 분석하고 어디에 두는지 알리고 동의를 받는다.
struct PeopleConsentView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PeopleSettings.enabledKey) private var enabled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                    Text("사진 속 얼굴을 분석해 같은 사람을 찾을까요?")
                        .font(.title2.bold())
                    point("iphone", "기기 안에서만 분석해요", "얼굴 이미지와 얼굴 특징값은 이 iPhone에만 저장되고, 서버나 다른 곳으로 보내지 않아요.")
                    point("person.2", "같은 사람끼리 묶어요", "사진마다 얼굴을 찾아 특징값(숫자 128개)을 만들고, 비슷한 얼굴을 한 사람으로 묶어요. 이름은 직접 붙여요.")
                    point("battery.100.bolt", "조금씩, 충전 중에 이어서", "앱을 쓰는 동안 조금씩 하고, 남은 사진은 충전 중일 때 이어서 분석해요.")
                    point("trash", "언제든 끄고 지울 수 있어요", "인물 설정에서 끄면 저장된 얼굴 데이터를 모두 지워요.")
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        enabled = true
                        PeopleIndexer.shared.prepare()
                        PeopleIndexer.shared.start()
                        dismiss()
                    } label: {
                        Text("동의하고 켜기").font(.headline).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("people-consent")
                    Button("나중에") { dismiss() }
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .background(.bar)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기", systemImage: "xmark") { dismiss() } } }
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 인물 설정: 켜고 끄기(끄면 얼굴 데이터 삭제), iCloud 사진 내려받기, 오픈소스 고지.
struct PeopleSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PeopleSettings.enabledKey) private var enabled = false
    @AppStorage(PeopleSettings.iCloudOnWiFiKey) private var downloadsOnWiFi = false
    @ObservedObject private var indexer = PeopleIndexer.shared
    @State private var confirmOff = false
    @State private var consent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("인물 찾기", isOn: Binding(get: { enabled }, set: { on in
                        if on { consent = true } else { confirmOff = true }
                    }))
                    .accessibilityIdentifier("people-toggle")
                } footer: {
                    Text("얼굴 분석은 이 iPhone 안에서만 해요. 끄면 저장된 얼굴 데이터를 모두 지워요.")
                }
                if enabled {
                    Section {
                        Toggle("Wi‑Fi에서 iCloud 사진도 분석", isOn: $downloadsOnWiFi)
                    } footer: {
                        Text("iCloud에만 있는 사진은 Wi‑Fi에 연결되어 있을 때만 내려받아 분석해요. 끄면 기기에 있는 사진만 분석해요.")
                    }
                    if let progress = indexer.progress {
                        Section("진행") {
                            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                                Text("사진 \(progress.done.formatted())/\(progress.total.formatted())장 살펴봄")
                            }
                        }
                    }
                }
                Section("오픈소스") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("dlib face recognition model (dlib_face_recognition_resnet_model_v1)").font(.subheadline.weight(.medium))
                        Text("Davis E. King, dlib.net. 퍼블릭 도메인(CC0)으로 공개된 모델을 Core ML로 옮겨 기기 안에서 얼굴 특징값을 만드는 데 써요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Link("http://dlib.net/files/", destination: URL(string: "http://dlib.net/files/")!)
                            .font(.footnote)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle("인물 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .confirmationDialog("인물 찾기를 끌까요?", isPresented: $confirmOff, titleVisibility: .visible) {
                Button("끄고 얼굴 데이터 지우기", role: .destructive) {
                    enabled = false
                    indexer.deleteAll()
                }
            } message: {
                Text("찾은 사람, 붙인 이름, 얼굴 데이터가 모두 지워져요. 만들어 둔 인물 앨범은 그대로 남아요.")
            }
            .sheet(isPresented: $consent) { PeopleConsentView() }
        }
    }
}
