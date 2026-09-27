import Foundation

/// The request behind "Suggest from my writing".
enum FeelingPrompt {
    static let system = """
    You read one short, private journal entry and name how the writer felt. Choose one to three \
    feelings from the allowed list only, most prominent first, based on what the writing actually \
    expresses (not on what would be nice). `day` rates how the day went overall from 1 (awful) to \
    5 (great); most ordinary days are 3. `why` is one gentle sentence under 20 words, addressed to \
    the writer as "you", pointing at what in the entry suggests it. No advice.
    """

    static func user(text: String, mood: String?) -> String {
        var parts: [String] = []
        if let mood, !mood.isEmpty { parts.append("Mood they typed earlier: \"\(mood)\"") }
        parts.append("Entry:\n\(text.isEmpty ? "(no text)" : text)")
        parts.append("Allowed feelings: " + Feeling.all.map(\.id).joined(separator: ", "))
        return parts.joined(separator: "\n\n")
    }

    struct Response: Decodable {
        let feelings: [String]
        let day: Int
        let why: String
    }

    static let schema: String = {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["feelings", "day", "why"],
            "properties": [
                "feelings": ["type": "array", "items": ["type": "string", "enum": Feeling.all.map(\.id)]],
                "day": ["type": "integer", "enum": [1, 2, 3, 4, 5]],
                "why": ["type": "string"],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }()

    /// Keeps known IDs, in order, without duplicates, at most `Feeling.maxPerEntry`.
    static func validIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.map { $0.lowercased() }
            .filter { Feeling.named($0) != nil && seen.insert($0).inserted }
            .prefix(Feeling.maxPerEntry)
            .map { $0 }
    }
}
