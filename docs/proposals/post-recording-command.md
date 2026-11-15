# Proposal: run a user command after each recording

Draft for an upstream issue. Not filed.

## Problem

People keep asking for Mila to send finished transcripts somewhere: Notion, a
task tracker, a shared drive, a team webhook. Each request is reasonable and
each is a separate integration to build, authenticate and maintain. The
current answer is the manual **Send to LLM** action, which covers the
"have an agent deal with it" case but has two gaps:

- It is manual. Somebody has to press it for every recording.
- It needs an LLM. Most of what people want is deterministic: copy the
  `.srt` next to the project, post a link to a channel, run the filing script
  they already have. Routing that through a model is slower, costs money and
  can get it wrong.

The Obsidian export shows the shape that works (off by default, fires once
per fresh recording after the summary settles), but it is one destination.

## Proposal

One opt-in setting: a command Mila runs once per fresh recording, after its
summary state is final.

- Settings → Storage gets a toggle, a command field (full path plus fixed
  arguments) and a timeout. Off by default.
- Before the run Mila writes a small JSON handoff describing the recording
  (id, title, dates, duration, language, source, folder, speakers, paths of
  the audio and sidecars, summary, action items) and passes its path as the
  last argument. `MILA_SRT`, `MILA_TXT`, `MILA_AUDIO`, `MILA_HANDOFF` and
  `MILA_RECORDING_ID` are set for scripts that want one file.
- The command is tokenized with `LLMRunner.tokenizeArguments` and launched
  directly. No shell, and nothing from a recording is ever placed on the
  command line.
- A banner reports the result. A context-menu item reruns the command for
  one recording.

A five-line shell script then covers "copy the subtitles into a dated
folder". The same hook can start `claude -p` or any other agent runner, and
Mila does not need to know.

### Design points

- **Sequencing is the Obsidian exporter's.** `markPending` at the two places
  `obsidian.markPending` is called for a fresh completion, the run from
  `RecordingSummarizer.onSummaryFinished` (so it fires on the skip paths with
  summaries off or no LLM), and a session tombstone so `finalizeTail` cannot
  re-arm a discarded recording. The launch backfill never marks, so it never
  runs.
- **Feature gate.** `isReady` means enabled and the command resolves to an
  executable file, per `.claude/rules/feature-gates.md`.
- **Subprocess handling reuses `LLMRunner.executeProcess`**, which gains two
  optional parameters (environment, working directory). Pipes are drained on
  dedicated threads, the exit is observed by `terminationHandler` with the
  `waitUntilExit` backstop, the timeout is SIGTERM then SIGKILL on the
  process group, and every wait is bounded.
- **Runs are serial.** A Voice Memos sync can complete many recordings in a
  row; one child at a time is the caller-side bound the subprocess rules ask
  for.
- **Deleted stays deleted.** The runner listens to
  `RecordingStore.permanentlyDeleted`: it kills a queued or running command
  for that recording and deletes its handoff file. Trashing a recording
  cancels its run without a tombstone.
- **Logs.** Recording UUID, trigger, exit code, duration, byte counts. No
  title, no paths, no command output.
- **Handoff files** live under the store's original root in `handoff/`, mode
  0600, newest 20 kept.
- **Diagnostics.** `postCommand.*` is exported in the support bundle with the
  command reduced to its length.

## Scope

- `PostRecordingCommandSettings`, `PostRecordingCommandRunner`,
  `PostRecordingHandoff`, a Settings section, a context-menu item.
- Wiring in `MilaApp`, `QuickActionsController.finalizeTail` and
  `PostRecordingCoordinator.cancelAndDiscard`.
- Unit tests for the settings, the handoff schema (key set pinned) and the
  runner, including real child processes for argv, environment, timeout and
  delete-while-running.
- `docs/post-recording-command.md`.

No new dependencies. No change to `recordings.json`, MilaKit, the MCP helper
or the share format.

## Deliberately left out

- **Calendar data.** Another branch adds `Recording.calendarEvent`. The
  handoff encoder has a marked extension point and no placeholder field.
- **MDM and `.milaconfig`.** A profile that can set a command to run on
  every managed Mac is a different trust decision from the one a user makes
  for themselves. It deserves its own issue. No `MilaConfig` field was
  added, so the `ManagedField` tripwire tests are untouched.
- **Automatic rerun on re-transcription.** The Obsidian note is overwritten
  in place, so re-exporting is safe. A command's side effects are unknown,
  so the rerun is manual. This is the one place the hook differs from the
  exporter's sequencing, and it is an open question.
- **Waiting for the auto-generated title.** The run starts when the summary
  settles. The title job runs in parallel, so the handoff can carry the
  default title.
- **Retries, a run history, per-folder or per-source filters, several
  commands.** A script can do all of these itself.
- **Persisting the queue.** Runs queued when Mila quits are dropped.
- **A sandbox for the command.** It runs as the user. The docs say so.
