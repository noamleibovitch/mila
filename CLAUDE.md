# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Mila is a native macOS app (Swift/SwiftUI, macOS 14+) that records, transcribes, and dictates audio locally using whisper.cpp with Metal GPU acceleration. Supports Hebrew (ivrit.ai large-v3) and English (OpenAI large-v3-turbo), optional speaker diarization via pyannote.audio, and Live AI mode via Claude API.

## Build & Development Commands

```bash
make bootstrap          # One-time: install xcodegen via Homebrew
make project            # Generate Mila.xcodeproj from project.yml
make build              # Debug build
make run                # Build + launch app
make test               # Run all unit tests (MilaTests + TranscriptionCoreTests)
make package-test       # Run TranscriptionCore package tests only
make e2e                # E2E transcription tests (requires ggml-tiny.bin)
make models             # Download both Whisper models (~4.6 GB)
make bundle-diarization # Build bundled Python runtime for diarization
make dmg                # Build release DMG
make clean              # Remove generated project + build artifacts
```

**Run a single test class or method** (xcodebuild):
```bash
xcodebuild test -project Mila.xcodeproj -scheme Mila -only-testing:MilaTests/SomeTestClass -derivedDataPath build -destination 'platform=macOS'
xcodebuild test -project Mila.xcodeproj -scheme Mila -only-testing:MilaTests/SomeTestClass/testMethodName -derivedDataPath build -destination 'platform=macOS'
```

**Requirements:** macOS 14+, Xcode 15.3+ (not just Command Line Tools), Homebrew. Apple Silicon strongly recommended.

## Architecture

- **Build system:** XcodeGen (`project.yml` is the source of truth, not the .xcodeproj). Never edit `.xcodeproj` directly.
- **Minimum deployment target:** macOS 14.0, Swift 5.10
- **Key dependencies:** TranscriptionCore (local Swift package wrapping whisper.cpp), Sparkle (auto-updates), Anthropic SDK (LLM features)
- **Swift concurrency:** `@MainActor` on UI-bound services (`TranscriptionService`, `RecordingStore`, `UpdaterViewModel`). Strict concurrency set to `minimal` in project.yml.
- **Project layout:**
  - `Mila/App/` — entry point (`MilaApp.swift`), `AppDelegate`, `UpdaterViewModel`
  - `Mila/Audio/` — mic recording (`MicrophoneRecorder`), system audio capture (`SystemAudioRecorder` via ScreenCaptureKit), `RecordingSession` (mixes both → mono 16 kHz WAV), live transcription, VAD
  - `Mila/Transcription/` — `TranscriptionService` (FIFO job queue), `ModelManager`, `RemoteWhisperEngine`, `SpeakerDiarizer` (Python subprocess), exporters
  - `Mila/Actions/` — LLM integration: `LLMRunner` (Claude API), `LiveAISession` (per-recording), `RecordingSummarizer`, `PostRecordingCoordinator`
  - `Mila/Dictation/` — global hotkeys (`HotkeyManager`, Carbon API), `DictationController` (mic → transcribe → paste)
  - `Mila/Models/` — data models and settings (`Recording`, `RecordingStore`, `DiarizationSettings`, etc.)
  - `Mila/Views/` — SwiftUI views (ContentView, SettingsView, SidebarView, LiveAIRecordingView, etc.)
  - `Mila/VoiceMemos/` — iPhone Voice Memos iCloud sync and import
  - `Mila/Resources/` — Info.plist, entitlements, bundled diarization models (~31 MB)
  - `MilaTests/` — unit tests (53 files)
  - `Packages/TranscriptionCore/` — cross-platform Swift package: WhisperEngine (whisper.cpp C bindings), SileroVAD, WAVReader, WER calculator, E2E test fixtures
  - `Packages/WhisperBinary/` — SPM wrapper for pre-built whisper.cpp xcframework (v1.8.4)
  - `scripts/` — release/build scripts (make-dmg.sh, build-diarization-bundle.sh, etc.)

### Data Flow
- **Recording:** `MicrophoneRecorder` + `SystemAudioRecorder` → `RecordingSession` → mono 16 kHz WAV file
- **Transcription:** WAV → `TranscriptionService` (FIFO queue, one job at a time) → `WhisperEngine` (local Metal GPU) or `RemoteWhisperEngine` (HTTP API) → `TranscriptSegment[]`
- **Diarization (optional):** WAV → `SpeakerDiarizer` (Python subprocess running pyannote.audio) → speaker labels merged into segments
- **Persistence:** `Recording` metadata → `recordings.json`; transcript → sidecar `.txt`; summary → sidecar `.summary.txt`
- **Live AI:** Streaming transcript chunks → `LiveAISession` → Claude API → summary + action items (throttled, min 20s between updates)

## Conventions

### Environment Objects
New app-wide settings (like `DiarizationSettings`) must be:
1. Instantiated in `MilaApp.init()` as a `@StateObject`
2. Injected via `.environmentObject()` on both the main window and the Settings scene
3. Accepted in tests via a custom `UserDefaults` suite (not `.standard`) to avoid polluting state

### Python Subprocess Integration
When calling Python ML pipelines from Swift via `Process`:
- Use inline Python scripts via `-c` argument (not bundled .py files) for the main pipeline -- this avoids path-resolution issues with app bundles
- Always separate stdout (JSON data) from stderr (diagnostic logs) -- pyannote and torch emit warnings to stderr that corrupt JSON parsing
- **Drain both pipes concurrently BEFORE `waitUntilExit()`** -- macOS pipe buffers are ~64 KB; if the subprocess fills a pipe before the parent reads, both sides deadlock. Use `Task.detached` to read pipes, then await after `waitUntilExit()`. See `.claude/rules/python-subprocess.md` for the correct pattern.
- Run Python processes on `Task.detached(priority: .userInitiated)` to avoid blocking the main actor
- Diarization models are bundled in the app (no HuggingFace token needed). The inline script receives the bundle models path as a CLI argument and loads the pipeline from a local config.yaml with `Pipeline.from_pretrained()`
- **Bundled model directory names must preserve the original HuggingFace model ID structure.** pyannote dispatches embedding backends via substring matching on the path (e.g., `"pyannote"` -> torch, `"wespeaker"` -> ONNX). See `.claude/rules/python-subprocess.md` for details.

### Python / PyTorch Compatibility Patches
The pyannote.audio + speechbrain stack requires two runtime monkey-patches (applied in the inline script):
1. **torch.load `weights_only` patch:** PyTorch >= 2.6 changed the default to `True`, breaking pyannote's checkpoint loading. Patch `torch.load` to force `weights_only=False`.
2. **speechbrain LazyModule patch:** pytorch_lightning stack inspection triggers speechbrain's lazy imports for optional packages (k2_fsa, nlp, huggingface.wordemb). Patch `LazyModule.ensure_module` to return a dummy module instead of raising `ImportError`.

These patches live in `SpeakerDiarizer.swift`'s inline diarize script. If upgrading pyannote.audio or speechbrain, check if these patches are still needed.

### Settings Persistence with UserDefaults
- Use namespaced keys: `"diarization.enabled"`, `"diarization.pythonPath"`, etc.
- For verification/setup state that should survive app restarts, persist a `verified` flag alongside the verified parameter values (path). On launch, restore only if current values match the persisted ones.
- Computed `status` properties must check `verificationStatus` before `lastVerifyResult` -- the persisted verified state should take precedence over nil in-memory verify results on launch.

### Tests
- `TranscriptionService` now requires a `diarizationSettings:` parameter. In tests, always pass `DiarizationSettings(defaults: .init(suiteName: "TestClassName.diarization")!)` to isolate from user defaults.
- Run tests with `make test` or via Xcode.

## Release Process
- **Release notes are REQUIRED, first.** Every release must add
  `RELEASE_NOTES/v<MARKETING_VERSION>.md` (Markdown, user-facing). This file
  becomes the Sparkle appcast `<description>` — i.e. the in-app "What's New"
  popup users see on update. Without it that popup is blank ("a new version is
  available" with no changelog). The signing pipeline runs
  `scripts/check-release-notes.sh <version>` **before building** and FAILS the
  release if the file is missing/empty/boilerplate, so this can't be skipped.
  Do NOT rely on the `project.yml` changelog comment or the GitHub Release body —
  neither feeds the appcast. See `RELEASE_NOTES/README.md`.
- Version is bumped only in `project.yml` (`MARKETING_VERSION` +
  `CURRENT_PROJECT_VERSION`). `Info.plist` inherits both via
  `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` — never hardcode
  literals there.
- Tags are `v`-prefixed: `v1.2.8`. `CURRENT_PROJECT_VERSION` (the build
  number) must increase monotonically — Sparkle keys updates on it.
- A local, unsigned DMG for testing: `make dmg` (ad-hoc signed; Gatekeeper
  shows the right-click → Open prompt on first launch).
- Notarized, signed release builds and Sparkle appcast publishing are produced
  by a separate, private signing pipeline maintained by the original authors;
  that toolchain is not part of this repository. Forks that want notarized
  builds should sign with their own Apple Developer ID and publish their own
  appcast (see `SUFeedURL` / `SUPublicEDKey` in `project.yml`).

## Contributing (PR Workflow)

- Branch from `main`. Run `make build && make test` before opening a PR.
- **Every bug-fix PR must link to a GitHub issue** (`Closes #N`). Create the issue first if needed. See `.claude/rules/pull-requests.md`.
- Upstream repo: `https://github.com/island-io/mila.git` — PRs go there.
- CI runs on `macos-26` runners; all checks must pass.
