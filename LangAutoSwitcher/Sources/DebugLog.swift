import Foundation

/// Appends to a file the user (and support) can actually read.
///
/// NSLog from an input method does not reliably reach the unified log — this
/// process's messages were invisible to `log show` throughout debugging, which
/// made "no output" impossible to distinguish from "code never ran". A file we
/// control removes that ambiguity.
enum DebugLog {
    private static let queue = DispatchQueue(label: "LangAutoSwitcher.debuglog")

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LangAutoSwitcher", isDirectory: true)
            .appendingPathComponent("debug.log")
    }

    static func write(_ message: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp)  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let url = Self.url
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
