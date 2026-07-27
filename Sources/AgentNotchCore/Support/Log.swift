import Foundation
import os

/// Unified-logging handles.
///
/// Everything the app drops on the floor — malformed JSON, an unknown source,
/// a payload with no `session_id` — is reported here and nowhere else. The HTTP
/// surface is fail-open by contract (see `EventRouter`), so `os.Logger` is the
/// only place a dropped event is ever visible.
///
///     log stream --predicate 'subsystem == "com.agentnotch.core"'
public enum Log {
    public static let subsystem = "com.agentnotch.core"

    public static let ingest = Logger(subsystem: subsystem, category: "ingest")
    public static let server = Logger(subsystem: subsystem, category: "server")
    public static let registry = Logger(subsystem: subsystem, category: "registry")
}
