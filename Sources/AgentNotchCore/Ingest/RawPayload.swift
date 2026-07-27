import Foundation

/// A thin, forgiving reader over one decoded JSON object.
///
/// Deliberately `JSONSerialization` and NOT `Codable`. A Claude Code hook
/// payload carries `tool_input`, which is arbitrary nested JSON whose shape
/// differs per tool and changes between releases — a `Codable` model would
/// either need `AnyCodable` (all of the cost, none of the safety) or would fail
/// to decode the whole envelope because of one unexpected field. We read a
/// handful of known keys and ignore everything else, forever.
public struct RawPayload {
    private let root: [String: Any]

    /// `nil` when the bytes are not JSON, or are JSON but not an object.
    public init?(_ data: Data) {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = any as? [String: Any]
        else { return nil }
        self.root = object
    }

    /// For tests and for callers that already hold a decoded object.
    public init(object: [String: Any]) {
        self.root = object
    }

    /// Top-level string. Numbers and bools are coerced; anything else is `nil`.
    public func string(_ key: String) -> String? {
        Self.asString(root[key])
    }

    /// Top-level integer. Numeric strings are coerced.
    public func int(_ key: String) -> Int? {
        Self.asInt(root[key])
    }

    /// Top-level nested object.
    public func object(_ key: String) -> [String: Any]? {
        root[key] as? [String: Any]
    }

    /// Walk a nested path, e.g. `path("_meta", "pid")`. Returns the raw value so
    /// the caller decides how to coerce it.
    public func path(_ keys: String...) -> Any? {
        var current: Any? = root
        for key in keys {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    // MARK: - Coercion

    /// JSON is written by shell scripts as often as by programs, so `"1234"` and
    /// `1234` both have to mean the same thing.
    public static func asString(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case is NSNull, nil: return nil
        default: return nil
        }
    }

    public static func asInt(_ any: Any?) -> Int? {
        switch any {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}
