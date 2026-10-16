import SwiftUI

/// 募集をタップしたときの画面。投稿者のプロフィールと、
/// 「参加」「フレンド申請」「Discordで通話」、募集ごとの公開チャットをまとめて出す。
struct TeamPostDetailView: View {
    let post: TeamPost
    let modeJa: String?
    let isMine: Bool
    let onJoin: () -> Void

    @StateObject private var chat: TeamChatStore
    @ObservedObject private var me = ProfileStore.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var profile: PlayerProfile?
    @State private var profileLoaded = false
    @State private var draft = ""
    @State private var toast: String?
    @State private var reportingMessage: TeamMessage?
    /// 利用規約（不適切な投稿の禁止）への同意。初めて書き込む前に 1 回だけ確認する
    @AppStorage("teamAgreedRules") private var agreedRules = false
    @State private var asksAgreement = false
    /// 最初の読み込みでは一番下へ飛ばさない（プロフィールから読んでほしいので）。新着が来たときだけ追う。
    @State private var seenMessageCount: Int?
    @FocusState private var inputFocused: Bool

    private let chatTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    init(post: TeamPost, modeJa: String?, isMine: Bool, onJoin: @escaping () -> Void) {
        self.post = post
        self.modeJa = modeJa
        self.isMine = isMine
        self.onJoin = onJoin
        _chat = StateObject(wrappedValue: TeamChatStore(postRecordName: post.id.recordName))
    }

    private var discordURL: URL? {
        (post.discordURL ?? profile?.discordInvite).flatMap(TeamInvite.discordURL(from:)).flatMap(URL.init(string:))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SpaceBackdrop()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            profileCard
                            postCard
                            actions
                            chatSection
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chat.messages.count) { _, count in
                        defer { seenMessageCount = count }
                        guard let seen = seenMessageCount, count > seen else { return }
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle(post.playerName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .alert("チャットのルール", isPresented: $asksAgreement) {
                Button("同意して送信") { agreedRules = true }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("暴言・嫌がらせ・出会い目的・外部への誘導・個人情報の書き込みは禁止です。違反したメッセージは通報により非表示になり、投稿者は利用できなくなることがあります。利用規約に同意しますか？")
            }
            .confirmationDialog("このメッセージを通報しますか？", isPresented: Binding(
                get: { reportingMessage != nil }, set: { if !$0 { reportingMessage = nil } }
            ), titleVisibility: .visible) {
                ForEach(["暴言・嫌がらせ", "出会い・外部への誘導", "スパム・荒らし", "その他"], id: \.self) { reason in
                    Button(reason, role: .destructive) {
                        guard let m = reportingMessage else { return }
                        Task {
                            let ok = await chat.report(m, reason: reason)
                            chat.block(m)
                            show(ok ? "通報しました。この人のメッセージは今後表示されません" : "非表示にしました")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut, value: toast)
        .task {
            if let name = post.profileRecordName {
                profile = await ProfileStore.fetch(recordName: name, fallbackName: post.playerName)
            }
            profileLoaded = true
            await chat.refresh()
        }
        .onReceive(chatTimer) { _ in Task { await chat.refresh() } }
    }

    // MARK: - プロフィール

    @ViewBuilder
    private var profileCard: some View {
        Group {
            if let profile {
                ProfileSummary(profile: profile)
            } else if profileLoaded {
                HStack(spacing: 12) {
                    ProfileAvatar(iconID: post.iconID, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(post.playerName).font(.title3.weight(.heavy)).foregroundStyle(.white)
                        Text("プロフィール未設定").font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .glassCard(tint: .purple, cornerRadius: 22)
    }

    private var postCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                tag(post.purpose.label, color: post.purpose.tint)
                if let modeJa { tag(modeJa, color: .cyan) }
                if post.rank > 0 { tag(TeamPost.ranks[post.rank] + "帯", color: .orange) }
                Spacer()
                SlotsBadge(slots: post.slots, tint: post.purpose.tint)
            }
            if !post.comment.isEmpty {
                Text(post.comment).font(.callout).foregroundStyle(.white)
            }
            ConditionRow(post: post, unmet: isMine ? nil : post.unmetCondition(for: me.me))
            if let code = post.teamCode {
                Label("チームコード \(code)", systemImage: "number")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(14)
        .glassCard(tint: post.purpose.tint.opacity(0.7), cornerRadius: 20)
    }

    // MARK: - ボタン

    private var actions: some View {
        VStack(spacing: 10) {
            if !isMine, let unmet = post.unmetCondition(for: me.me) {
                Label(unmet, systemImage: "lock.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(.orange)
            } else if !isMine {
                Button {
                    onJoin()
                } label: {
                    Label("ブロスタで参加する", systemImage: "arrow.up.forward.app.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(post.purpose.tint, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
            HStack(spacing: 10) {
                actionButton("フレンド申請", icon: "person.badge.plus", color: .yellow,
                             enabled: profile?.friendLink != nil) {
                    if let s = profile?.friendLink, let url = URL(string: s) { openURL(url) }
                }
                actionButton("Discordで通話", icon: "headphones", color: Color(red: 0.45, green: 0.54, blue: 1),
                             enabled: discordURL != nil || profile?.discordName != nil) {
                    if let url = discordURL {
                        openURL(url)
                    } else if let name = profile?.discordName {
                        UIPasteboard.general.string = name
                        show("Discord のユーザー名（\(name)）をコピーしました")
                    }
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, color: Color, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(enabled ? color : .white.opacity(0.3))
                .background(Color.white.opacity(enabled ? 0.1 : 0.04), in: Capsule())
                .overlay(Capsule().strokeBorder(enabled ? color.opacity(0.6) : .clear))
        }
        .disabled(!enabled)
    }

    // MARK: - チャット

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("チャット", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("募集を見ている全員に公開").font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
            if let err = chat.errorText {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
            if chat.messages.isEmpty {
                Text("「入っていいですか？」など気軽にどうぞ")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            ForEach(chat.messages) { m in
                bubble(m)
            }
        }
    }

    private func bubble(_ m: TeamMessage) -> some View {
        let mine = chat.isMine(m)
        return HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 40) }
            if !mine { ProfileAvatar(iconID: m.senderIconID, size: 28) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !mine {
                    Text(m.senderName).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                }
                Text(m.text)
                    .font(.callout)
                    .foregroundStyle(mine ? .black : .white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(mine ? AnyShapeStyle(Color.mint) : AnyShapeStyle(Color.white.opacity(0.12)),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(m.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .contextMenu {
                if !mine {
                    Button("通報する", systemImage: "exclamationmark.bubble") { reportingMessage = m }
                    Button("この人を非表示", systemImage: "eye.slash") {
                        chat.block(m)
                        show("この人のメッセージを非表示にしました")
                    }
                }
                Button("コピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = m.text }
            }
            if !mine { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(Cloud.isEnabled ? "メッセージ" : "チャットは準備中です", text: $draft, axis: .vertical)
                .lineLimit(1...3)
                .focused($inputFocused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onChange(of: draft) { _, v in
                    if v.count > TeamMessage.maxLength { draft = String(v.prefix(TeamMessage.maxLength)) }
                }
            Button {
                guard agreedRules else { asksAgreement = true; return }
                let text = draft
                Task {
                    if let error = await chat.send(text, as: me.me) {
                        show(error)
                    } else {
                        draft = ""
                    }
                }
            } label: {
                Group {
                    if chat.sending { ProgressView().tint(.black) } else { Image(systemName: "arrow.up") }
                }
                .font(.headline)
                .frame(width: 40, height: 40)
                .background(Color.mint, in: Circle())
                .foregroundStyle(.black)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || chat.sending)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: -

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
    }
}
