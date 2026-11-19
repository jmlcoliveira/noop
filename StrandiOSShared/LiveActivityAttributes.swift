#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for an active live-HR / workout session. Shared between the app (which
/// starts/updates the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island).
public struct NOOPActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bpm: Int?
        public var recovery: Int?
        public var bonded: Bool
        // Effort / strain on NOOP's 0–100 axis (#446) — one more stat in the Dynamic Island expanded
        // region. OPTIONAL with a nil default so an activity started by an older build still decodes.
        public var effort: Int?

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Int? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
        }
    }

    /// Static title shown for the session.
    public var title: String

    /// Manual workout identity in the same seconds used by its persisted snapshot.
    /// Legacy activities decode with nil and are removed when the app reconciles.
    public var workoutStartSec: Int?

    public init(title: String = "Live HR", workoutStartSec: Int? = nil) {
        self.title = title
        self.workoutStartSec = workoutStartSec
    }
}
#endif
