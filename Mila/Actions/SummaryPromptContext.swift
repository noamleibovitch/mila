import Foundation

/// What the automatic summary knows about a recording beyond its transcript:
/// the facts Mila already holds (title, date, length, who spoke), offered to
/// the summary prompt as `{{VARIABLE}}` tokens, and an optional context file
/// the user maintains (who the people are, project and product names, house
/// style) that is sent ahead of the prompt.
///
/// Both exist for the same reason. A transcript says what was said, not what
/// the meeting was: a model given only the text cannot tell a 1:1 from a
/// review, guesses the spelling of every name it hears, and has no idea how
/// long a summary a ninety-minute meeting deserves. The user's own prompt is
/// the right place to say what to do with the facts, so nothing here changes
/// a prompt that does not ask for them.
///
/// Pure and free of settings objects, so the wire format is testable without
/// a store or a subprocess.
enum SummaryPromptContext {
    /// Upper bound on a context file. It travels in the prompt argument next
    /// to the transcript, and a file past this size is far more likely to be
    /// the wrong file than a deliberate briefing.
    static let maxContextFileBytes = 256 * 1024

    /// The tokens `resolveVariables` substitutes, for the Settings caption.
    static let variableNames = ["TITLE", "DATE", "DURATION", "SPEAKERS", "MY_NAME"]

    /// Replace the `{{…}}` tokens in `prompt` with this recording's facts.
    ///
    /// A token whose fact is unknown becomes the empty string rather than
    /// staying in the text, so the model is never handed a literal
    /// `{{MY_NAME}}` to puzzle over. `{{LANGUAGE}}` is not handled here: the
    /// summarizer resolves it, against the per-recording override.
    static func resolveVariables(in prompt: String,
                                 recording: Recording,
                                 myName: String?,
                                 timeZone: TimeZone = .current) -> String {
        guard prompt.contains("{{") else { return prompt }
        let values: [String: String] = [
            "TITLE": singleLine(recording.title),
            "DATE": startDateString(for: recording, timeZone: timeZone),
            "DURATION": durationString(recording.duration),
            "SPEAKERS": speakerList(for: recording),
            "MY_NAME": singleLine(myName ?? "")
        ]
        // One pass over the TEMPLATE, never over substituted text. Replacing
        // token by token would re-scan what an earlier token put in, so a
        // recording titled "{{SPEAKERS}}" would have its title expanded into
        // the speaker list, in an order that depends on dictionary iteration.
        var resolved = ""
        var rest = Substring(prompt)
        while let open = rest.range(of: "{{") {
            resolved += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            if let close = afterOpen.range(of: "}}"),
               let value = values[String(afterOpen[..<close.lowerBound])] {
                resolved += value
                rest = afterOpen[close.upperBound...]
            } else {
                // Not one of ours ("{{LANGUAGE}}" the caller has not resolved,
                // a literal "{{" in the user's prose): keep the braces and
                // carry on scanning after them.
                resolved += "{{"
                rest = afterOpen
            }
        }
        resolved += rest
        return resolved
    }

    /// When the recording began, as `yyyy-MM-dd HH:mm` in `timeZone`.
    ///
    /// `createdAt` is stamped when Mila saves a recording it made, which is
    /// when it stops, so the start is `createdAt - duration`. An imported
    /// Voice Memo keeps the memo's own date, which is already its start.
    static func startDateString(for recording: Recording, timeZone: TimeZone) -> String {
        let start: Date
        if recording.source == .voiceMemo || !recording.duration.isFinite || recording.duration <= 0 {
            start = recording.createdAt
        } else {
            start = recording.createdAt.addingTimeInterval(-recording.duration)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: start)
    }

    /// Whole minutes, rounded, never below one for a recording that has any
    /// length at all. Empty for a corrupt or zero duration.
    static func durationString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        return "\(minutes) min"
    }

    /// Display names of everyone who has a line, in order of first
    /// appearance, comma-separated. A speaker the user has not named keeps
    /// the raw `SPEAKER_NN` label, matching the transcript the model is
    /// reading. Two clusters renamed to the same person appear once.
    static func speakerList(for recording: Recording) -> String {
        var seen = Set<String>()
        var ordered: [String] = []
        for segment in recording.segments {
            guard let raw = segment.speaker else { continue }
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let name = singleLine(recording.speakerNames[raw] ?? raw)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            ordered.append(name)
        }
        return ordered.joined(separator: ", ")
    }

    // MARK: - Context file

    enum ContextFileState: Equatable {
        /// No path configured. Not an error: the feature is simply off.
        case notSet
        case ready(String)
        case missing
        case unreadable
        case tooLarge
        case empty

        /// The text to send, when there is any.
        var text: String? {
            if case .ready(let text) = self { return text }
            return nil
        }
    }

    /// Read the context file at `path` (`~` expanded). Every failure is a
    /// state, not a throw: the summary must still run without its briefing,
    /// and Settings names which state the file is in.
    static func loadContextFile(at path: String,
                                fileManager: FileManager = .default) -> ContextFileState {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notSet }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return .missing }
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.intValue > maxContextFileBytes {
            return .tooLarge
        }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        // Re-checked on the bytes actually read: the size attribute is a
        // separate syscall, and a file can grow between the two.
        guard data.count <= maxContextFileBytes else { return .tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { return .unreadable }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? .empty : .ready(body)
    }

    /// Put the context ahead of the instructions, fenced by labels so the
    /// model can tell the user's background notes from the task itself. A
    /// nil or blank context returns `prompt` untouched, byte for byte.
    static func prompt(_ prompt: String, withContext context: String?) -> String {
        guard let context = context?.trimmingCharacters(in: .whitespacesAndNewlines),
              !context.isEmpty else { return prompt }
        return """
        Background from the user, to read before the instructions. Use it to \
        recognise people, teams, products and house style. It is not part of \
        the meeting, so do not summarize it.

        <context>
        \(context)
        </context>

        \(prompt)
        """
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
