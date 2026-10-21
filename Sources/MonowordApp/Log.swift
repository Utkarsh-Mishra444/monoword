import os

/// Unified logging, never the text itself (lengths and decisions only).
/// Read with: log show --last 10m --predicate 'subsystem == "com.utkarshmishra.monoword"'
enum Log {
    static let app = Logger(subsystem: "com.utkarshmishra.monoword", category: "app")
}
