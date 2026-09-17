import Foundation

/// Shared utilities for the Call Recorder app.
public enum CallRecorderFolderNameFormatter {
    public static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        f.timeZone = .current
        return f.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
    }
}
