import CloudKit
import SwiftUI

/// 募集の作成。プロフィールを作ってあれば名前・アイコン・トロフィー・Discord が自動で付く。
struct TeamComposeView: View {
    @ObservedObject var board: TeamBoardStore
    let modes: [(key: String, ja: String)]
    let onDone: (String) -> Void

    @ObservedObject private var profiles = ProfileStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("teamPlayerName") private var manualName = ""
    @AppStorage("teamAgreedRules") private var agreedRules = false
    @State private var purpose: TeamPost.Purpose = .ranked
    @State private var mode = ""
    @State private var rank = 0
    @State private var slots = 2
    @State private var comment = ""
    @State private var inviteText = ""
    @State private var discordText = ""
    @State private var sending = false
    @State private var errorText: String?

    private var profile: PlayerProfile { profiles.me }
    private var parsed: (url: String?, code: String?) { TeamInvite.parse(inviteText) }
    private var playerName: String {
        profile.isEmpty ? manualName.trimmingCharacters(in: .whitespacesAndNewlines) : profile.name
    }

    private var problems: [String] {
        var out: [String] = []
        if playerName.isEmpty { out.append("名前を入れるか、プロフィールを作ってください") }
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
                    if profile.isEmpty {
                        NavigationLink {
                            MyProfileView()
                        } label: {
                            HStack(spacing: 12) {
                                ProfileAvatar(iconID: nil, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("ブロスタと連携してプロフィールを作る").font(.subheadline.weight(.semibold))
                                    Text("トロフィーやよく使うキャラが募集に表示されます").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        TextField("ゲーム内の名前", text: $manualName)
                            .onChange(of: manualName) { _, v in if v.count > 20 { manualName = String(v.prefix(20)) } }
                    } else {
                        HStack(spacing: 12) {
                            ProfileAvatar(iconID: profile.iconID, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(.headline)
                                if let t = profile.trophies {
                                    Label(t.formatted(), systemImage: "trophy.fill").font(.caption).foregroundStyle(.yellow)
                                }
                            }
                            Spacer()
                            Text("このプロフィールで投稿").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
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
                    TextField("https://discord.gg/…（任意）", text: $discordText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.footnote)
                } header: {
                    Text("Discord で通話")
                } footer: {
                    Text("サーバーの招待リンクやボイスチャンネルのリンクを貼ると、見た人が「Discordで通話」からそのまま入れます。")
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
        if !profile.isEmpty {
            post.iconID = profile.iconID
            post.trophies = profile.trophies
            post.profileRecordName = await profiles.myProfileRecordName()
        }
        do {
            try await board.publish(post)
            onDone("募集を出しました")
            dismiss()
        } catch {
            errorText = TeamBoardStore.describe(error)
        }
    }
}
