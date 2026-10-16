import PhotosUI
import SwiftUI

// MARK: - アイコン

/// ブロスタのプロフィールアイコン（ブロスタ風の黒フチ角丸）。読めなければ人型のマーク。
struct ProfileAvatar: View {
    let iconID: Int?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.25, blue: 0.95),
                                              Color(red: 0.25, green: 0.45, blue: 1)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let url = iconID.flatMap(PlayerProfile.iconURL(for:)) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(size * 0.06)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.black.opacity(0.85), lineWidth: max(1.5, size * 0.05))
        )
    }

    private var placeholder: some View {
        Image(systemName: "person.fill")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
    }
}

// MARK: - 表示用カード

/// プロフィールの中身（自分の画面と、募集をタップしたときの相手の画面で共通）。
/// 公式データで取れるもの（トロフィー・勝利数・レベル・育成状況・全キャラ）をすべて並べる。
struct ProfileSummary: View {
    let profile: PlayerProfile
    /// ルールデータの読み込みが終わったら分母（全ブロウラー数など）を出すため、変化を監視する
    @ObservedObject private var rulesStore = RulesStore.shared

    /// 全体の数（所持率の分母）。ルールデータから数える
    private var totals: (brawlers: Int, gadgets: Int, starPowers: Int)? {
        guard let rules = RulesStore.shared.loaded else { return nil }
        let list = rules.document.brawlers
        return (list.count, list.reduce(0) { $0 + $1.gadgets.count }, list.reduce(0) { $0 + $1.starPowers.count })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            trophyRow
            rankedRow
            basicData
            growthData
            brawlerGrid
            if let extra = profile.officialExtra, !extra.isEmpty { extraData(extra) }
            if !profile.bio.isEmpty {
                Text(profile.bio).font(.callout).foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    // MARK: 上段

    private var header: some View {
        HStack(spacing: 14) {
            ProfileAvatar(iconID: profile.iconID, size: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(profile.name)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                if !profile.tag.isEmpty {
                    Text(profile.tag).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.6))
                }
                if let club = profile.club {
                    Label(club, systemImage: "shield.lefthalf.filled")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var trophyRow: some View {
        HStack(spacing: 10) {
            statBox("現在のトロフィー") {
                if let t = profile.trophies { TrophyLabel(trophies: t, size: 16) } else { dash }
            }
            statBox("最多トロフィー") {
                if let t = profile.highestTrophies { TrophyLabel(trophies: t, size: 16) } else { dash }
            }
        }
    }

    @ViewBuilder
    private var rankedRow: some View {
        if profile.highestRank != nil || profile.rankedHighest != nil || profile.rankedCurrent != nil {
            HStack(spacing: 12) {
                if let r = profile.highestRank, r > 0 { RankBadge(tier: r, size: 40, showsLabel: false) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("ガチバトル").font(.caption.weight(.bold)).foregroundStyle(.pink)
                    HStack(spacing: 14) {
                        if let r = profile.highestRank, r > 0 {
                            Text("最高 \(RankTier.label(r))").font(.subheadline.weight(.heavy)).foregroundStyle(.white)
                        }
                        if let v = profile.rankedHighest {
                            Text("最高 \(v.formatted())").font(.subheadline.weight(.heavy).monospacedDigit()).foregroundStyle(.white)
                        }
                        if let v = profile.rankedCurrent {
                            Text("現在 \(v.formatted())").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.pink.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: 基本データ

    @ViewBuilder
    private var basicData: some View {
        let rows = basicRows()
        if !rows.isEmpty {
            section("基本データ") {
                if let level = profile.expLevel {
                    HStack(spacing: 8) {
                        Text("レベル").font(.caption).foregroundStyle(.white.opacity(0.65))
                        Text("\(level)").font(.headline.weight(.heavy).monospacedDigit()).foregroundStyle(.cyan)
                        if let xp = profile.expPoints {
                            Spacer()
                            Text("経験値 \(xp.formatted())").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                grid(rows)
            }
        }
    }

    private func basicRows() -> [(String, String, Color)] {
        var out: [(String, String, Color)] = []
        if let v = profile.trioVictories { out.append(("3vs3 勝利数", v.formatted(), .cyan)) }
        if let v = profile.soloVictories { out.append(("ソロ 勝利数", v.formatted(), .orange)) }
        if let v = profile.duoVictories { out.append(("デュオ 勝利数", v.formatted(), .mint)) }
        if let v = profile.bestRoboRumbleTime, v > 0 { out.append(("ロボットパニック最高", Self.time(v), .red)) }
        if let v = profile.bestTimeAsBigBrawler, v > 0 { out.append(("ビッグブロウラー最高", Self.time(v), .purple)) }
        return out
    }

    // MARK: 育成状況

    @ViewBuilder
    private var growthData: some View {
        if let g = profile.growth {
            section("育成状況") {
                let t = totals
                var rows: [(String, String, Color)] = [
                    ("ブロウラー", fraction(g.owned, t?.brawlers), .yellow),
                ]
                if let v = g.gadgets { rows.append(("ガジェット", fraction(v, t?.gadgets), .green)) }
                if let v = g.starPowers { rows.append(("スターパワー", fraction(v, t?.starPowers), .orange)) }
                if let v = g.gears { rows.append(("ギア", "\(v)", .gray)) }
                if let v = g.hyperCharges { rows.append(("ハイパーチャージ", "\(v)", .pink)) }
                if let v = g.buffies { rows.append(("バフィー", "\(v)", .purple)) }
                rows.append(("パワー11", "\(g.power11) / \(g.owned)", .blue))
                if let a = g.averagePower { rows.append(("平均パワー", String(format: "%.2f", a), .cyan)) }
                return grid(rows)
            }
        }
    }

    // MARK: 全キャラ

    @ViewBuilder
    private var brawlerGrid: some View {
        let list = (profile.brawlers ?? profile.topBrawlers).sorted { ($0.trophies ?? 0) > ($1.trophies ?? 0) }
        if !list.isEmpty {
            section(profile.brawlers == nil ? "よく使うキャラ" : "全キャラのトロフィー（\(list.count)体）") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(list) { b in
                        VStack(spacing: 2) {
                            BrawlerIcon(id: b.id, size: 46)
                            if let t = b.trophies { TrophyLabel(trophies: t, size: 10) }
                            if let p = b.power { Text("パワー\(p)").font(.system(size: 8)).foregroundStyle(.white.opacity(0.55)) }
                        }
                    }
                }
            }
        }
    }

    private func extraData(_ extra: [String: String]) -> some View {
        section("公式のその他の項目") {
            ForEach(extra.keys.sorted(), id: \.self) { key in
                HStack {
                    Text(key).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text(extra[key] ?? "").font(.caption.weight(.semibold)).foregroundStyle(.white)
                }
            }
        }
    }

    // MARK: 部品

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func grid(_ rows: [(String, String, Color)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(rows.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rows[i].0).font(.caption2).foregroundStyle(rows[i].2)
                    Text(rows[i].1).font(.subheadline.weight(.heavy).monospacedDigit()).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func fraction(_ owned: Int, _ total: Int?) -> String {
        total.map { "\(owned) / \($0)" } ?? "\(owned)"
    }

    static func time(_ seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60)分\(seconds % 60)秒" : "\(seconds)秒"
    }

    private var dash: some View {
        Text("—").font(.headline).foregroundStyle(.white.opacity(0.5))
    }

    private func statBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.6))
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 自分のプロフィール

/// プロフィールの作成・編集。
///
/// 作り方は 3 通り。どれでも読めたところまで自動で埋まり、最後に確認して保存する。
///   1. ブロスタの「フレンド招待リンク」を貼る（リンクにタグが入っているので、そこから公式データを取る）
///   2. ブロスタのプロフィール画面のスクショを選ぶ（端末内の文字認識でタグ・トロフィー・ランクを読む）
///   3. タグを入力する
struct MyProfileView: View {
    /// 保存が済んだら呼ばれる（チーム募集の最初の画面から開いたとき用）
    var onSaved: (() -> Void)? = nil

    @ObservedObject private var store = ProfileStore.shared

    @State private var draft = PlayerProfile()
    @State private var editing = false
    @State private var tagInput = ""
    @State private var screenshotItem: PhotosPickerItem?
    @State private var working: String?
    @State private var message: String?
    @State private var isError = false
    @State private var saving = false

    var body: some View {
        ZStack {
            SpaceBackdrop()
            ScrollView {
                VStack(spacing: 16) {
                    if editing {
                        ProfileSummary(profile: draft)
                            .padding(16)
                            .glassCard(tint: .purple, cornerRadius: 22)
                        editCard
                        saveButton
                        if store.me.isComplete {
                            ProfileShareButton(profile: store.me)
                        }
                        DeleteMyDataButton(onDeleted: { draft = PlayerProfile(); editing = false })
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    } else {
                        setupCard
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(isError ? .orange : .green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            if let working {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(working).font(.footnote).foregroundStyle(.white)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle("プロフィール")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if editing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("作り直す") {
                        editing = false
                        message = nil
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            draft = store.me
            editing = !store.me.isEmpty
        }
        .task {
            // 開くたびに、公式の最新の値へ更新（3 時間以内なら何もしない）
            await store.refreshFromOfficial()
            if editing, store.me.isComplete {
                // 編集中の自分で入れた欄は残して、公式の値だけ差し替える
                var merged = store.me
                merged.bio = draft.bio; merged.friendLink = draft.friendLink
                merged.discordName = draft.discordName; merged.discordInvite = draft.discordInvite
                draft = merged
            }
        }
        .onChange(of: screenshotItem) { _, item in
            guard let item else { return }
            Task { await readScreenshot(item) }
        }
    }

    // MARK: 最初の画面

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ブロスタと連携してプロフィールを作ろう")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                Text("下のどれか 1 つで、トロフィー・ランク・アイコンが自動で入ります。Brawl Insights で作ったプロフィール画像でも読み取れます。")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }

            // 1. フレンド招待リンク
            step(number: 1, title: "フレンド招待リンクを貼る", tint: .yellow,
                 detail: "ブロスタの「フレンド」→「フレンドを招待」→ リンクをコピーして、ここで貼り付け") {
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first else { return }
                    Task { await useLink(first) }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .tint(.yellow)
            }

            // 2. スクショ
            step(number: 2, title: "プロフィールのスクショ・画像を選ぶ", tint: .cyan,
                 detail: "ブロスタのプロフィール画面のスクショか、Brawl Insights のプロフィール画像を選ぶと文字を読み取ります") {
                PhotosPicker(selection: $screenshotItem, matching: .images) {
                    Label("スクショを選ぶ", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Color.cyan, in: Capsule())
                        .foregroundStyle(.black)
                }
            }

            // 3. タグ
            step(number: 3, title: "タグを入力", tint: .purple, detail: nil) {
                HStack {
                    TextField("#2PP0Y8LQ", text: $tagInput)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        // 日本語キーボードだと「2っ…」のように変換されてしまうので英数字に固定
                        .keyboardType(.asciiCapable)
                        .padding(10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    Button("読み込む") { Task { await useLink(tagInput) } }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(tagInput.count < 3)
                }
            }
        }
        .padding(18)
        .glassCard(tint: .purple, cornerRadius: 22)
    }

    private func step<Content: View>(number: Int, title: String, tint: Color, detail: String?,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .frame(width: 26, height: 26)
                .background(tint, in: Circle())
                .foregroundStyle(.black)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                content()
            }
        }
    }

    // MARK: 確認・編集

    /// ブロスタ公式の値は取得専用（上のプレビューに出ているものはここでは変えられない）。
    /// 自分で決めていいのは、ひとこと・フレンド招待リンク・Discord だけ。
    private var editCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("名前・トロフィー・ランクなどはブロスタ公式のデータで、自分では変更できません。",
                  systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))

            if draft.highestRank == nil && draft.rankedHighest == nil {
                Text("ガチバトルの最高ランクは、Brawl Insights のプロフィール画像かブロスタのスクショを読み込むと入ります。")
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }

            Divider().overlay(.white.opacity(0.1))
            Text("自分で入れるもの").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))

            textField("ひとこと（40文字まで）", text: $draft.bio, limit: 40, icon: "text.bubble")

            VStack(alignment: .leading, spacing: 6) {
                textField("フレンド招待リンク", text: Binding(
                    get: { draft.friendLink ?? "" },
                    set: { draft.friendLink = ProfileLink.parse($0).friendLink ?? ($0.isEmpty ? nil : $0) }
                ), limit: 300, icon: "person.badge.plus")
                Text("募集を見た人が「フレンド申請」を押すと、ブロスタが開いてあなたに申請が届きます。")
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }

            textField("Discord のユーザー名（任意）", text: Binding(
                get: { draft.discordName ?? "" },
                set: { draft.discordName = $0.isEmpty ? nil : $0 }
            ), limit: 40, icon: "at")
            textField("Discord のサーバー招待リンク（任意）", text: Binding(
                get: { draft.discordInvite ?? "" },
                set: { draft.discordInvite = $0.isEmpty ? nil : $0 }
            ), limit: 200, icon: "headphones")
        }
        .padding(16)
        .glassCard(tint: .white.opacity(0.4), cornerRadius: 22)
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            Group {
                if saving { ProgressView().tint(.black) } else { Text(draft.isComplete ? "この内容で保存" : "上の方法でプロフィールを読み込んでください") }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(draft.isComplete ? Color.mint : Color.white.opacity(0.15), in: Capsule())
            .foregroundStyle(draft.isComplete ? .black : .white.opacity(0.6))
        }
        .disabled(!draft.isComplete || saving)
    }

    private func textField(_ title: String, text: Binding<String>, limit: Int, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.purple).frame(width: 20)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: text.wrappedValue) { _, v in
                    if v.count > limit { text.wrappedValue = String(v.prefix(limit)) }
                }
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 処理

    /// フレンド招待リンク・タグのどちらでも受け付ける。
    private func useLink(_ text: String) async {
        let parsed = ProfileLink.parse(text)
        guard let tag = parsed.tag else {
            show("リンクかタグを読み取れませんでした。フレンド招待リンクをそのまま貼ってください", error: true)
            return
        }
        var base = draft
        base.tag = tag
        if let link = parsed.friendLink { base.friendLink = link }
        await fill(from: base, tag: tag)
    }

    private func readScreenshot(_ item: PhotosPickerItem) async {
        defer { screenshotItem = nil }
        working = "スクショを読み取り中…"
        defer { working = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            show("画像を読み込めませんでした", error: true)
            return
        }
        let r = (try? await ProfileScreenshotReader.read(image)) ?? .init()
        guard !r.isEmpty else {
            show("プロフィール画面の文字を読み取れませんでした。ブロスタのプロフィール画面のスクショか確認してください", error: true)
            return
        }
        var base = draft
        if let tag = r.tag { base.tag = tag }
        if let name = r.name, !name.isEmpty { base.name = name }
        if let t = r.trophies { base.trophies = t }
        if let t = r.highestTrophies { base.highestTrophies = t }
        if let rank = r.highestRank { base.highestRank = rank }
        if let club = r.club, !club.isEmpty { base.club = club }
        if let v = r.rankedHighest { base.rankedHighest = v }
        if let v = r.rankedCurrent { base.rankedCurrent = v }
        if let tag = r.tag {
            await fill(from: base, tag: tag, ocrFallback: true)
        } else {
            draft = base
            editing = true
            show("スクショから読み取りました。足りないところを入れてください", error: false)
        }
    }

    /// タグが分かったら公式データで埋める。サーバーが使えないときは読めた分だけで編集画面へ。
    private func fill(from base: PlayerProfile, tag: String, ocrFallback: Bool = false) async {
        working = "ブロスタのプロフィールを取得中…"
        defer { working = nil }
        do {
            var filled = try await ProfileAPI.lookup(tag: tag, into: base)
            // 公式 API に無い項目（最高ランク・ガチバトルのポイント）はスクショや手入力の値を残す
            filled.highestRank = base.highestRank
            filled.rankedHighest = base.rankedHighest
            filled.rankedCurrent = base.rankedCurrent
            draft = filled
            show("\(filled.name) のプロフィールを読み込みました。確認して保存してください", error: false)
        } catch {
            draft = base
            show(ocrFallback
                 ? "スクショから読み取りました（自動取得は使えませんでした: \(error.localizedDescription)）"
                 : "\(error.localizedDescription)。名前などを入れてください", error: !ocrFallback)
        }
        editing = true
    }

    private func save() async {
        if TeamModeration.containsBlockedWord(draft.bio) || TeamModeration.containsBlockedWord(draft.name) {
            show("使えない言葉が含まれています", error: true)
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await ProfileStore.shared.save(draft)
            show("保存しました", error: false)
            onSaved?()
        } catch {
            show("端末には保存しました。公開に失敗: \(TeamBoardStore.describe(error))", error: true)
            onSaved?()
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
