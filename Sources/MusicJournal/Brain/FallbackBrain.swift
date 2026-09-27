import Foundation

enum BrainPreference: String, CaseIterable, Identifiable, Sendable {
    case auto
    case claudeOnly
    case onDeviceOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Claude, fall back to on-device"
        case .claudeOnly: "Claude only"
        case .onDeviceOnly: "On-device only"
        }
    }
}

struct BrainResult: Sendable {
    let plan: MoodPlan
    let brain: BrainKind
    /// Set when the primary brain failed and the fallback answered.
    let fallbackReason: String?
}

/// Tries Claude first and falls back to Apple's on-device model (or honours a fixed preference).
struct FallbackBrain: Sendable {
    let primary: any MoodBrain
    let fallback: any MoodBrain
    let preference: BrainPreference

    func interpret(_ request: MoodRequest) async throws -> BrainResult {
        switch preference {
        case .claudeOnly:
            return BrainResult(plan: try await primary.interpret(request), brain: primary.kind, fallbackReason: nil)
        case .onDeviceOnly:
            return BrainResult(plan: try await fallback.interpret(request), brain: fallback.kind, fallbackReason: nil)
        case .auto:
            do {
                return BrainResult(plan: try await primary.interpret(request), brain: primary.kind, fallbackReason: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch let primaryError {
                do {
                    let plan = try await fallback.interpret(request)
                    return BrainResult(plan: plan, brain: fallback.kind, fallbackReason: primaryError.localizedDescription)
                } catch let fallbackError {
                    throw BrainError.failed(
                        "\(primary.kind.label): \(primaryError.localizedDescription)\n"
                            + "\(fallback.kind.label): \(fallbackError.localizedDescription)"
                    )
                }
            }
        }
    }
}
