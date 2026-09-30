import SwiftUI

/// マイクに向かって自由に質問できる対話モード。
/// 「おすすめは?」「なんで?」「次点は?」「シェリーどう?」のように話しかけると声で返す。
struct VoiceAssistantView: View {
    @ObservedObject private var assistant = VoiceAssistant.shared

    private var isActive: Bool {
        switch assistant.state {
        case .idle, .unavailable: return false
        default: return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("このアプリの画面を開いている間だけ会話できます。ブロスタ本体に切り替えると自動で止まります。")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.top, 8)

            statusIndicator
                .padding(.vertical, 20)

            if case .unavailable(let message) = assistant.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal)
            }

            if !assistant.liveTranscript.isEmpty {
                Text(assistant.liveTranscript)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            List(assistant.turns.reversed()) { turn in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Q. \(turn.question)").font(.footnote).foregroundStyle(.secondary)
                    Text(turn.answer).font(.callout)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .overlay {
                if assistant.turns.isEmpty {
                    ContentUnavailableView(
                        "まだ会話がありません",
                        systemImage: "mic.circle",
                        description: Text("「おすすめは?」「なんで?」「ガジェットは?」のように話しかけてみてください。")
                    )
                }
            }

            Button {
                isActive ? assistant.stop() : assistant.start()
            } label: {
                Label(isActive ? "対話を終了" : "対話を始める",
                      systemImage: isActive ? "stop.fill" : "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(isActive ? .red : .accentColor)
            .padding()
        }
        .navigationTitle("対話モード")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { assistant.stop() }
        .animation(.default, value: assistant.liveTranscript)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 56))
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, isActive: assistant.state == .listening)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var iconName: String {
        switch assistant.state {
        case .idle: return "mic.slash.fill"
        case .listening: return "mic.fill"
        case .thinking: return "ellipsis.circle.fill"
        case .speaking: return "speaker.wave.2.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch assistant.state {
        case .idle: return .secondary
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .blue
        case .unavailable: return .red
        }
    }

    private var label: String {
        switch assistant.state {
        case .idle: return "「対話を始める」を押して話しかけてください"
        case .listening: return "聞いています…"
        case .thinking: return "考え中…"
        case .speaking: return "答えています…"
        case .unavailable: return "使用できません"
        }
    }
}
