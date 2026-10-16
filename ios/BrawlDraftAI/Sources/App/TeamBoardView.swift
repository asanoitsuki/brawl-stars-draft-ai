import CloudKit
import SwiftUI

/// チーム募集の掲示板。ブロスタ本体の「チームに招待 → 招待リンクを共有」で作ったリンクを貼って募集し、
/// 見た人は「参加」を押すとブロスタが開いてそのままチームに入れる。
struct TeamBoardView: View {
    @StateObject private var board = TeamBoardStore()
    @EnvironmentObject private var rules: RulesStore
    @Environment(\.openURL) private var openURL
    @State private var modeFilter = ""
    @State private var purposeFilter: TeamPost.Purpose?
    @State private var showsComposer = false
    @State private var toast: String?
    @State private var reporting: TeamPost?

    private let refreshTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var modes: [(key: String, ja: String)] {
        guard let doc = rules.loaded?.document else { return [] }
        return doc.modes.map { ($0.key, $0.value.ja) }.sorted { $0.ja < $1.ja }
    }

    private var filtered: [TeamPost] {
        board.posts.filter {
            (modeFilter.isEmpty || $0.mode == modeFilter || $0.mode.isEmpty)
                && (purposeFilter == nil || $0.purpose == purposeFilter)
        }
    }

    var body: some View {
        ZStack {
            SpaceBackdrop()

            ScrollView {
                VStack(spacing: 12) {
                    filters
                    if let message = board.accountMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 100)
            }
            .refreshable { await board.refresh() }

            VStack {
                Spacer()
                composeButton
            }

            if let toast {
                VStack {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationTitle("チーム募集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task {
            await board.checkAccount()
            await board.refresh()
        }
        .onReceive(refreshTimer) { _ in Task { await board.refresh() } }
        .sheet(isPresented: $showsComposer) {
            TeamComposeView(board: board, modes: modes) { message in
                show(message)
            }
            .presentationDetents([.large])
        }
        .confirmationDialog("この投稿を通報しますか？", isPresented: Binding(
            get: { reporting != nil }, set: { if !$0 { reporting = nil } }
        ), titleVisibility: .visible) {
            ForEach(["暴言・嫌がらせ", "出会い・外部への誘導", "スパム・荒らし", "その他"], id: \.self) { reason in
                Button(reason, role: .destructive) {
                    guard let post = reporting else { return }
                    Task {
                        let ok = await board.report(post, reason: reason)
                        board.block(post)
                        show(ok ? "通報しました。この人の投稿は今後表示されません" : "通報を送れませんでした（非表示にはしました）")
                    }
                }
            }
        }
        .animation(.easeInOut, value: toast)
    }

    // MARK: -

    private var filters: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip("すべて", selected: purposeFilter == nil) { purposeFilter = nil }
                    ForEach(TeamPost.Purpose.allCases) { p in
                        chip(p.label, selected: purposeFilter == p) { purposeFilter = p }
                    }
                }
            }
            .scrollIndicators(.hidden)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip("全モード", selected: modeFilter.isEmpty) { modeFilter = "" }
                    ForEach(modes, id: \.key) { m in
                        chip(m.ja, selected: modeFilter == m.key) { modeFilter = m.key }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 4)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(selected ? .bold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(selected ? .black : .white.opacity(0.85))
                .background(selected ? Color.mint : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch board.loadState {
        case .idle, .loading:
            ProgressView().tint(.white).padding(.top, 60)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "icloud.slash").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                Text(message).font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                Button("もう一度読み込む") { Task { await board.refresh() } }
            }
            .padding(.top, 50)
        case .loaded:
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.3").font(.largeTitle).foregroundStyle(.white.opacity(0.4))
                    Text("いまは募集がありません").font(.headline).foregroundStyle(.white.opacity(0.8))
                    Text("右下の「募集する」から、ブロスタの招待リンクを貼って募集できます")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 60)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filtered) { post in
                        TeamPostCard(
                            post: post,
                            modeJa: modes.first { $0.key == post.mode }?.ja,
                            isMine: board.isMine(post),
                            onJoin: { join(post) },
                            onClose: { Task { await board.closeMyPost(); show("募集を締め切りました") } },
                            onReport: { reporting = post },
                            onBlock: { board.block(post); show("この人の投稿を非表示にしました") }
                        )
                    }
                }
            }
        }
    }

    private var composeButton: some View {
        Button {
            showsComposer = true
        } label: {
            Label(board.myPostID == nil ? "募集する" : "募集を出し直す", systemImage: "plus")
                .font(.headline)
                .padding(.horizontal, 22).padding(.vertical, 14)
                .foregroundStyle(.black)
                .background(Color.mint, in: Capsule())
                .shadow(color: .mint.opacity(0.6), radius: 16, y: 6)
        }
        .disabled(!board.canPost)
        .opacity(board.canPost ? 1 : 0.4)
        .padding(.bottom, 18)
    }

    private func join(_ post: TeamPost) {
        if let url = TeamInvite.joinURL(for: post) {
            if let code = post.teamCode { UIPasteboard.general.string = code }
            openURL(url)
        } else {
            show("この募集には参加リンクがありません")
        }
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
    }
}

// MARK: - 投稿カード

private struct TeamPostCard: View {
    let post: TeamPost
    let modeJa: String?
    let isMine: Bool
    let onJoin: () -> Void
    let onClose: () -> Void
    let onReport: () -> Void
    let onBlock: () -> Void

    private var tint: Color {
        switch post.purpose {
        case .ranked: return .pink
        case .trophy: return .yellow
        case .casual: return .mint
        case .club: return .purple
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                badge(post.purpose.label, color: tint)
                if let modeJa { badge(modeJa, color: .cyan) }
                if post.rank > 0 { badge(TeamPost.ranks[post.rank] + "帯", color: .orange) }
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(ago(post.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
                if !isMine {
                    Menu {
                        Button("通報する", systemImage: "exclamationmark.bubble", action: onReport)
                        Button("この人を非表示", systemImage: "eye.slash", action: onBlock)
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 28, height: 28)
                    }
                }
            }
            if !post.comment.isEmpty {
                Text(post.comment)
                    .font(.callout)
                    .foregroundStyle(.white)
            }
            HStack {
                Image(systemName: "person.fill").font(.caption).foregroundStyle(.white.opacity(0.5))
                Text(post.playerName).font(.footnote).foregroundStyle(.white.opacity(0.75))
                Text("あと\(post.slots)人").font(.footnote.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                if isMine {
                    Button("締め切る", action: onClose)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white)
                } else {
                    Button(action: onJoin) {
                        Label("参加", systemImage: "arrow.up.forward.app")
                            .font(.footnote.weight(.bold))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(tint, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
            }
        }
        .padding(14)
        .glassCard(tint: isMine ? .white : tint.opacity(0.7), cornerRadius: 20)
        .background { AuraGlow(post: post, tint: isMine ? .white : tint) }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func ago(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        return minutes < 1 ? "たった今" : "\(minutes)分前"
    }
}

// MARK: - 募集の作成

private struct TeamComposeView: View {
    @ObservedObject var board: TeamBoardStore
    let modes: [(key: String, ja: String)]
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("teamPlayerName") private var playerName = ""
    @AppStorage("teamAgreedRules") private var agreedRules = false
    @State private var purpose: TeamPost.Purpose = .ranked
    @State private var mode = ""
    @State private var rank = 0
    @State private var slots = 2
    @State private var comment = ""
    @State private var inviteText = ""
    @State private var sending = false
    @State private var errorText: String?

    private var parsed: (url: String?, code: String?) { TeamInvite.parse(inviteText) }

    private var problems: [String] {
        var out: [String] = []
        if playerName.trimmingCharacters(in: .whitespaces).isEmpty { out.append("名前を入れてください") }
        if parsed.url == nil && parsed.code == nil { out.append("招待リンクかチームコードを貼ってください") }
        if TeamModeration.containsBlockedWord(comment) || TeamModeration.containsBlockedWord(playerName) {
            out.append("使えない言葉が含まれています")
        }
        if !agreedRules { out.append("ルールに同意してください") }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { inviteText = first }
                    }
                    .labelStyle(.titleAndIcon)
                    TextField("招待リンク または チームコード", text: $inviteText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                    if let url = parsed.url {
                        Label(url, systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                    } else if let code = parsed.code {
                        Label("チームコード \(code)", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                    }
                } header: {
                    Text("招待リンク")
                } footer: {
                    Text("ブロスタでチームを作り「招待」→「リンクを共有」→「コピー」してから貼り付けてください。")
                }

                Section("募集内容") {
                    TextField("ゲーム内の名前", text: $playerName)
                        .onChange(of: playerName) { _, v in if v.count > 20 { playerName = String(v.prefix(20)) } }
                    Picker("目的", selection: $purpose) {
                        ForEach(TeamPost.Purpose.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("モード", selection: $mode) {
                        Text("指定なし").tag("")
                        ForEach(modes, id: \.key) { Text($0.ja).tag($0.key) }
                    }
                    Picker("ランク帯", selection: $rank) {
                        ForEach(TeamPost.ranks.indices, id: \.self) { Text(TeamPost.ranks[$0]).tag($0) }
                    }
                    Stepper("あと \(slots) 人", value: $slots, in: 1...2)
                    TextField("ひとこと（40文字まで）", text: $comment, axis: .vertical)
                        .onChange(of: comment) { _, v in if v.count > 40 { comment = String(v.prefix(40)) } }
                }

                Section {
                    Toggle(isOn: $agreedRules) {
                        Text("暴言・出会い目的・外部への誘導をしないことに同意します。違反した投稿は通報により非表示になります。")
                            .font(.caption)
                    }
                } footer: {
                    Text("募集は \(Int(TeamPost.lifetime / 60)) 分で自動的に消えます。投稿は iCloud を通じて全ユーザーに公開されます。")
                }

                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("募集する")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("投稿") { Task { await send() } }
                            .disabled(!problems.isEmpty)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let first = problems.first {
                    Text(first).font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                }
            }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let now = Date()
        let post = TeamPost(
            id: CKRecord.ID(recordName: UUID().uuidString),
            playerName: playerName.trimmingCharacters(in: .whitespacesAndNewlines),
            purpose: purpose, mode: mode, rank: rank, slots: slots,
            comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
            inviteURL: parsed.url, teamCode: parsed.code,
            createdAt: now, expiresAt: now.addingTimeInterval(TeamPost.lifetime),
            creatorID: nil
        )
        do {
            try await board.publish(post)
            onDone("募集を出しました")
            dismiss()
        } catch {
            errorText = TeamBoardStore.describe(error)
        }
    }
}

// MARK: - 投稿直後のオーラ

/// 投稿された直後に、カードの枠から光がにじみ出て、少しずつ静まっていく演出。
/// 「あと1人」の募集は埋まる寸前＝急ぎなので、光が強く・長く続き、静まったあとも淡く脈打つ。
private struct AuraGlow: View {
    let post: TeamPost
    let tint: Color

    /// 光が出ている秒数（投稿からの経過）。あと1人は長め。
    private var fadeSeconds: Double { post.slots == 1 ? 150 : 60 }
    private var peak: Double { post.slots == 1 ? 1.0 : 0.5 }

    var body: some View {
        let age = Date().timeIntervalSince(post.createdAt)
        // 光が完全に消えるのは、あと1人 以外だけ。あと1人は常に淡く残す。
        if age < fadeSeconds || post.slots == 1 {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                glow(at: context.date)
            }
            .allowsHitTesting(false)
        }
    }

    private func glow(at date: Date) -> some View {
        let age = max(0, date.timeIntervalSince(post.createdAt))
        let fresh = max(0, 1 - age / fadeSeconds)            // 1 → 0 に静まる
        let floor = post.slots == 1 ? 0.22 : 0.0              // あと1人の最低ライン
        let level = max(fresh * peak, floor)
        let speed = post.slots == 1 ? 3.2 : 2.0               // 脈打つ速さ
        let pulse = 0.78 + 0.22 * sin(date.timeIntervalSinceReferenceDate * speed)
        let strength = level * pulse
        let corner: CGFloat = 20

        return ZStack {
            // 外側のにじみ
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(tint, lineWidth: 3)
                .blur(radius: 6 + 10 * strength)
                .opacity(0.9 * strength)
            // 枠そのものの光
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(tint.opacity(0.95), lineWidth: 1.5)
                .opacity(strength)
        }
        .padding(-2)
        .shadow(color: tint.opacity(0.7 * strength), radius: 10 + 22 * strength)
    }
}
