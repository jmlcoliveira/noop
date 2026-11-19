import SwiftUI

private struct ScreenActivityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether this screen is visible and may prepare data or animate decoration. Tab shells can
    /// suspend hidden roots without removing their navigation stacks, selections, or scroll state.
    /// Standalone screens and sheets remain active unless their container explicitly overrides it.
    public var isScreenActive: Bool {
        get { self[ScreenActivityKey.self] }
        set { self[ScreenActivityKey.self] = newValue }
    }
}
