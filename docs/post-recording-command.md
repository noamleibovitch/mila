# Run a command after each recording

Mila can run one command of yours each time a recording finishes. It is the
generic way to send transcripts somewhere Mila has no built-in support for.
You write a script, and Mila runs it with the recording's files.

A plain shell script is the main use: copy the subtitles into a dated folder,
append a line to a log, call a webhook, hand the audio to a backup tool. The
same hook can also start an LLM agent that reads the transcript and acts on
it. Mila does not know or care which one it is. It launches an executable and
reports the exit code.

The hook is off by default. Nothing is launched until you turn it on and
enter a command.

## Setting it up

Settings → Storage → **Run a command after each recording**.

| Setting | What it does |
|---|---|
| Toggle | Turns the hook on. Off by default. |
| Command | A full path to a script or executable, then any fixed arguments. `~/` is expanded. A bare name such as `hook.sh` is refused, because Mila does not search `PATH` for the command itself. |
| Stop it after | Seconds one run may take before Mila terminates it. Default 600, minimum 5, maximum 3600. |
| Run on Latest Recording | Runs the command now against your newest finished recording, so you can test a script without recording anything. |

The file must be executable (`chmod +x`). Settings says so when the path is
missing, is a directory, or lacks the executable bit.

Mila launches the command directly, not through a shell. Quotes and
backslashes group arguments the way a shell would, and that is all: `$HOME`,
`*`, `|` and `>` are passed to your program as literal text. Put that logic
inside the script.

## When it runs

Once per new recording, after transcription has finished and the AI summary
has either landed, failed, or been skipped. It runs with summaries turned off
and with no LLM configured; the handoff then has no `summary`.

It runs for recordings you capture in Mila. Runs are queued and happen one at
a time.

It does not run:

- for recordings that already existed when you turned the hook on, or for the
  summary catch-up Mila does at launch
- for audio files you import, a Voice Memos sync, or a recording Mila
  recovers at launch after a crash. Use "Run Post-Recording Command" in the
  recording's context menu for those
- when you re-transcribe a recording. Your command has effects Mila cannot
  see, so Mila does not repeat them on its own
- for dictation, or for a `.milashare` someone sent you
- for a recording that is in Recently Deleted or has been deleted

To run it again for one recording, right-click the recording and choose
**Run Post-Recording Command**. The menu item appears once the hook is on and
a command is entered.

A banner in the main window reports each run: finished, failed with the exit
code and the first line your command wrote to stderr, or stopped at the
timeout.

## What your command receives

**Arguments.** Your fixed arguments, then the path of the handoff file as the
last argument.

**Environment.** Mila's own environment, with `PATH` extended by the usual
Homebrew, npm and version-manager directories so that `#!/usr/bin/env node`
and friends resolve, plus:

| Variable | Value |
|---|---|
| `MILA_RECORDING_ID` | The recording's UUID. |
| `MILA_HANDOFF` | Path of the handoff JSON (same as the last argument). |
| `MILA_SRT` | Path of the `.srt` subtitles. Unset if there is no such file. |
| `MILA_TXT` | Path of the plain-text transcript. Unset if there is no such file. |
| `MILA_AUDIO` | Path of the audio file. Unset if there is no such file. |

**Working directory.** `~/Library/Application Support/Mila/post-recording-command`,
a directory Mila owns. It is never your home folder. Use absolute paths for
anything you read or write elsewhere.

**Standard input** is closed. Whatever the command prints is read and
discarded, apart from the one line shown in the failure banner.

## The handoff file

Before each run Mila writes
`~/Library/Application Support/Mila/handoff/<recording-id>.json`:

```json
{
  "actionItems" : [
    {
      "id" : "a1",
      "source" : "inferred",
      "speaker" : "Dana",
      "text" : "Send the deck to the client"
    }
  ],
  "appName" : "zoom.us",
  "createdAt" : "2026-11-15T09:31:07Z",
  "duration" : 1867.4,
  "files" : {
    "audio" : "/Users/dana/Library/Application Support/Mila/Recordings/Weekly sync.m4a",
    "srt" : "/Users/dana/Library/Application Support/Mila/Recordings/Weekly sync.srt",
    "summary" : "/Users/dana/Library/Application Support/Mila/Recordings/Weekly sync.summary.txt",
    "txt" : "/Users/dana/Library/Application Support/Mila/Recordings/Weekly sync.txt"
  },
  "folder" : "Work",
  "id" : "6F1C0E0A-3B1D-4E0B-9C55-0A6F2C1B7D10",
  "language" : "en",
  "schemaVersion" : 1,
  "source" : "meeting",
  "speakers" : {
    "SPEAKER_00" : "Dana",
    "SPEAKER_01" : "SPEAKER_01"
  },
  "startedAt" : "2026-11-15T08:59:59Z",
  "summary" : "The team agreed to ship on Thursday.",
  "title" : "Weekly sync"
}
```

| Key | Type | Notes |
|---|---|---|
| `schemaVersion` | number | `1`. New keys can be added without changing it. It changes only if a key is removed or its type changes. |
| `id` | string | The recording's UUID. |
| `title` | string | The title at the time of the run. If Mila is still generating a title, this is the default one. |
| `createdAt` | ISO 8601 date, UTC | When the recording was saved. For a recording you captured, that is when you pressed Stop. For an imported file it is the import time, and for a Voice Memo it is the memo's own date. |
| `startedAt` | ISO 8601 date, UTC | `createdAt` minus `duration`. Paused time is not part of `duration`, so a recording you paused reads as starting later than it did. For imports it is an estimate. |
| `duration` | number | Seconds of audio. |
| `language` | string | Transcript language code, `he` or `en`. |
| `source` | string | `microphone`, `systemAudio`, `meeting` or `voiceMemo`. |
| `folder` | string | The Mila folder. Omitted when the recording is unfiled. |
| `appName` | string | The captured app, for app-audio and meeting recordings. Omitted otherwise. |
| `speakers` | object | Raw speaker id to the label used in the `.srt` and `.txt`: the name you assigned, or the raw id for an unnamed speaker. Empty when speakers were not identified. |
| `calendarEvent` | object | Only when the calendar match is on and the recording overlapped an event: `title`, `start`, `end`, `calendarName`, and `attendees` as a list of `name` and optional `email`. Missing otherwise. |
| `files` | object | Absolute paths under `audio`, `srt`, `txt` and `summary`. A key is present only if the file exists. |
| `summary` | string | The AI summary. Omitted when there is none. |
| `actionItems` | array | Each item has `id`, `text`, `source` (`inferred` or `voice_command`) and, when known, `speaker`. Empty when there are none. |

Read keys by name and ignore ones you do not know. Later versions may add
keys.

The file is readable only by you (mode 0600). Mila keeps the 20 newest
handoff files and deletes older ones, and deletes a recording's handoff when
you delete the recording permanently. Copy anything you want to keep.

## Example: copy the subtitles into a dated folder

```sh
#!/bin/sh
set -eu
dest="$HOME/Transcripts/$(date +%Y-%m-%d)"
mkdir -p "$dest"
cp "$MILA_SRT" "$dest/"
```

Save it as `~/bin/file-transcript.sh`, run `chmod +x ~/bin/file-transcript.sh`,
and enter `~/bin/file-transcript.sh` as the command. With `set -u` the script
fails with a clear message on the rare recording that has no `.srt`, and the
banner shows it.

If the destination is in Desktop, Documents, Downloads or iCloud Drive, macOS
asks once whether Mila may access that folder. The request names Mila because
the script runs as Mila's child process.

To use more of the handoff, read it with `jq`. This one names the copy after
the recording's title:

```sh
#!/bin/sh
set -eu
title=$(jq -r .title "$1" | tr '/:' '--')
cp "$MILA_SRT" "$HOME/Transcripts/$(date +%Y-%m-%d) $title.srt"
```

## Example: hand the recording to an agent

The same hook starts an agent CLI. The script passes it the handoff path and
a fixed instruction:

```sh
#!/bin/sh
set -eu
exec claude -p "Read the JSON file at $1. It describes a meeting recording \
and gives the path of its transcript under files.txt. Read the transcript, \
then add each action item to ~/notes/todo.md under today's date." \
  --allowedTools "Read,Edit"
```

Three things to know before you rely on this:

- The agent runs unattended, as you, with whatever tools you allow it. Keep
  the allowed tools as narrow as the job needs.
- A transcript is text other people spoke. An agent that reads it can be
  steered by what was said in the meeting. Do not give such an agent tools
  you would not hand to the people in the call.
- Agents are slow. Raise the timeout if runs are being stopped at 600
  seconds.

## Safety notes

- **It runs as you.** The command has your permissions, your files and your
  network access. Mila does not sandbox it. Only enter a command you would
  run yourself in a terminal.
- **Off by default.** No command is launched until you turn the hook on and
  enter one. Turning it off stops new runs. A run that has already started
  is left to finish or time out.
- **No shell.** The command line is split into arguments and launched
  directly, so nothing in it is expanded.
- **Nothing from a recording goes on the command line.** Titles, names and
  transcript text reach your command only inside the handoff file and the
  files it points to. A meeting titled `; rm -rf ~` is a string in a JSON
  file.
- **Deleting stops it.** If you delete a recording, or move it to Recently
  Deleted, while its command is queued or running, Mila terminates the
  command. A permanent delete also removes the handoff file. Mila cannot
  undo what the command already did.
- **Timeouts are enforced.** At the limit Mila sends SIGTERM to the command
  and the processes it started, then SIGKILL if they are still there.
- **Logs carry no content.** Mila's log records the recording's UUID, the
  exit code, the duration and how many bytes the command printed. It never
  records the title, file paths or the command's output.
- **The command text stays out of support bundles.** The diagnostics export
  reports only its length, because arguments often hold a webhook URL or a
  token.

What it never does: upload anything on its own, run for old recordings,
retry a failed run, wait for the command before letting you record again, or
resume queued runs after Mila quits.

The hook is a per-user setting. It cannot be set from a `.milaconfig` file
or an MDM profile.
