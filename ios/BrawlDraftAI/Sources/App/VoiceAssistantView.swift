import SwiftUI

/// マイクに向かって状況を実況すると、その都度おすすめを声で返す対話モード。
/// スマホでブロスタ本体を操作しながら、この画面は別端末（iPadなど）で開いておく運用を想定。
/// 「このマップになった」「相手、二人はこれを選んだ」のように状況を伝えると、
/// 聞き取った内容の確認と次のおすすめを声で返す。「おすすめは?」「なんで?」のような
/// 質問にも答える。
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
            Text("この画面を開いている間だけ会話できます。スマホでブロスタを操作しながら、"
                 + "この画面は別端末で開いておく使い方を想定しています。")
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
                        description: Text("「このマップになった」「相手、二人はこれを選んだ」のように状況を教えるか、"
                                         + "「おすすめは?」「なんで?」と聞いてみてください。")
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
