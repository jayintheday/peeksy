import Foundation

/// An outstanding permission prompt the agent is blocked on.
///
/// Two strings, not one: the row has ~60 columns and the tooltip has none, so
/// truncation is decided once at ingest and both forms are carried.
public struct PendingPermission: Sendable, Equatable {
    public let requestID: String
    public let toolName: String
    /// Truncated to 60 cols — what the row shows.
    public let summary: String
    /// Untruncated — what the tooltip shows.
    public let detail: String
    public let receivedAt: Date

    public init(requestID: String, toolName: String, summary: String, detail: String, receivedAt: Date) {
        self.requestID = requestID
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
        self.receivedAt = receivedAt
    }
}
