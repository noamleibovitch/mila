---
name: review
description: Pre-push code review that catches CodeRabbit/Copilot/maintainer issues before submitting. Run with /review before pushing. Loops fix→review until clean. Learned from 19 upstream PRs.
---

# Pre-Push Code Review

## Overview

Review all staged/unstaged changes against the project's code quality standards before pushing. Learned from 80+ CodeRabbit findings across 19 merged upstream PRs plus maintainer (Uri) review patterns.

## How to run

The user invokes `/review`. You then:

1. **Collect the diff** — run `git diff HEAD --` for tracked files, then enumerate `git ls-files --others --exclude-standard` and read each untracked file
2. **Review against ALL checklists below** — every item, no skipping
3. **Fix every issue found** — edit the files directly
4. **Re-review the fixes** — loop until zero issues
5. **Build and test** — run `make build` and `make test` to confirm compilation and behavior
6. **Report** — show a summary table: found | fixed | deferred
7. **Only then** tell the user it's ready to commit and push

## Review Checklist

### 1. Safety & Correctness (CRITICAL — these block merge)

- [ ] **No force-unwraps in production code**: Never `try!`, `as!`, or `!` force-unwrap outside tests — UNLESS it matches an established project convention (e.g. `try! fileManager.url(for: .applicationSupportDirectory)` is used by RecordingStore/DiarizationBootstrap).
- [ ] **No force-unwraps in tests**: Use `throws` on test methods + `try`, not `try!`. (PR #188, #95)
- [ ] **Error handling — use `do/catch`, not blanket `try?`**: `try?` silently swallows errors. Use `do { try ... } catch { log/handle }` unless the failure is genuinely ignorable. (CodeRabbit PR #198)
- [ ] **Weak self in escaping closures**: Any `Task { }`, completion handler, or `sink { }` that outlives the call must capture `[weak self]`. (PR #91)
- [ ] **Cancel/stop races**: If an async operation can outlive `stop()`, guard with an epoch counter or cancelled flag. (PR #143)
- [ ] **Task cancellation honored**: Long-running async operations must check `Task.isCancelled` periodically. (PR #95)
- [ ] **No transcription pipeline changes**: Never modify `SpeakerDiarizer.diarize()` return type or `TranscriptionService` flow.

### 2. Data Integrity (MAJOR — CodeRabbit flags these consistently)

- [ ] **Input validation at boundaries**: Reject empty strings, nil, zero/negative counts, empty arrays at public API entry points. (PR #95, #198)
- [ ] **Dimension safety**: Array index access on embeddings/centroids must guard equal dimensions. Never silently truncate. (PR #198)
- [ ] **Duplicate name/ID guards**: Before renaming speakers, folders, or profiles — check if target exists. (PR #198, #171)
- [ ] **No stale data leaks**: Only assign names/embeddings for speakers who actually spoke — check `diarizer.intervals`. (PR #198, #97)
- [ ] **Concurrent mutation safety**: Read-modify-write, don't clobber. (PR #154)
- [ ] **Preserve user edits across re-processing**: Re-transcription must carry forward speaker names. (PR #154)
- [ ] **isConfigured means ready**: Feature gates must check "enabled AND dependencies ready". (CLAUDE.md)
- [ ] **Handle Application Support creation**: Mila directory may not exist on clean install. (PR #187, #198)
- [ ] **Decoding fallback for new persisted fields**: New optional fields in Codable types must use `decodeIfPresent` with a sensible default so existing data still loads. (CodeRabbit PR #198)

### 3. Privacy & Security (Uri cares deeply about these)

- [ ] **Privacy logging**: No bare `print()` with user names or PII. Use `os.Logger` with `privacy: .private`. (PR #192, #198)
- [ ] **Biometric data opt-in**: Voice profiles must be gated on an explicit user toggle (OFF by default). (PR #97)
- [ ] **Delete path exists**: Any persistent user data must have individual + bulk deletion. (PR #97)
- [ ] **Excluded from diagnostics**: Sensitive data must NOT appear in `DiagnosticReporter`. (PR #97)
- [ ] **No secrets in examples**: API keys in docs must be obvious placeholders. (PR #105)
- [ ] **Security-scoped resources released**: Release bookmark access in `deinit`. (PR #164)

### 4. Swift Conventions (CodeRabbit auto-flags these)

- [ ] **`deinit` on every class**: Explicit `deinit {}` required (SwiftLint `required_deinit`). (PR #88, #198)
- [ ] **`@StateObject` construction**: Declare without inline default, assign via `_x = StateObject(wrappedValue:)` in `init()`. (PR #88, #133, #198)
- [ ] **`@MainActor` consistency**: Classes with `@Published` that drive UI must be `@MainActor`. (PR #95)
- [ ] **Sendable compliance**: All `@Published` types must be `Sendable`.
- [ ] **Heavy work off MainActor**: File I/O, subprocess calls — run on a non-main executor (not necessarily `Task.detached` — a plain `Task` from a nonisolated context or an actor-isolated method works too). (PR #115, CodeRabbit PR #198)

### 5. UI & Accessibility

- [ ] **Accessibility identifiers**: New interactive elements need `.accessibilityIdentifier()` for XCUITest. (PR #88, #198)
- [ ] **No stale @State**: State in navigable views — if critical, move to a store/ObservableObject.
- [ ] **SRT sidecar regeneration**: When mutating `segments[*].speaker` or `speakerNames`, call `TranscriptExporter.writeSRT`. (PR #198 Copilot)

### 6. Python Subprocess Integration

- [ ] **Pipe drain before waitUntilExit**: Both stdout and stderr read concurrently BEFORE `process.waitUntilExit()`. (CLAUDE.md)
- [ ] **Shared Python patches**: speechbrain LazyModule + torch.load patch in every inline script. (PR #198)
- [ ] **Null device for unread pipes**: `FileHandle.nullDevice`, not an unread `Pipe()`. (CLAUDE.md)

### 7. Architecture & Process (Uri's preferences)

- [ ] **Small focused PRs**: >10 files → consider splitting. (PR #97)
- [ ] **Rebase before review**: Branch must be on current `main`. (PR #97, #124, #154)
- [ ] **Link to issues**: Bug fixes → `Closes #N`. (`.claude/rules/pull-requests.md`)
- [ ] **Respond to every review comment**: Fix or explain. Never leave unanswered. (PR #97)
- [ ] **CI must be green**: Trigger `@coderabbitai review` if rate-limited. (PR #154, #164, #187)
- [ ] **Additive only**: New fields default to empty/nil. Never break backward compat.
- [ ] **Don't include local tooling in upstream PRs**: Skills, local configs stay on your fork's main.

### 8. Testing

- [ ] **Unit tests for new logic**: Isolated `UserDefaults(suiteName:)`, temp directories. (PR #187, #198)
- [ ] **Await background work in tests**: Join detached tasks before asserting. (PR #154)
- [ ] **Stable locale in process tests**: Set `LC_ALL=C` for git/subprocess output. (PR #164)

## Severity Guide

- 🔴 **CRITICAL** — Will definitely block merge (crashes, data corruption, security)
- 🟠 **MAJOR** — CodeRabbit will flag, maintainer will request fix
- 🟡 **MINOR** — Good to fix, won't block merge alone
- 🔵 **TRIVIAL** — Style/convention, fix if easy

## Learning

After each CodeRabbit review, update this checklist:
1. Read the new findings
2. Add NEW patterns with the PR number
3. Remove obsolete patterns
4. This file is the single source of truth
