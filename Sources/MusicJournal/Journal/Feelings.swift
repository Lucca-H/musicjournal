import SwiftUI

/// A named feeling with its own muted colour. Fourteen of them, so a month of entries reads
/// as more than light versus dark. Each sits at a (valence, energy) point, which is how a
/// mood's reading or an older heavy-to-bright entry maps onto the nearest one.
struct Feeling: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let red: Double, green: Double, blue: Double
    /// 0 dark/sad … 1 bright/happy.
    let valence: Double
    /// 0 still … 1 intense.
    let energy: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    static let all: [Feeling] = [
        Feeling(id: "joyful", label: "Joyful", red: 0.91, green: 0.79, blue: 0.45, valence: 0.95, energy: 0.75),
        Feeling(id: "excited", label: "Excited", red: 0.92, green: 0.58, blue: 0.47, valence: 0.85, energy: 0.95),
        Feeling(id: "loved", label: "Loved", red: 0.86, green: 0.58, blue: 0.64, valence: 0.9, energy: 0.5),
        Feeling(id: "grateful", label: "Grateful", red: 0.93, green: 0.72, blue: 0.58, valence: 0.8, energy: 0.35),
        Feeling(id: "calm", label: "Calm", red: 0.63, green: 0.75, blue: 0.64, valence: 0.7, energy: 0.15),
        Feeling(id: "hopeful", label: "Hopeful", red: 0.60, green: 0.75, blue: 0.87, valence: 0.7, energy: 0.55),
        Feeling(id: "nostalgic", label: "Nostalgic", red: 0.79, green: 0.67, blue: 0.51, valence: 0.5, energy: 0.3),
        Feeling(id: "tired", label: "Tired", red: 0.68, green: 0.66, blue: 0.78, valence: 0.4, energy: 0.05),
        Feeling(id: "numb", label: "Numb", red: 0.60, green: 0.62, blue: 0.65, valence: 0.35, energy: 0.2),
        Feeling(id: "anxious", label: "Anxious", red: 0.49, green: 0.66, blue: 0.64, valence: 0.25, energy: 0.75),
        Feeling(id: "overwhelmed", label: "Overwhelmed", red: 0.63, green: 0.47, blue: 0.66, valence: 0.2, energy: 0.9),
        Feeling(id: "sad", label: "Sad", red: 0.46, green: 0.57, blue: 0.79, valence: 0.12, energy: 0.3),
        Feeling(id: "lonely", label: "Lonely", red: 0.44, green: 0.46, blue: 0.68, valence: 0.15, energy: 0.1),
        Feeling(id: "angry", label: "Angry", red: 0.78, green: 0.43, blue: 0.39, valence: 0.08, energy: 0.95),
    ]

    static let maxPerEntry = 3

    static func named(_ id: String) -> Feeling? {
        all.first { $0.id == id }
    }

    /// The closest feeling to a (valence, energy) reading. Without energy, valence decides.
    static func nearest(valence: Double, energy: Double? = nil) -> Feeling {
        all.min { a, b in distance(a, valence, energy) < distance(b, valence, energy) } ?? all[0]
    }

    private static func distance(_ f: Feeling, _ valence: Double, _ energy: Double?) -> Double {
        let dv = f.valence - valence
        guard let energy else { return abs(dv) }
        let de = f.energy - energy
        return (dv * dv * 1.5 + de * de).squareRoot()   // valence matters a bit more
    }
}

/// How the day went, on one scale from awful to great. This is what colours the month chart
/// (feelings are the finer detail inside an entry). Stored as the entry's `valence`.
enum DayRating: Int, CaseIterable, Identifiable, Sendable {
    case awful = 1, rough, okay, good, great

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .awful: "Awful"
        case .rough: "Rough"
        case .okay: "Okay"
        case .good: "Good"
        case .great: "Great"
        }
    }

    var valence: Double { [0.1, 0.3, 0.5, 0.7, 0.9][rawValue - 1] }

    var color: Color { Theme.blend(valence: valence) }

    /// For "An awful day" / "A good day".
    var article: String { self == .awful ? "An" : "A" }

    init(valence: Double) {
        self = DayRating.allCases.min { abs($0.valence - valence) < abs($1.valence - valence) } ?? .okay
    }
}
