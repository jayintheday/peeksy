import Foundation

/// One line describing what a tool call is doing, e.g. `"Bash: npm test"`.
public enum ToolSummary {
    /// A session row gets about this many columns before it starts eating the
    /// project label.
    public static let maxColumns = 60

    public struct Result: Sendable, Equatable {
        /// Whitespace-collapsed and truncated to `maxColumns` — for the row.
        public let summary: String
        /// Whitespace-collapsed, never truncated — for the tooltip.
        public let detail: String

        public init(summary: String, detail: String) {
            self.summary = summary
            self.detail = detail
        }
    }

    /// Keys tried in order. `command` first because `Bash` is the tool people
    /// actually want to read; `url` last because `WebFetch` is the rarest.
    private static let preferredKeys = ["command", "file_path", "path", "url"]

    /// Build both forms from a tool name and its (arbitrary) input object.
    ///
    /// With no recognised key the value is the bare tool name — `"Read"`, not
    /// `"Read: Read"`.
    public static func describe(toolName: String, input: [String: Any]?) -> Result {
        let name = collapse(toolName)
        var text = name

        if let input {
            for key in preferredKeys {
                guard let raw = RawPayload.asString(input[key]) else { continue }
                let value = collapse(raw)
                guard !value.isEmpty else { continue }
                text = name.isEmpty ? value : "\(name): \(value)"
                break
            }
        }

        return Result(summary: truncate(text, to: maxColumns), detail: text)
    }

    /// Collapse every run of whitespace — including newlines — to a single
    /// space, and trim the ends.
    ///
    /// This happens BEFORE truncation, not after. A `Bash` command is routinely
    /// a multi-line heredoc; truncating first would leave an embedded `\n` in
    /// the first 60 characters and wreck the row layout.
    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Truncate to exactly `limit` characters including the trailing ellipsis.
    static func truncate(_ s: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard s.count > limit else { return s }
        return String(s.prefix(limit - 1)) + "…"
    }
}
