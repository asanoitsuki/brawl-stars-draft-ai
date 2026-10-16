import CloudKit
import SwiftUI

/// チーム募集の掲示板。ブロスタ本体の「チームに招待 → 招待リンクを共有」で作ったリンクを貼って募集し、
/// 見た人は「参加」を押すとブロスタが開いてそのままチームに入れる。
/// 募集をタップすると、投稿者のプロフィール・フレンド申請・Discord・チャットが開く。
struct TeamBoardView: View {
    @StateObject private var board = TeamBoardStore()
    @ObservedObject private var profiles = ProfileStore.shared
    @EnvironmentObject private var rules: RulesStore
    @Environment(\.openURL) private var openURL
    @State private var modeFilter = ""
    @State private var purposeFilter: TeamPost.Purpose?
    @State private var showsComposer = false
    @State private var toast: String?
    @State private var reporting: TeamPost?
    @State private var opened: TeamPost?

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: HomeRoute.profile) {
                    ProfileAvatar(iconID: profiles.me.iconID, size: 30)
                }
                .accessibilityLabel("プロフィール")
            }
        }
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
        .sheet(item: $opened) { post in
            TeamPostDetailView(
                post: post,
                modeJa: modes.first { $0.key == post.mode }?.ja,
                isMine: board.isMine(post),
                onJoin: { join(post) }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
                    Text("下の「募集する」から、ブロスタの招待リンクを貼って募集できます")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 60)
            } else {
                // 光が外ににじむぶん、カードの間を少し広めに取る
                LazyVStack(spacing: 18) {
                    ForEach(filtered) { post in
                        TeamPostCard(
                            post: post,
                            modeJa: modes.first { $0.key == post.mode }?.ja,
                            isMine: board.isMine(post),
                            onOpen: { opened = post },
                            onJoin: { join(post) },
                            onClose: { Task { await board.closeMyPost(); show("募集を締め切りました") } },
                            onReport: { reporting = post },
                            onBlock: { board.block(post); show("この人の投稿を非表示にしました") }
                        )
                    }
                }
                .padding(.top, 6)
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

extension TeamPost.Purpose {
    var tint: Color {
        switch self {
        case .ranked: return .pink
        case .trophy: return .yellow
        case .casual: return .mint
        case .club: return .purple
        }
    }
}

private struct TeamPostCard: View {
    let post: TeamPost
    let modeJa: String?
    let isMine: Bool
    let onOpen: () -> Void
    let onJoin: () -> Void
    let onClose: () -> Void
    let onReport: () -> Void
    let onBlock: () -> Void

    private var tint: Color { post.purpose.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProfileAvatar(iconID: post.iconID, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.playerName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let trophies = post.trophies {
                        Label(trophies.formatted(), systemImage: "trophy.fill")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.yellow)
                    }
                }
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

            HStack(spacing: 6) {
                badge(post.purpose.label, color: tint)
                if let modeJa { badge(modeJa, color: .cyan) }
                if post.rank > 0 { badge(TeamPost.ranks[post.rank] + "帯", color: .orange) }
                if post.discordURL != nil { badge("Discord", color: Color(red: 0.45, green: 0.54, blue: 1)) }
            }

            if !post.comment.isEmpty {
                Text(post.comment)
                    .font(.callout)
                    .foregroundStyle(.white)
            }

            HStack {
                SlotsBadge(slots: post.slots, tint: tint)
                Spacer()
                Label("詳細・チャット", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
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
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture(perform: onOpen)
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

/// 「あと○人」の表示。あと1人はひと目で分かるよう塗りつぶしで強調する。
struct SlotsBadge: View {
    let slots: Int
    let tint: Color

    var body: some View {
        if slots == 1 {
            Label("あと1人！", systemImage: "flame.fill")
                .font(.footnote.weight(.heavy))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(.black)
                .background(
                    LinearGradient(colors: [.yellow, .orange], startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
        } else {
            Text("あと\(slots)人")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
        }
    }
}
