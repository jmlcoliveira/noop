import SwiftUI

/// Shared banded material for Pulse metric progress fills.
///
/// Keep these stops in sync across horizontal bars and circular rings so the same metric tint
/// carries the same dark/light texture wherever it appears.
public enum PulseMetricMaterial {
    /// The visible dark ↔ light bands used by Pulse progress fills.
    public static func gradient(for tint: Color) -> Gradient {
        Gradient(stops: [
            .init(color: darker(tint, by: 0.48), location: 0.00),
            .init(color: lighter(tint, by: 0.38), location: 0.34),
            .init(color: darker(tint, by: 0.22), location: 0.58),
            .init(color: lighter(tint, by: 0.28), location: 0.82),
            .init(color: darker(tint, by: 0.35), location: 1.00)
        ])
    }

    private static func darker(_ color: Color, by fraction: Double) -> Color {
        let components = color.rgbaComponents
        let amount = min(max(fraction, 0), 1)
        return Color(.sRGB,
                     red: components.r * (1 - amount),
                     green: components.g * (1 - amount),
                     blue: components.b * (1 - amount),
                     opacity: 1)
    }

    private static func lighter(_ color: Color, by fraction: Double) -> Color {
        let components = color.rgbaComponents
        let amount = min(max(fraction, 0), 1)
        return Color(.sRGB,
                     red: components.r + (1 - components.r) * amount,
                     green: components.g + (1 - components.g) * amount,
                     blue: components.b + (1 - components.b) * amount,
                     opacity: 1)
    }
}
