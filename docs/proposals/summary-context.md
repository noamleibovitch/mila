# Draft upstream issue: give the automatic summary the facts Mila already has

Not filed. Two changes, on two stacked branches.

## 1. The summary cannot attribute anything (`feat/summary-speaker-labels`)

**Problem.** `RecordingSummarizer` builds its call from `Recording.fullText`, the plain join with no speaker labels. On a recording where every speaker is named, the model still writes "the main speaker prefers…" and returns action items with no owner. The Send action and `mila-mcp` already send the labelled rendering (`TranscriptFormatter.plainText`).

**Change.** Send `TranscriptFormatter.plainText(segments:fallback:names:)`. The staleness check in `completion(of:token:produced:)` compares the same rendering, so naming a speaker while a call is out re-runs it once.

**Behaviour change to review.** A rename mid-flight now costs one follow-up call. A rename after the summary landed still does not regenerate it, and summaries stored before this change are not rebuilt; both need "Regenerate summary". Marking a summary stale on rename is a separate decision.

## 2. Prompt variables and a context file (`feat/summary-context`)

**Problem.** The summary prompt can only say `{{LANGUAGE}}`. It cannot mention the title, the date, the length or who spoke, so a user cannot ask for "a longer summary for a long meeting" or "a 1:1 format when there are two speakers". And there is nowhere to put standing background: who the people are, product names the model keeps misspelling, house style. Pasting that into the prompt works, but it is the same pattern that caused #110 for Live AI, and it cannot be shared or versioned.

**Change.**
- `{{TITLE}}`, `{{DATE}}`, `{{DURATION}}`, `{{SPEAKERS}}`, `{{MY_NAME}}` in the summary prompt. Unknown facts resolve to empty. A prompt with no tokens is sent byte-identical to today.
- `llm.summary.contextFile`: an optional path to a text or Markdown file, inlined ahead of the prompt inside a `<context>` block. Read at send time. Capped at 256 KB. A missing, empty, oversized or non-UTF-8 file is skipped and the summary still runs; Settings names the state.

**Deliberately left out.** Path delivery for the context file (the unattended summary stays inline, same reasoning as #179). `.milaconfig` / MDM support. Per-folder prompts. Calendar attendees (`{{ATTENDEES}}` belongs with #384).

**Privacy.** The file's text goes to the same provider the transcript already goes to. The diagnostic report exports the setting as `<set>` / `<not set>`, never the path.
