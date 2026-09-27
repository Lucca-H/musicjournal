import Foundation

extension String {
    /// Spotify playlist descriptions contain HTML links and entities; turn them into plain text.
    var strippingHTML: String {
        var s = replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'",
            "&apos;": "'", "&lt;": "<", "&gt;": ">", "&#x2F;": "/", "&nbsp;": " ",
        ]
        for (entity, char) in entities {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func truncated(to length: Int) -> String {
        count <= length ? self : String(prefix(length - 1)) + "…"
    }

    /// Lowercased, diacritic-free, alphanumerics only, for loose name matching.
    var matchKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
