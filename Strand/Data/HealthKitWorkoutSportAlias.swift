import Foundation

/// Labels whose spelling differs from HealthKit's activity name but whose activity is unambiguous.
/// This is deliberately an outbound-only bridge: changing labels read back from HealthKit would alter
/// stored workout identity and needs its own migration/dedup treatment.
enum HealthKitWorkoutSportAlias: Equatable {
    case stairClimbing
    case traditionalStrengthTraining

    /// Resolve a stored sport label to the HealthKit activity family it should export as.
    /// Unknown labels return nil so HealthKitBridge keeps its existing `.other` fallback.
    static func resolve(_ sport: String) -> Self? {
        let key = sport.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "stairclimber", "stairmaster", "stairstepper", "stairclimbingmachine":
            return .stairClimbing
        case "strength", "strengthtraining", "weightlifting", "powerlifting", "bodybuilding":
            return .traditionalStrengthTraining
        default:
            return nil
        }
    }
}
