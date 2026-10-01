import PollyCore
import SwiftUI

/// Shows transcript turns (and optional live lines), auto-scrolling while live.
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    var liveText: [Speaker: String] = [:]
    var isLive = false
    var myName: String?

    private var turns: [TranscriptSegment] { TranscriptFormatter.turns(segments) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if turns.isEmpty && liveText.isEmpty {
                        Text(isLive ? "Listening… speech will appear here." : "This meeting has no transcript.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                    ForEach(turns) { turn in
                        TurnView(speaker: turn.speaker, label: label(turn.speaker), time: TranscriptFormatter.timestamp(turn.start), text: turn.text, isLive: false)
                    }
                    ForEach(Speaker.allCases, id: \.self) { speaker in
                        if let text = liveText[speaker], !text.isEmpty {
                            TurnView(speaker: speaker, label: label(speaker), time: "now", text: text, isLive: true)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
                .textSelection(.enabled)
            }
            .onChange(of: segments.count) { _, _ in
                if isLive { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: liveText) { _, _ in
                if isLive { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func label(_ speaker: Speaker) -> String {
        TranscriptFormatter.label(for: speaker, myName: myName)
    }
}

private struct TurnView: View {
    let speaker: Speaker
    let label: String
    let time: String
    let text: String
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(speaker == .me ? Color.accentColor : Color.orange)
                Text(time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(text)
                .foregroundStyle(isLive ? .secondary : .primary)
                .italic(isLive)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
