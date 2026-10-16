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
struct ProfileSummary: View {
    let profile: PlayerProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ProfileAvatar(iconID: profile.iconID, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(.white)
                    HStack(spacing: 8) {
                        if !profile.tag.isEmpty {
                            Text(profile.tag).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.6))
                        }
                        if profile.rank > 0 {
                            Text(TeamPost.ranks[profile.rank])
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    if let club = profile.club {
                        Label(club, systemImage: "shield.lefthalf.filled")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                stat("トロフィー", profile.trophies, icon: "trophy.fill", color: .yellow)
                stat("最高", profile.highestTrophies, icon: "arrow.up.circle.fill", color: .orange)
                stat("3vs3勝利", profile.trioVictories, icon: "person.3.fill", color: .cyan)
            }

            if !profile.topBrawlers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("よく使うキャラ").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 10) {
                        ForEach(profile.topBrawlers.prefix(5)) { b in
                            VStack(spacing: 3) {
                                BrawlerIcon(id: b.id, size: 46)
                                if let t = b.trophies {
                                    Text("\(t)").font(.caption2.monospacedDigit()).foregroundStyle(.yellow)
                                }
                            }
                        }
                    }
                }
            }

            if !profile.bio.isEmpty {
                Text(profile.bio).font(.callout).foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private func stat(_ title: String, _ value: Int?, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(.caption2).foregroundStyle(color)
            Text(value.map { $0.formatted() } ?? "—")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 自分のプロフィール

/// ブロスタの「フレンド招待リンク」かタグを貼るだけで、公式のプロフィールを読み込んで作れる。
struct MyProfileView: View {
    @ObservedObject private var store = ProfileStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var draft = PlayerProfile()
    @State private var input = ""
    @State private var loading = false
    @State private var saving = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        ZStack {
            SpaceBackdrop()
            ScrollView {
                VStack(spacing: 16) {
                    if draft.isEmpty {
                        setupCard
                    } else {
                        ProfileSummary(profile: draft)
                            .padding(16)
                            .glassCard(tint: .purple, cornerRadius: 22)
                        reloadRow
                        extrasCard
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
        }
        .navigationTitle("プロフィール")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if !draft.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("保存") { Task { await save() } }
                            .disabled(draft == store.me)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { draft = store.me }
    }

    // MARK: 初回

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ブロスタと連携")
                .font(.title3.weight(.heavy))
                .foregroundStyle(.white)
            Text("ブロスタで自分のプロフィールを開き、右上の「フレンド招待」→「リンクをコピー」してから貼り付けてください。トロフィーやよく使うキャラが自動で入ります。")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
            PasteButton(payloadType: String.self) { strings in
                guard let first = strings.first else { return }
                input = first
                Task { await load() }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
            .tint(.purple)

            HStack {
                TextField("またはタグを入力（#2PP0Y8LQ）", text: $input)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                Button {
                    Task { await load() }
                } label: {
                    if loading { ProgressView() } else { Text("読み込む").font(.subheadline.weight(.bold)) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(input.isEmpty || loading)
            }
        }
        .padding(18)
        .glassCard(tint: .purple, cornerRadius: 22)
    }

    private var reloadRow: some View {
        HStack {
            if let at = draft.fetchedAt {
                Text("ブロスタから取得: \(at.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Button {
                input = draft.tag
                Task { await load() }
            } label: {
                Label(loading ? "更新中…" : "最新にする", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .disabled(loading)
            Button(role: .destructive) {
                draft = PlayerProfile()
                input = ""
            } label: {
                Label("連携し直す", systemImage: "link.badge.plus").font(.caption.weight(.semibold))
            }
        }
    }

    // MARK: 自分で足す部分

    private var extrasCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("見た人に表示されるもの").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))

            Picker("ガチバトルのランク帯", selection: $draft.rank) {
                ForEach(TeamPost.ranks.indices, id: \.self) { Text(TeamPost.ranks[$0]).tag($0) }
            }
            .tint(.orange)

            field("ひとこと（40文字まで）", text: $draft.bio, limit: 40, icon: "text.bubble")

            VStack(alignment: .leading, spacing: 6) {
                field("ブロスタのフレンド招待リンク", text: Binding(
                    get: { draft.friendLink ?? "" },
                    set: { draft.friendLink = ProfileLink.parse($0).friendLink ?? ($0.isEmpty ? nil : $0) }
                ), limit: 300, icon: "person.badge.plus")
                Text("募集を見た人が「フレンド申請」を押すと、ブロスタが開いてあなたに申請が届きます。")
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }

            field("Discord のユーザー名", text: Binding(
                get: { draft.discordName ?? "" },
                set: { draft.discordName = $0.isEmpty ? nil : $0 }
            ), limit: 40, icon: "at")
            VStack(alignment: .leading, spacing: 6) {
                field("Discord のサーバー招待リンク（任意）", text: Binding(
                    get: { draft.discordInvite ?? "" },
                    set: { draft.discordInvite = $0.isEmpty ? nil : $0 }
                ), limit: 200, icon: "headphones")
                Text("募集に自動で付きます。見た人は「Discordで通話」からそのまま入れます。")
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(16)
        .glassCard(tint: .white.opacity(0.4), cornerRadius: 22)
    }

    private func field(_ title: String, text: Binding<String>, limit: Int, icon: String) -> some View {
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

    private func load() async {
        let parsed = ProfileLink.parse(input)
        guard let tag = parsed.tag else {
            show("タグかフレンド招待リンクを貼ってください", error: true)
            return
        }
        loading = true
        defer { loading = false }
        var base = draft
        if let link = parsed.friendLink { base.friendLink = link }
        do {
            draft = try await ProfileAPI.lookup(tag: tag, into: base)
            show("\(draft.name) のプロフィールを読み込みました。「保存」で確定します", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func save() async {
        if TeamModeration.containsBlockedWord(draft.bio) {
            show("ひとことに使えない言葉が含まれています", error: true)
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await ProfileStore.shared.save(draft)
            show("保存しました", error: false)
        } catch {
            show("端末には保存しました。公開に失敗: \(TeamBoardStore.describe(error))", error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
