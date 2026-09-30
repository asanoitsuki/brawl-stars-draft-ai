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
        ZStack {
            SpaceBackdrop()

            VStack(spacing: 0) {
                Text("この画面を開いている間だけ会話できます。スマホでブロスタを操作しながら、"
                     + "この画面は別端末で開いておく使い方を想定しています。")
                    .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, 8)

                ZStack {
                    AICoreOrb(energy: energy, accent: accent)
                        .frame(width: 300, height: 300)
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .offset(y: 150)
                }
                .frame(height: 240)
                .padding(.vertical, 12)

                if case .unavailable(let message) = assistant.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                if !assistant.liveTranscript.isEmpty {
                    Text(assistant.liveTranscript)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(assistant.turns.reversed()) { turn in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Q. \(turn.question)")
                                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
                                Text(turn.answer)
                                    .font(.callout).foregroundStyle(.white)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .glassCard(tint: .green.opacity(0.5))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                }
                .overlay {
                    if assistant.turns.isEmpty {
                        ContentUnavailableView(
                            "まだ会話がありません",
                            systemImage: "mic.circle",
                            description: Text("「このマップになった」「相手、二人はこれを選んだ」のように状況を教えるか、"
                                             + "「おすすめは?」「なんで?」と聞いてみてください。")
                        )
                        .foregroundStyle(.white.opacity(0.7))
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
                        .foregroundStyle(.white)
                }
                .background(
                    Capsule().fill(isActive ? Color.red.opacity(0.85) : Color.green.opacity(0.85))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .shadow(color: (isActive ? Color.red : Color.green).opacity(0.5), radius: 20, y: 8)
                .padding()
            }
        }
        .navigationTitle("対話モード")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    assistant.resetConversation()
                } label: {
                    Label("リセット", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { assistant.stop() }
        .animation(.default, value: assistant.liveTranscript)
        .animation(.easeInOut(duration: 0.4), value: assistant.state)
    }

    private var energy: Double {
        switch assistant.state {
        case .idle: return 0.12
        case .listening: return 0.55
        case .thinking: return 0.35
        case .speaking: return 0.85
        case .unavailable: return 0.08
        }
    }

    private var accent: Color {
        switch assistant.state {
        case .listening: return .cyan
        case .speaking: return .green
        case .thinking: return .yellow
        default: return .white.opacity(0.6)
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
