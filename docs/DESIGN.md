# Polly — design notes

Polly is a native macOS app that transcribes video calls (Zoom, Microsoft Teams,
Google Meet, or anything else that plays audio) and produces meeting summaries
with Claude.

This document records the options that were explored, what was chosen and why,
and the resulting architecture.

---

## 1. Exploration

### 1.1 Getting the audio

The core problem: a meeting has two sides — **what you say** (microphone) and
**what everyone else says** (audio the meeting app plays). We need both, and
ideally we want to keep them separate so the transcript knows who is speaking.

| Option | How it works | Pros | Cons |
|---|---|---|---|
| **Join the call as a bot** (Recall.ai-style, Zoom/Teams SDKs) | A bot participant joins via each vendor's API | Speaker names from the platform | Three different integrations, bot shows up in the meeting, needs servers + vendor approval, Meet has no public bot API |
| **Virtual audio device** (BlackHole, Loopback) | User routes output through a loopback driver | Works on old macOS | Users must install a kernel/audio driver and re-route output; fragile; terrible UX |
| **Core Audio process taps** (`CATapDescription`, macOS 14.4+) | Tap the output of specific processes | No screen-recording permission, low level, low latency | Newer, C-heavy API, macOS 14.4+ only |
| **ScreenCaptureKit audio** (`SCStream.capturesAudio`, macOS 13+) | Capture audio of selected apps (filter by `SCRunningApplication`) | Per-app filter, first-party, well documented, same permission also lets us read window titles for meeting detection | Requires the Screen Recording permission |
| **Microphone** via `AVAudioEngine` | Standard input tap | Simple, universal | Picks up speaker output if the user isn't wearing headphones |

**Choice:** ScreenCaptureKit for the remote side (filtered to the meeting app, or
"all system audio" as a fallback) + `AVAudioEngine` for the microphone, as **two
independent channels**. This works identically for every meeting platform
(nothing vendor-specific in the audio path), needs no drivers and no bots, and
gives us free speaker separation: *Me* (mic) vs *Others* (meeting app).
The Screen Recording permission it needs is the same one we use for detection.
Core Audio taps are a good future swap-in (`SystemAudioCapture` is isolated
behind a small interface).

### 1.2 Speech-to-text

| Option | Where it runs | Notes |
|---|---|---|
| **`SpeechAnalyzer` / `SpeechTranscriber`** (macOS 26) | On device | Apple's new long-form engine: designed for meetings/lectures, no 1-minute limit, volatile + final results, audio time ranges, models managed by the OS (`AssetInventory`) |
| **`SFSpeechRecognizer`** (on-device mode) | On device | Available on macOS 14/15. Older engine meant for short utterances; needs request rotation for long audio |
| **WhisperKit / whisper.cpp** | On device | Very accurate, but ships 100 MB–1.5 GB models and burns GPU; extra dependency |
| **Cloud STT** (Deepgram, AssemblyAI, OpenAI) | Cloud | Diarization, high accuracy; but every second of every meeting leaves the machine, extra vendor + key, recurring cost |

**Choice:** a `SpeechTranscriptionEngine` protocol with two implementations:
`SpeechAnalyzer` on macOS 26+ (default), `SFSpeechRecognizer` on-device as the
fallback for macOS 14/15. Audio never leaves the Mac; only the *text* transcript
is sent to Claude, and only when the user asks for a summary (or enabled
auto-summarize). WhisperKit can be added later as a third engine.

### 1.3 Knowing that a meeting is happening

Signals available to a non-sandboxed app:

* `NSWorkspace.runningApplications` — is Zoom / Teams / a browser running?
* Window titles via `CGWindowListCopyWindowInfo` (needs Screen Recording,
  which we already have) — "Zoom Meeting", "Meet - abc-defg-hij",
  "Meeting with … | Microsoft Teams".
* Core Audio `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default
  input device — *some* app is using the microphone.

**Choice:** a pure, unit-tested rule engine (`MeetingDetector` in `PollyCore`)
that combines these into `DetectedMeeting(platform, bundleID, confidence)`.
Window-title matches are *high* confidence; "meeting app running + mic in use"
is *medium*. Polly suggests recording (menu bar + notification with a
**Start Transcribing** action) and can optionally auto-start. Recording always
remains an explicit, visible state (red menu bar icon) — consent to record is the
user's responsibility and the UI reminds them.

### 1.4 Summaries with Claude

* There is no official Anthropic Swift SDK, so Polly calls the Messages API over
  raw HTTPS (`URLSession`), streaming with Server-Sent Events so the summary
  appears as it is written.
* Default model **Claude Opus 5.5** (`claude-opus-5-5`), effort `medium`
  (set explicitly), with `fallbacks: "default"` (beta
  `server-side-fallback-2026-07-01`) so a safety-classifier decline is retried
  on Anthropic's recommended fallback model instead of failing. `stop_reason:
  "refusal"` is still handled. Sonnet 5.5 and Haiku 4.5 are selectable in
  Settings for cheaper/faster summaries.
* The transcript is placed first in the user turn with a `cache_control`
  breakpoint, so the summary request and every follow-up "Ask about this
  meeting" question reuse the cached transcript prefix.
* Follow-up questions are independent single requests (transcript + prior Q&A
  as text) — no thinking-block replay to manage.
* Output is Markdown with a fixed section layout (title, TL;DR, discussion,
  decisions, action items with owners, open questions). The H1 becomes the
  meeting title.
* The API key lives in the macOS Keychain.

### 1.5 App shape & build

* SwiftUI app with a **menu bar extra** (status, start/stop, detected meetings)
  and a **main window** (meeting library, live transcript, summary, Q&A),
  plus a Settings window.
* Built with **Swift Package Manager** — no `.xcodeproj` to maintain.
  `Info.plist` is embedded into the executable (`-sectcreate __TEXT __info_plist`)
  so even `swift run` gets proper permission prompts, and
  `scripts/build-app.sh` assembles and signs a real `Polly.app`.
* Platform-independent logic (Claude client, SSE parsing, transcript assembly,
  detection rules, storage, export) lives in **`PollyCore`**, which builds and is
  unit-tested on Linux CI as well as macOS.

---

## 2. Architecture

```
┌──────────────────────────── Polly.app (macOS) ────────────────────────────┐
│                                                                            │
│  MeetingMonitor ──(apps, window titles, mic-in-use)──▶ MeetingDetector*    │
│        │ DetectedMeeting                                                   │
│        ▼                                                                   │
│  AppModel (@MainActor) ──▶ RecordingSession                                │
│                              ├─ MicrophoneCapture (AVAudioEngine) ─┐       │
│                              │                                     ▼       │
│                              │                   ChannelPipeline "Me"      │
│                              │       resample ▸ TimelineAligner* ▸ engine  │
│                              ├─ SystemAudioCapture (ScreenCaptureKit) ┐    │
│                              │                                        ▼    │
│                              │                ChannelPipeline "Others"     │
│                              └─ TranscriptBuilder* ◀── TranscriptionUpdate │
│                                        │                                   │
│  MeetingStore* (JSON, App Support) ◀───┘                                   │
│  Summarizer ──▶ ClaudeClient* ──SSE──▶ api.anthropic.com/v1/messages       │
│  KeychainStore (API key)                                                   │
└────────────────────────────────────────────────────────────────────────────┘
                                        * = PollyCore (pure Swift, tested)
```

### Data flow for one meeting

1. User clicks **Start** (or accepts a detection prompt). `RecordingSession`
   asks for mic / screen-recording permission if needed.
2. Two capture sources start; each feeds its own `ChannelPipeline`:
   convert to the engine's preferred format → pad gaps with silence so the
   recognizer's clock stays aligned with wall-clock time → append to the engine.
3. Engines emit volatile (in-progress) and final results. `TranscriptBuilder`
   keeps finalized segments ordered by start time plus one live line per
   speaker, and drops "Me" segments that are just the mic hearing the
   speakers (echo suppression via token-overlap with nearby "Others" text).
4. The UI shows the live transcript. The meeting is autosaved periodically and
   on stop.
5. On stop (or on demand) `Summarizer` streams a summary from Claude into the
   meeting; the H1 becomes the title. Users can then ask follow-up questions,
   copy, or export Markdown.

### Privacy

* Audio is processed on device and never written to disk.
* Transcripts are stored locally in
  `~/Library/Application Support/Polly/Meetings/*.json`.
* Only transcript text is sent to Anthropic, only on summary/question requests.

---

## 3. Plan

1. `PollyCore`: models, transcript builder + formatter + echo suppression,
   timeline aligner, detection rules, SSE parser, Claude client & prompts,
   JSON store, Markdown export — with unit tests.
2. Audio capture: ScreenCaptureKit system audio, AVAudioEngine microphone,
   format conversion.
3. Transcription engines: SpeechAnalyzer (macOS 26) and SFSpeechRecognizer
   fallback behind one protocol.
4. Meeting monitor (apps + windows + mic) and notifications.
5. SwiftUI: app model, menu bar, library, live transcript, summary, Q&A,
   settings (API key in Keychain, model, language, behaviours).
6. Packaging: embedded Info.plist, entitlements, `build-app.sh`, README.
7. CI: build + test `PollyCore` on Linux, build the app on macOS.

### Future work

* Core Audio process taps instead of ScreenCaptureKit (drops the
  Screen Recording requirement on macOS 14.4+).
* Speaker diarization of the "Others" channel (e.g. pyannote/FluidAudio) and
  naming speakers from the platform's participant list.
* WhisperKit engine; per-meeting language auto-detect.
* Calendar integration (EventKit) for titles/attendees.
* Export to Notion / Google Docs / Slack.
