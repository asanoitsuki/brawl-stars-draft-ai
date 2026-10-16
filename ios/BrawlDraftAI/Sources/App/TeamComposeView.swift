import CloudKit
import SwiftUI

/// 募集の作成。プロフィールを作ってあれば名前・アイコン・トロフィー・Discord が自動で付く。
struct TeamComposeView: View {
    @ObservedObject var board: TeamBoardStore
    let modes: [(key: String, ja: String)]
    let onDone: (String) -> Void

    @ObservedObject private var profiles = ProfileStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("teamAgreedRules") private var agreedRules = false
    @State private var purpose: TeamPost.Purpose = .ranked
    @State private var mode = ""
    @State private var rank = 0
    @State private var slots = 2
    @State private var minTrophies = 0
    @State private var minRank = 0
    @State private var comment = ""
    @State private var inviteText = ""
    @State private var discordText = ""
    @State private var sending = false
    @State private var errorText: String?

    private var profile: PlayerProfile { profiles.me }
    private var parsed: (url: String?, code: String?) { TeamInvite.parse(inviteText) }
    private var playerName: String { profile.name }

    private var problems: [String] {
        var out: [String] = []
        if !profile.isComplete { out.append("先にプロフィールを完成させてください") }
        if parsed.url == nil && parsed.code == nil { out.append("招待リンクかチームコードを貼ってください") }
        if !discordText.isEmpty && TeamInvite.discordURL(from: discordText) == nil {
            out.append("Discord のリンクの形式が違います（https://discord.gg/…）")
        }
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
                    HStack(spacing: 12) {
                        ProfileAvatar(iconID: profile.iconID, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.headline)
                            HStack(spacing: 10) {
                                if let t = profile.trophies { TrophyLabel(trophies: t, size: 12) }
                                if let r = profile.highestRank, r > 0 { RankBadge(tier: r, size: 18) }
                            }
                        }
                        Spacer()
                        Text("このプロフィールで投稿").font(.caption2).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.black.opacity(0.35))
                } header: {
                    Text("投稿者")
                }

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
                    Text("ブロスタの招待リンク")
                } footer: {
                    Text("ブロスタでチームを作り「招待」→「リンクを共有」→「コピー」してから貼り付けてください。")
                }

                Section("募集内容") {
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
                    Picker("あと何人", selection: $slots) {
                        Text("あと1人（目立つ表示）").tag(1)
                        Text("あと2人").tag(2)
                    }
                    TextField("ひとこと（40文字まで）", text: $comment, axis: .vertical)
                        .onChange(of: comment) { _, v in if v.count > 40 { comment = String(v.prefix(40)) } }
                }

                Section {
                    Picker("最低トロフィー", selection: $minTrophies) {
                        Text("条件なし").tag(0)
                        ForEach(TeamPost.trophyThresholds, id: \.self) { Text("\($0.formatted()) 以上").tag($0) }
                    }
                    Picker("最低ランク（ガチバトル最高）", selection: $minRank) {
                        Text("条件なし").tag(0)
                        ForEach(1...RankTier.count, id: \.self) { Text("\(RankTier.label($0)) 以上").tag($0) }
                    }
                    if minRank > 0 {
                        HStack {
                            Spacer()
                            RankBadge(tier: minRank, size: 30)
                            Text("以上").font(.caption)
                            Spacer()
                        }
                    }
                } header: {
                    Text("参加条件")
                } footer: {
                    Text("条件を満たさない人には「条件外」と表示され、参加ボタンが押せなくなります。")
                }

                Section {
                    TextField("https://discord.gg/…（任意）", text: $discordText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.footnote)
                    HStack(spacing: 10) {
                        Button {
                            openURL(URL(string: "discord://")!) { accepted in
                                if !accepted { openURL(URL(string: "https://discord.com/app")!) }
                            }
                        } label: {
                            Label("Discord を開く", systemImage: "arrow.up.forward.app")
                        }
                        Button {
                            if let text = UIPasteboard.general.string,
                               let link = TeamInvite.discordURL(from: text) {
                                discordText = link
                            } else {
                                errorText = "コピーした Discord のリンクが見つかりません"
                            }
                        } label: {
                            Label("コピーしたリンクを貼る", systemImage: "doc.on.clipboard")
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                } header: {
                    Text("Discord で通話")
                } footer: {
                    Text("Discord でサーバーの招待リンクやボイスチャンネルのリンクをコピーして戻り、「コピーしたリンクを貼る」を押すと、見た人が募集カードからそのまま入れます。")
                }

                Section {
                    Toggle(isOn: $agreedRules) {
                        Text("暴言・出会い目的・外部への誘導をしないことに同意します。違反した投稿やチャットは通報により非表示になります。")
                            .font(.caption)
                    }
                } footer: {
                    Text("募集は \(Int(TeamPost.lifetime / 60)) 分で自動的に消えます。投稿とチャットは iCloud を通じて全ユーザーに公開されます。")
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
            .onAppear {
                rank = profile.rank
                if discordText.isEmpty, let invite = profile.discordInvite { discordText = invite }
            }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let now = Date()
        var post = TeamPost(
            id: CKRecord.ID(recordName: UUID().uuidString),
            playerName: playerName,
            purpose: purpose, mode: mode, rank: rank, slots: slots,
            comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
            inviteURL: parsed.url, teamCode: parsed.code,
            createdAt: now, expiresAt: now.addingTimeInterval(TeamPost.lifetime),
            creatorID: nil
        )
        post.discordURL = TeamInvite.discordURL(from: discordText)
        post.minTrophies = minTrophies > 0 ? minTrophies : nil
        post.minRank = minRank > 0 ? minRank : nil
        post.iconID = profile.iconID
        post.trophies = profile.trophies
        post.highestRank = profile.highestRank
        post.profileRecordName = await profiles.myProfileRecordName()
        do {
            try await board.publish(post)
            onDone("募集を出しました")
            dismiss()
        } catch {
            errorText = TeamBoardStore.describe(error)
        }
    }
}
