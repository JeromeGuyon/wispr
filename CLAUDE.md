# Wispr

macOS menu bar app for on-device speech-to-text transcription. Audio never leaves the Mac.

## Quick Reference

- **Bundle ID**: `com.stormacq.mac.wispr` (GUI), `com.stormacq.mac.wispr-cli` (CLI)
- **Deployment target**: macOS 26.2, ARM64 only (Apple Silicon)
- **Swift 6** with strict concurrency (`SWIFT_APPROACHABLE_CONCURRENCY = YES`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)
- **Build system**: Xcode project (`wispr.xcodeproj`), not SPM workspace
- **Schemes**: `wispr` (GUI app), `wispr-cli` (CLI tool)

## Build & Test

```bash
# Build
xcodebuild -scheme wispr -configuration Debug build

# Test
xcodebuild -scheme wispr -configuration Debug test

# Archive & notarize (see Makefile targets)
make archive
make notarize
```

## Architecture

Four-layer structure under `wispr/`:

| Layer | Path | Purpose |
|-------|------|---------|
| Models | `wispr/Models/` | Value types: app state, model info, errors, permissions |
| Services | `wispr/Services/` | Actors & services: audio capture, ASR engines, hotkeys, settings |
| UI | `wispr/UI/` | SwiftUI views + AppKit integration (NSStatusItem, NSPanel) |
| Utilities | `wispr/Utilities/` | Logging, theming, SF Symbols, model paths |

### Key Types & Isolation

| Type | Isolation | Role |
|------|-----------|------|
| `StateManager` | `@MainActor @Observable` | Central orchestrator, state machine, hotkey callbacks |
| `AudioEngine` | `actor` | AVAudioEngine wrapper, real-time audio capture, level streaming |
| `WhisperService` | `actor` | WhisperKit integration, batch transcription |
| `ParakeetService` | `actor` | FluidAudio integration, streaming + EOU detection |
| `CompositeTranscriptionEngine` | `actor` | Routes to Whisper/Parakeet based on active model |
| `TextInsertionService` | `@MainActor` | Accessibility API insertion + clipboard fallback |
| `HotkeyMonitor` | `@MainActor @Observable` | Carbon hotkeys + CGEventTap for Fn key |
| `SettingsStore` | `@MainActor @Observable` | UserDefaults-backed persistent settings |
| `PermissionManager` | `@MainActor @Observable` | Mic + Accessibility permission polling |

### Protocols

- `TranscriptionEngine` — unified ASR interface (model management, batch & streaming transcription)
- `TextInserting` — text insertion abstraction (enables test fakes)
- `HTTPDataProvider` — abstracts URLSession for update checking

### Dual Engine Design

`CompositeTranscriptionEngine` aggregates `WhisperService` and `ParakeetService` behind `TranscriptionEngine`. Model ownership determines routing. Switching engines is transparent to callers.

### AppKit + SwiftUI Integration

- **Menu bar**: `NSStatusItem` + `NSMenu` (SwiftUI `MenuBarExtra` can't do dynamic icons)
- **Recording overlay**: `NSPanel` (non-activating, floats above all windows)
- **Settings/Onboarding**: SwiftUI views hosted in `NSWindow` + `NSHostingController`
- **App policy**: `.accessory` — menu bar only, no Dock icon

## Dependencies (SPM)

- **WhisperKit 0.17.0** — OpenAI Whisper via CoreML
- **FluidAudio 0.13.4** — NVIDIA Parakeet models
- **swift-argument-parser 1.7.1** — CLI argument parsing

## CLI Tool (`WisprCLI`)

Embedded in `Wispr.app/Contents/Resources/bin/WisprCLI`. Transcribes audio/video files offline.

Reads models from the GUI app's sandbox container, so both share one set of downloads:

```
~/Library/Containers/com.stormacq.mac.wispr/Data/Library/Application Support/wispr/models/
```

`ModelPaths.base` resolves this for both targets. The CLI is not sandboxed, so it targets the container path explicitly; `~/Library/Application Support/wispr/` is only a fallback for when the container does not exist and is not the shared location.

macOS protects that container as app-private data. Because the CLI is not the owning app, it needs Full Disk Access to read it, and the denial is asymmetric: `fileExists` (stat) succeeds while `contentsOfDirectory` (readdir) returns `EPERM`. `FileAccess` in `WisprCore` exists to keep that distinction from being swallowed — see `.kiro/specs/cli-model-access-errors/`.

## Concurrency Patterns

- **Actors** for all mutable shared state (audio buffers, ASR engines)
- **AsyncStream** via `makeStream()` pattern for audio levels and transcription results
- **Structured concurrency** only — no `Task.detached`, no GCD, no Combine
- Per-engine audio device routing via `AudioUnitSetProperty` (no global side effects)

## Privacy Guarantees

- Audio captured in-memory only (`[Float]` buffer), never written to disk
- Transcribed text inserted then discarded, never logged
- Clipboard restored within 2 seconds when fallback insertion used
- Network used only for model downloads (explicit user action) and update checks

## Feature Specs

Detailed designs live in `.kiro/specs/`:
- `hands-free-dictation/` — EOU-based auto-stop, push-to-talk vs hands-free toggle
- `fn-key-hotkey/` — Fn key as dictation trigger via CGEventTap
- `auto-suffix-insertion/` — configurable suffix + auto-send Enter
- `cli-tool/` — CLI architecture, audio decoding, shared model paths
- `per-engine-device-routing/` — per-AudioUnit device routing bugfix
- `app-store-check-list.md` — App Store submission validation

## Testing

- Uses **Swift Testing** framework (`#expect`, `@Test`), not XCTest
- 22 test files in `wisprTests/`
- Fakes/stubs preferred over mocking frameworks
- Tests cover: services, UI views, integration, accessibility, error recovery

## Live Meeting Features (JuL + Apple Intelligence)

On-device meeting intelligence layered on the existing meeting transcription.
**Opt-in: the whole section is off by default** (`SettingsStore.liveMeetingFeaturesEnabled`).

Two features share one mechanism — each finalized transcript sentence is sent,
non-blocking, to a local JuL server for typed classification (no token
generation):

- **Awareness** ("someone is talking about you"): wakes the user (notification +
  haptic + window flash) when a sentence names them and asks a question/task.
  Highlights: urgency, action-needed, deadline (Noul), tone (Score, 5 levels).
  Context brief: last N transcript lines (default) or an on-device AI summary.
- **Bullshit bingo**: a live 4×4 grid that fills as corporate buzzwords are heard.

Key types (all in `Services/`, `@MainActor`):

| Type | Role |
|------|------|
| `JulClient` | actor, HTTP client for the local JuL server (`/v1/classify`, `/health`) |
| `MeetingClassifier` | `@Observable`, hooked into `MeetingStateManager.record()`; classifies each sentence, drives awareness + bingo |
| `MeetingClassifierFeatures` | `AwarenessConfig`, `BingoConfig`, `ContextSummary` — the question sets and decision logic |
| `AwarenessSummarizer` | optional one-shot brief via `AppleIntelligence` |
| `AppleIntelligence` | shared wrapper over `SystemLanguageModel` (also used by `TextCorrectionService`) |

UI in `UI/Meeting/` (`BingoGridView`, `AwarenessHistoryView`, `FeaturePanel`)
and `UI/Components/LiveFeatureComponents`. Settings live in `SettingsView`'s
"Live Meeting Features" section (master toggle, install guide, context-mode
picker, collapsed Advanced for endpoint/API key).

**Privacy**: transcript text is never logged (only decision metadata). JuL runs
on `127.0.0.1` by default; the optional summary uses Apple's on-device model.
Nothing leaves the Mac. Requires a running JuL server (`jul serve`, see the
in-app install guide) and, for the AI summary, Apple Intelligence.
