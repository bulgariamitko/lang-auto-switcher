import Foundation

/// Fetches a language's word list on demand.
///
/// Dictionaries are not bundled for every language — four of them would triple
/// the download for words most people never type — so a language added from
/// the menu fetches its dictionary once and keeps it in Application Support,
/// where app updates cannot remove it.
enum DictionaryDownloader {

    /// Published alongside the app's releases, under a tag that holds data
    /// rather than a build, so dictionaries can be corrected without shipping
    /// a new version of the app.
    private static let baseURL =
        "https://github.com/bulgariamitko/lang-auto-switcher/releases/download/dictionaries"

    enum Failure: LocalizedError {
        case network(String)
        case empty
        case wrongScript

        var errorDescription: String? {
            switch self {
            case .network(let why): return "Could not download the dictionary: \(why)"
            case .empty:            return "The downloaded dictionary was empty."
            case .wrongScript:      return "The downloaded file does not look like a word list."
            }
        }
    }

    /// Download and install the dictionary for `code`, calling back on the
    /// main queue. Does nothing if it is already installed.
    static func install(_ code: String, completion: @escaping (Result<Int, Error>) -> Void) {
        if LanguagePackStore.isInstalled(code) {
            DispatchQueue.main.async { completion(.success(0)) }
            return
        }
        guard let url = URL(string: "\(baseURL)/\(code)-dictionary.txt") else {
            DispatchQueue.main.async { completion(.failure(Failure.network("bad URL"))) }
            return
        }

        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            let finish: (Result<Int, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error = error {
                finish(.failure(Failure.network(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                finish(.failure(Failure.network("HTTP \(http.statusCode)")))
                return
            }
            guard let data = data, let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else {
                finish(.failure(Failure.empty))
                return
            }
            // A word list is one token per line. Anything else — an error page,
            // an HTML redirect — is rejected rather than written to disk and
            // loaded as vocabulary.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count > 100,
                  lines.prefix(50).allSatisfy({ !$0.contains(" ") && !$0.contains("<") })
            else {
                finish(.failure(Failure.wrongScript))
                return
            }
            do {
                try LanguagePackStore.install(dictionaryText: text, for: code)
                NSLog("LangAutoSwitcher: installed '%@' dictionary — %d words", code, lines.count)
                finish(.success(lines.count))
            } catch {
                finish(.failure(error))
            }
        }
        task.resume()
    }
}
