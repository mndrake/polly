import PollyCore
import SwiftUI

/// Shows transcript turns (and optional live lines), auto-scrolling while live.
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    var liveText: [Speaker: String] = [:]
    var isLive = false
    var labels = SpeakerLabels(myName: nil)

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
                        TurnView(color: SpeakerColor.color(for: turn), label: labels.label(for: turn),
                                 time: TranscriptFormatter.timestamp(turn.start), text: turn.text, isLive: false)
                    }
                    ForEach(Speaker.allCases, id: \.self) { speaker in
                        if let text = liveText[speaker], !text.isEmpty {
                            TurnView(color: SpeakerColor.color(for: speaker, speakerID: nil),
                                     label: TranscriptFormatter.label(for: speaker, myName: labels.myName),
                                     time: "now", text: text, isLive: true)
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
}

/// A stable colour per voice: accent for the user, orange for unseparated
/// "Others", and a palette for separated speakers.
enum SpeakerColor {
    private static let palette: [Color] = [.orange, .purple, .teal, .pink, .green, .brown, .indigo, .mint]

    static func color(for segment: TranscriptSegment) -> Color {
        color(for: segment.speaker, speakerID: segment.speakerID)
    }

    static func color(for speaker: Speaker, speakerID: String?) -> Color {
        guard speaker == .others else { return .accentColor }
        guard let speakerID, let number = Int(speakerID.dropFirst()), number > 0 else { return .orange }
        return palette[(number - 1) % palette.count]
    }
}

private struct TurnView: View {
    let color: Color
    let label: String
    let time: String
    let text: String
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
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
