import SwiftUI

/// マイクに向かって状況を実況すると、その都度おすすめを声で返す対話モード。
/// スマホでブロスタ本体を操作しながら、この画面は別端末（iPadなど）で開いておく運用を想定。
///
/// 画面全体が GPU で描く宇宙（CosmosView）。球体は状態に合わせて
/// 「聞いている = 吸い込む / 考え中 = 分裂して浮く / 答える = 破裂して再生」と動く。
struct VoiceAssistantView: View {
    @ObservedObject private var assistant = VoiceAssistant.shared

    private var isActive: Bool {
        switch assistant.state {
        case .idle, .unavailable: return false
        default: return true
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CosmosView(mode: cosmosMode,
                           center: CGPoint(x: 0.5, y: 0.30),
                           radius: 0.19,
                           level: { VoiceAssistant.currentLevel })
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    statusChip
                        .padding(.top, 6)

                    // 球体のぶんの空き
                    Spacer(minLength: geo.size.height * 0.36)

                    transcript
                        .frame(minHeight: 44)
                        .padding(.horizontal, 24)

                    conversation
                        .frame(maxHeight: geo.size.height * 0.34)

                    micButton
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }
            }
        }
        .navigationTitle("対話モード")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    assistant.resetConversation()
                } label: {
                    Label("リセット", systemImage: "arrow.counterclockwise")
                }
                .tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { assistant.stop() }
        .animation(.easeInOut(duration: 0.25), value: assistant.liveTranscript)
        .animation(.easeInOut(duration: 0.4), value: assistant.state)
    }

    // MARK: - パーツ

    private var statusChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
                .shadow(color: accent, radius: 6)
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    @ViewBuilder
    private var transcript: some View {
        if case .unavailable(let message) = assistant.state {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        } else if !assistant.liveTranscript.isEmpty {
            Text(assistant.liveTranscript)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .shadow(color: .cyan.opacity(0.6), radius: 12)
                .transition(.opacity)
        } else if assistant.turns.isEmpty {
            Text(isActive
                 ? "例：「マップはハードロック鉱山。相手がガスを選んだ」"
                 : "状況を話しかけると、次のピックを答えます")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    private var conversation: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(assistant.turns.reversed().enumerated()), id: \.element.id) { index, turn in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.question)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                        Text(turn.answer)
                            .font(index == 0 ? .callout.weight(.medium) : .footnote)
                            .foregroundStyle(.white.opacity(index == 0 ? 1 : 0.7))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassCard(tint: index == 0 ? .cyan.opacity(0.55) : .white.opacity(0.15),
                               cornerRadius: 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .animation(.spring(duration: 0.4), value: assistant.turns.count)
    }

    private var micButton: some View {
        Button {
            isActive ? assistant.stop() : assistant.start()
        } label: {
            ZStack {
                Circle()
                    .fill(isActive ? Color.red.opacity(0.85) : Color.cyan.opacity(0.85))
                    .frame(width: 74, height: 74)
                    .shadow(color: (isActive ? Color.red : Color.cyan).opacity(0.7), radius: 22)
                Circle()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                    .frame(width: 74, height: 74)
                Image(systemName: isActive ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "対話を終了" : "対話を始める")
    }

    // MARK: - 状態ごとの見た目

    private var cosmosMode: CosmosMode {
        switch assistant.state {
        case .idle, .unavailable: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        }
    }

    private var accent: Color {
        switch assistant.state {
        case .listening: return .cyan
        case .speaking: return .mint
        case .thinking: return .purple
        case .unavailable: return .orange
        case .idle: return .white.opacity(0.6)
        }
    }

    private var label: String {
        switch assistant.state {
        case .idle: return "待機中"
        case .listening: return "聞いています"
        case .thinking: return "考え中"
        case .speaking: return "答えています"
        case .unavailable: return "使用できません"
        }
    }
}
