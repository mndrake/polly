# Polly

A native macOS app that transcribes your video calls on-device and writes
meeting notes with Claude. Works with **Zoom**, **Microsoft Teams**,
**Google Meet** (any browser), Webex, or anything else that plays audio.

- 🎙️ **Two-channel capture** – your microphone and the meeting app's audio are
  recorded separately, so the transcript knows what *you* said vs. *others*.
- 🔒 **On-device transcription** – Apple's SpeechAnalyzer (macOS 26) or
  SFSpeechRecognizer (macOS 14/15). Audio never leaves your Mac and is never
  written to disk.
- 👀 **Meeting detection** – notices Zoom/Teams/Meet meetings and offers to
  start transcribing (or starts automatically), and stops when the meeting
  window closes.
- 💬 **Live captions** – a small floating window stays on top of your call
  (even full-screen) with the latest lines and a green/yellow/grey status per
  side, so you can see both you and the others are being captured. It's hidden
  from screen sharing.
- 🗣️ **Who said what** – after the meeting, other participants' voices are
  separated on your Mac (Speaker 1, Speaker 2, …). Claude suggests who each one
  is from the conversation and the calendar invite, and you can confirm or
  rename them with one click. Notes and action items then name real people.
- 🧠 **Remembers voices** – once you've named someone, Polly recognizes their
  voice in later meetings (a fingerprint stored on your Mac, not a recording).
- 📅 **Google Calendar** – connect your Google account (or any calendar in macOS
  Calendar) so meetings get their real title and invitee list. See
  [docs/GOOGLE_CALENDAR.md](docs/GOOGLE_CALENDAR.md).
- ✨ **Claude summaries** – title, summary, key points, decisions, action items
  with owners, open questions — streamed live. Then ask follow-up questions
  ("What did I commit to?", "Draft a follow-up email").
- 📝 **Library & export** – every meeting is saved locally; copy or export as
  Markdown.

See [`docs/DESIGN.md`](docs/DESIGN.md) for the options considered and the architecture.

## Requirements

- macOS 14 Sonoma or later (macOS 26 Tahoe recommended for the best transcription)
- Xcode 16+ (Xcode 26 to build the SpeechAnalyzer engine)
- For summaries, either:
  - **[Claude Code](https://claude.com/claude-code)** signed in with your Claude
    plan (Pro, Max, Team or Enterprise). Usage counts toward your plan, with no
    API bill. This is the default.
  - or an [Anthropic API key](https://console.anthropic.com/settings/keys), billed per token.

## Download

Grab the latest `Polly-*-macOS.zip` from
[Releases](https://github.com/mndrake/polly/releases). Builds are ad-hoc
signed, so the first launch needs right-click → **Open**.

To publish a release, push a version tag (`git tag v0.2.0 && git push origin v0.2.0`) or run the **Release** workflow from the Actions tab with a version.

## Build & run

```bash
scripts/build-app.sh          # builds and ad-hoc signs build/Polly.app
open build/Polly.app
```

For development you can also `swift run Polly` (or open `Package.swift` in
Xcode). Notifications only work from the `.app` bundle.

To distribute, sign with your Developer ID and notarize:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" UNIVERSAL=1 scripts/build-app.sh
xcrun notarytool submit build/Polly.zip …   # after zipping with ditto
```

## First run

1. Install Claude Code and run `claude` once in Terminal to sign in with your
   Claude account. Polly finds it automatically (check **Settings → Claude**).
   Or switch Settings to **Anthropic API key** and paste a key (stored in the
   Keychain). Optionally set your name so your lines are labelled with it.
2. Click **Start Recording**. macOS will ask for:
   - **Microphone** – to transcribe you.
   - **Screen & System Audio Recording** – to capture the meeting app's audio
     and read window titles for meeting detection. Polly never records video.
     After granting it, quit and reopen Polly.
   - **Speech Recognition** (macOS 14/15 only).
3. Join a meeting. The floating captions window shows what's being heard on
   both channels as people talk. Click **Stop** — the notes are generated
   automatically. Once the meeting ends, Polly separates the other voices (a
   progress bar shows while it works), then writes the notes. Click a speaker
   chip above the transcript to confirm or change who it is.

> **Consent:** recording or transcribing people may require their consent
> where you live. Tell participants you are transcribing the call.

## How it works

| Piece | Implementation |
|---|---|
| Other participants' audio | ScreenCaptureKit audio capture filtered to the meeting app (Zoom, Teams, or the browser running Meet), with "all system audio" fallback |
| Your audio | AVAudioEngine microphone tap |
| Speech-to-text | `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+), `SFSpeechRecognizer` on-device fallback |
| Speaker separation | FluidAudio offline diarization (pyannote segmentation + WeSpeaker + VBx, Core ML, on device, macOS 15+) on the meeting-app channel after the call; voices are matched to transcript lines by time overlap |
| Speaker names | Your edits > voices recognized from earlier meetings (WeSpeaker embeddings, cosine match) > Claude's suggestions (a `speakers` JSON block returned with the notes), with invitees from Google Calendar (OAuth, read-only) or macOS Calendar (EventKit) |
| Transcript assembly | `TranscriptBuilder`: orders both channels, live partial lines, echo suppression |
| Meeting detection | Running apps + window titles + "mic in use" → `MeetingDetector` rules |
| Summaries & Q&A | Your Claude Code install in headless mode (`claude -p`, no tools, no project settings, nothing saved), or the Claude Messages API with an API key; `claude-opus-5-5` by default (Sonnet 5.5 / Haiku 4.5 selectable) |
| Storage | JSON per meeting in `~/Library/Application Support/Polly/Meetings` |

### Project layout

```
App/                    Info.plist + entitlements
Sources/PollyCore/      Platform-independent logic (unit-tested on Linux + macOS)
  Claude/               Messages API client, SSE parser, prompts
  Detection/            Meeting detection rules
  Models/               Meeting, transcript segment, platform
  Storage/              JSON store, Markdown export
  Transcript/           Transcript builder, formatter, timeline alignment
Sources/Polly/          The macOS app
  Audio/                ScreenCaptureKit + microphone capture, format conversion
  Transcription/        Speech engines and per-channel pipeline
  Detection/            System polling + notifications
  Services/             Recording session, settings, Keychain, permissions
  Views/                SwiftUI
Tests/PollyCoreTests/   Unit tests
scripts/build-app.sh    Builds and signs Polly.app
```

## Tests

```bash
swift test
```

`PollyCore` (Claude client, SSE parsing, detection rules, transcript assembly,
storage, export) builds and tests on Linux too; CI runs it there and builds
the full app on macOS.

## Troubleshooting

- **No "Others" transcript** – check Screen & System Audio Recording permission
  (then restart Polly). If the meeting runs somewhere unusual, set
  *Settings → Transcription → Other participants* to **All system audio**.
- **Your lines are duplicated as "Others"** – you're on speakers; keep
  *Remove speaker echo* on, or use headphones.
- **"On-device speech recognition isn't installed"** (macOS 14/15) – enable
  Dictation for that language in *System Settings → Keyboard*.
- **"Claude Code isn't signed in"** – run `claude` in Terminal and sign in with
  your Claude account.
- **"Claude Code isn't installed"** – install it, or set its path in
  *Settings → Claude* if it lives somewhere unusual.
- **401 from Anthropic** (API key mode) – re-enter the API key in Settings.
