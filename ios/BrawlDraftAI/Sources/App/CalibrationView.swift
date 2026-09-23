import PhotosUI
import SwiftUI

/// ドラフト画面のどこに何があるかを、実機のスクリーンショットに合わせて調整する画面。
///
/// 既定値はあくまで目安なので、初回は必ずここで合わせる。
/// 枠を正確に置けるほど認識が安定し、ジッタ探索が要らなくなるぶん速くもなる。
struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var profiles = LayoutStore.load()
    @State private var profileIndex = 0
    @State private var pickedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var selection: RegionRef = .map
    @State private var testSummary: String?
    @State private var saved = false

    enum RegionRef: Hashable {
        case map
        case ban(Int)
        case ally(Int)
        case enemy(Int)

        var label: String {
            switch self {
            case .map: return "マップ画像"
            case .ban(let i): return "BAN \(i + 1)"
            case .ally(let i): return "味方 \(i + 1)"
            case .enemy(let i): return "相手 \(i + 1)"
            }
        }

        var color: Color {
            switch self {
            case .map: return .yellow
            case .ban: return .red
            case .ally: return .green
            case .enemy: return .blue
            }
        }
    }

    private var layout: ScreenLayout {
        get { profiles.profiles[min(profileIndex, profiles.profiles.count - 1)] }
        nonmutating set { profiles.profiles[min(profileIndex, profiles.profiles.count - 1)] = newValue }
    }

    var body: some View {
        VStack(spacing: 12) {
            picker
            canvas
            controls
        }
        .padding()
        .navigationTitle("枠合わせ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }.bold()
            }
        }
    }

    // MARK: - パーツ

    private var picker: some View {
        HStack {
            Picker("プロファイル", selection: $profileIndex) {
                ForEach(profiles.profiles.indices, id: \.self) { i in
                    Text(profiles.profiles[i].name).tag(i)
                }
            }
            .pickerStyle(.menu)

            Spacer()

            PhotosPicker(selection: $pickedItem, matching: .screenshots) {
                Label("スクショ", systemImage: "photo")
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        image = UIImage(data: data)
                        testSummary = nil
                    }
                }
            }
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    let frame = fitRect(imageSize: image.size, in: geo.size)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    ForEach(allRegions, id: \.self) { ref in
                        regionShape(ref, in: frame)
                    }
                } else {
                    ContentUnavailableView(
                        "スクリーンショットを選んでください",
                        systemImage: "photo.badge.plus",
                        description: Text("ガチバトルのドラフト画面を撮ったものを選ぶと、枠を重ねて調整できます。")
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxHeight: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func regionShape(_ ref: RegionRef, in frame: CGRect) -> some View {
        let n = rect(for: ref)
        let r = CGRect(x: frame.minX + n.x * frame.width,
                       y: frame.minY + n.y * frame.height,
                       width: n.w * frame.width,
                       height: n.h * frame.height)
        let isSelected = ref == selection

        return ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .strokeBorder(ref.color, lineWidth: isSelected ? 3 : 1.5)
                .background(Rectangle().fill(ref.color.opacity(isSelected ? 0.18 : 0.06)))
            if isSelected {
                Circle()
                    .fill(ref.color)
                    .frame(width: 18, height: 18)
                    .offset(x: 9, y: 9)
                    .gesture(resizeGesture(ref, frame: frame))
            }
        }
        .frame(width: max(r.width, 8), height: max(r.height, 8))
        .position(x: r.midX, y: r.midY)
        .onTapGesture { selection = ref }
        .gesture(moveGesture(ref, frame: frame))
    }

    private func moveGesture(_ ref: RegionRef, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard ref == selection else { return }
                var n = rect(for: ref)
                n.x = clamp(n.x + value.translation.width / frame.width, max: 1 - n.w)
                n.y = clamp(n.y + value.translation.height / frame.height, max: 1 - n.h)
                setRect(n, for: ref)
            }
            .simultaneously(with: TapGesture().onEnded { selection = ref })
    }

    private func resizeGesture(_ ref: RegionRef, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                var n = rect(for: ref)
                n.w = max(0.02, min(1 - n.x, n.w + value.translation.width / frame.width))
                n.h = max(0.02, min(1 - n.y, n.h + value.translation.height / frame.height))
                setRect(n, for: ref)
            }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("調整する枠", selection: $selection) {
                ForEach(allRegions, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)

            HStack {
                nudge("←") { move(dx: -0.002) }
                nudge("→") { move(dx: 0.002) }
                nudge("↑") { move(dy: -0.002) }
                nudge("↓") { move(dy: 0.002) }
                nudge("－") { resize(-0.004) }
                nudge("＋") { resize(0.004) }
            }

            HStack {
                Button {
                    runTest()
                } label: {
                    Label("この配置で解析テスト", systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(image == nil)

                Button(role: .destructive) {
                    LayoutStore.resetToBundled()
                    profiles = LayoutStore.load()
                } label: {
                    Label("既定に戻す", systemImage: "arrow.uturn.backward")
                }
            }

            if let testSummary {
                ScrollView {
                    Text(testSummary)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
            }
            if saved {
                Text("保存しました").font(.caption).foregroundStyle(.green)
            }
        }
    }

    private func nudge(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .frame(maxWidth: .infinity)
            .buttonStyle(.bordered)
    }

    // MARK: - ロジック

    private var allRegions: [RegionRef] {
        var refs: [RegionRef] = [.map]
        refs += layout.banSlots.indices.map { .ban($0) }
        refs += layout.allySlots.indices.map { .ally($0) }
        refs += layout.enemySlots.indices.map { .enemy($0) }
        return refs
    }

    private func rect(for ref: RegionRef) -> NRect {
        switch ref {
        case .map: return layout.mapPreview
        case .ban(let i): return layout.banSlots[i]
        case .ally(let i): return layout.allySlots[i]
        case .enemy(let i): return layout.enemySlots[i]
        }
    }

    private func setRect(_ value: NRect, for ref: RegionRef) {
        var l = layout
        switch ref {
        case .map: l.mapPreview = value
        case .ban(let i): l.banSlots[i] = value
        case .ally(let i): l.allySlots[i] = value
        case .enemy(let i): l.enemySlots[i] = value
        }
        layout = l
    }

    private func move(dx: Double = 0, dy: Double = 0) {
        var n = rect(for: selection)
        n.x = clamp(n.x + dx, max: 1 - n.w)
        n.y = clamp(n.y + dy, max: 1 - n.h)
        setRect(n, for: selection)
    }

    private func resize(_ delta: Double) {
        var n = rect(for: selection)
        n.w = max(0.02, min(1 - n.x, n.w + delta))
        n.h = max(0.02, min(1 - n.y, n.h + delta))
        setRect(n, for: selection)
    }

    private func clamp(_ value: Double, max upper: Double) -> Double {
        Swift.max(0, Swift.min(upper, value))
    }

    private func fitRect(imageSize: CGSize, in box: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func save() {
        do {
            try LayoutStore.save(profiles)
            saved = true
            Task { try? await Task.sleep(for: .seconds(2)); saved = false }
        } catch {
            testSummary = "保存に失敗: \(error.localizedDescription)"
        }
    }

    private func runTest() {
        guard let cg = image?.cgImage else { return }
        let current = layout
        Task {
            do {
                let rules = try await RulesStore.shared.rules()
                let snapshot = DraftAnalyzer.analyze(image: cg, rules: rules, layoutOverride: current)
                let recommendation = Recommender.make(from: snapshot, rules: rules)
                await MainActor.run {
                    testSummary = snapshot.diagnosticSummary + "\n→ " + recommendation.title
                }
            } catch {
                await MainActor.run { testSummary = error.localizedDescription }
            }
        }
    }
}
