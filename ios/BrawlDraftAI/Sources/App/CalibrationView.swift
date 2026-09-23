import PhotosUI
import SwiftUI

/// ドラフト画面のどこに何があるかを、実機のスクリーンショットに合わせて調整する画面。
///
/// スクリーンショットを選ぶと、まず自動検出（`AutoDetector`）が実測済みの既定位置を
/// 出発点に各枠をスナップさせる。手で一から置く必要はなく、ズレていたら微調整するだけ。
/// キャラ一覧グリッドは常に全キャラが表示されて調整対象にならないため、
/// 調整できるのは「自チーム 3 枠」「相手チーム 3 枠（相手が見える画面のときだけ）」
/// 「モード名の文字が書かれている領域」。
struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var profiles = LayoutStore.load()
    @State private var profileIndex = 0
    @State private var pickedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var selection: RegionRef = .ally(0)
    @State private var testSummary: String?
    @State private var saved = false
    @State private var autoDetecting = false
    @State private var autoDetectNote: String?

    enum RegionRef: Hashable {
        case modeText
        case ally(Int)
        case enemy(Int)

        var label: String {
            switch self {
            case .modeText: return "モード名の文字"
            case .ally(let i): return "味方 \(i + 1)"
            case .enemy(let i): return "相手 \(i + 1)"
            }
        }

        var color: Color {
            switch self {
            case .modeText: return .yellow
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
                        await runAutoDetect()
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

                    if autoDetecting {
                        ProgressView("自動検出中 …")
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    ContentUnavailableView(
                        "スクリーンショットを選んでください",
                        systemImage: "photo.badge.plus",
                        description: Text("ガチバトルのドラフト画面（味方 3 人・相手 3 人が並ぶ画面）を選ぶと、"
                                         + "自動でだいたいの位置に枠を合わせます。")
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxHeight: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func regionShape(_ ref: RegionRef, in frame: CGRect) -> some View {
        guard let n = rect(for: ref) else { return AnyView(EmptyView()) }
        let r = CGRect(x: frame.minX + n.x * frame.width,
                       y: frame.minY + n.y * frame.height,
                       width: n.w * frame.width,
                       height: n.h * frame.height)
        let isSelected = ref == selection
        let matchLabel = matchedName(for: ref)

        return AnyView(
            ZStack(alignment: .bottomTrailing) {
                Rectangle()
                    .strokeBorder(ref.color, lineWidth: isSelected ? 3 : 1.5)
                    .background(Rectangle().fill(ref.color.opacity(isSelected ? 0.18 : 0.06)))
                if let matchLabel {
                    Text(matchLabel)
                        .font(.caption2.bold())
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(ref.color.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                        .offset(y: -18)
                }
                if isSelected {
                    // ハンドルの見た目は小さいまま、タップ判定はもっと広く取る
                    // （実機での「感度が高すぎる／狙った所を掴めない」対策）。
                    Circle()
                        .fill(ref.color)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle().inset(by: -16))
                        .offset(x: 11, y: 11)
                        .gesture(resizeGesture(ref, frame: frame))
                }
            }
            .frame(width: max(r.width, 8), height: max(r.height, 8))
            .contentShape(Rectangle())
            .position(x: r.midX, y: r.midY)
            .onTapGesture { selection = ref }
            .gesture(moveGesture(ref, frame: frame))
        )
    }

    private func moveGesture(_ ref: RegionRef, frame: CGRect) -> some Gesture {
        // minimumDistance を大きめに取り、軽いタップが誤ってドラッグと判定されないようにする
        // （「感度が高すぎる」という報告への対応）。
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                selection = ref
                guard var n = rect(for: ref) else { return }
                n.x = clamp(n.x + value.translation.width / frame.width, max: 1 - n.w)
                n.y = clamp(n.y + value.translation.height / frame.height, max: 1 - n.h)
                setRect(n, for: ref)
            }
    }

    private func resizeGesture(_ ref: RegionRef, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard var n = rect(for: ref) else { return }
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
                nudge("←") { move(dx: -0.003) }
                nudge("→") { move(dx: 0.003) }
                nudge("↑") { move(dy: -0.003) }
                nudge("↓") { move(dy: 0.003) }
                nudge("－") { resize(-0.006) }
                nudge("＋") { resize(0.006) }
            }

            HStack {
                Button {
                    Task { await runAutoDetect() }
                } label: {
                    Label("この画像で自動検出しなおす", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(image == nil || autoDetecting)
            }

            HStack {
                Button {
                    runTest()
                } label: {
                    Label("この配置で解析テスト", systemImage: "play.circle")
                }
                .buttonStyle(.bordered)
                .disabled(image == nil)

                Button(role: .destructive) {
                    LayoutStore.resetToBundled()
                    profiles = LayoutStore.load()
                } label: {
                    Label("既定に戻す", systemImage: "arrow.uturn.backward")
                }
            }

            if let autoDetectNote {
                Text(autoDetectNote).font(.caption).foregroundStyle(.secondary)
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

    // MARK: - 自動検出

    /// 既定レイアウトを出発点に各枠をスナップさせる。ゼロから探すのではなく
    /// 「だいたい合っている状態」からの微調整なので、キャラ一覧グリッドに惑わされない。
    private func runAutoDetect() async {
        guard let cg = image?.cgImage else { return }
        autoDetecting = true
        defer { autoDetecting = false }
        do {
            let rules = try await RulesStore.shared.rules()
            let base = layout
            let result = await Task.detached(priority: .userInitiated) {
                AutoDetector.refine(image: cg, base: base, rules: rules)
            }.value

            var l = layout
            for (i, slot) in result.allySlots.enumerated() where i < l.allySlots.count {
                l.allySlots[i] = slot.rect
            }
            for (i, slot) in result.enemySlots.enumerated() where i < l.enemySlots.count {
                l.enemySlots[i] = slot.rect
            }
            layout = l

            let matched = (result.allySlots + result.enemySlots).compactMap(\.matchedName)
            autoDetectNote = matched.isEmpty
                ? "自動検出: 一致するキャラが見つかりませんでした（誰も選んでいない画面か、画角が違う可能性）。手で微調整してください。"
                : "自動検出: \(matched.joined(separator: "、")) を認識してスナップしました。ズレていたら微調整してください。"
        } catch {
            autoDetectNote = "自動検出に失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - ロジック

    private var allRegions: [RegionRef] {
        var refs: [RegionRef] = []
        if layout.modeTextRegion != nil { refs.append(.modeText) }
        refs += layout.allySlots.indices.map { .ally($0) }
        if layout.enemyVisible {
            refs += layout.enemySlots.indices.map { .enemy($0) }
        }
        return refs
    }

    private func rect(for ref: RegionRef) -> NRect? {
        switch ref {
        case .modeText: return layout.modeTextRegion
        case .ally(let i): return i < layout.allySlots.count ? layout.allySlots[i] : nil
        case .enemy(let i): return i < layout.enemySlots.count ? layout.enemySlots[i] : nil
        }
    }

    private func setRect(_ value: NRect, for ref: RegionRef) {
        var l = layout
        switch ref {
        case .modeText: l.modeTextRegion = value
        case .ally(let i) where i < l.allySlots.count: l.allySlots[i] = value
        case .enemy(let i) where i < l.enemySlots.count: l.enemySlots[i] = value
        default: break
        }
        layout = l
    }

    private func matchedName(for ref: RegionRef) -> String? {
        // 直近の自動検出結果は保持していないので、テスト実行結果から拾う
        // （シンプルさ優先。必要なら状態を追加で持たせる）。
        nil
    }

    private func move(dx: Double = 0, dy: Double = 0) {
        guard var n = rect(for: selection) else { return }
        n.x = clamp(n.x + dx, max: 1 - n.w)
        n.y = clamp(n.y + dy, max: 1 - n.h)
        setRect(n, for: selection)
    }

    private func resize(_ delta: Double) {
        guard var n = rect(for: selection) else { return }
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
