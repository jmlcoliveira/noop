import SwiftUI

/// Shared page treatment for the Pulse iPhone screens that opt into the new appearance.
public enum PulseScreenStyle {
    public static let sectionSpacing = NoopMetrics.space6
    public static let calendarHeight: CGFloat = 520
    public static let calendarMaxWidth: CGFloat = 440
    public static let sleepSceneHeight: CGFloat = 440
    public static let sleepScoreDiameter: CGFloat = 184
    public static let sleepScoreFont = StrandFont.rounded(44)
    public static let sleepOnNight = Color(hex: "#7E9DBD")
    public static let activityTileWidth: CGFloat = 72
    public static let activityTileHeight: CGFloat = 60
    public static let activityIconSize: CGFloat = 20
    public static let activityTintOpacity: Double = 0.12
}

public struct PulsePageBackground: View {
    public init() {}

    public var body: some View {
        LinearGradient(colors: [PulseDashboardStyle.backdropTop, StrandPalette.surfaceBase],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .accessibilityHidden(true)
    }
}
