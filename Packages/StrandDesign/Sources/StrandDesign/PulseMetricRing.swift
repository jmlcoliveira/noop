import SwiftUI

/// Pulse score ring with a caller-owned readout so detail screens can keep their unit and scale format.
public struct PulseMetricRing<Readout: View>: View {
    /// Score value on the displayed scale. Missing or non-finite values render an empty ring.
    public let score: Double?
    /// Maximum value represented by a complete ring.
    public let maxValue: Double
    /// Accent used for the progress stroke and center icon.
    public let tint: Color
    /// SF Symbol shown above the caller-provided value.
    public let systemImage: String
    @ViewBuilder private let readout: () -> Readout

    /// Creates a Pulse ring while leaving number and unit formatting to the caller.
    public init(score: Double?, maxValue: Double = 100, tint: Color, systemImage: String,
                @ViewBuilder readout: @escaping () -> Readout) {
        self.score = score
        self.maxValue = maxValue
        self.tint = tint
        self.systemImage = systemImage
        self.readout = readout
    }

    private var progress: Double {
        guard let score, score.isFinite, maxValue.isFinite, maxValue > 0 else { return 0 }
        return min(1, max(0, score / maxValue))
    }

    public var body: some View {
        Circle()
            .strokeBorder(tint.opacity(0.22), lineWidth: PulseDashboardStyle.ringWidth)
            .overlay {
                Circle()
                    .trim(from: 0, to: progress)
                    .rotation(.degrees(-90))
                    .stroke(LinearGradient(
                        gradient: PulseMetricMaterial.gradient(for: tint),
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    ), style: StrokeStyle(lineWidth: PulseDashboardStyle.ringWidth,
                                          lineCap: .round))
                    .padding(PulseDashboardStyle.ringWidth / 2)
            }
            .overlay {
                Circle()
                    .strokeBorder(StrandPalette.hairline, style: StrokeStyle(
                        lineWidth: NoopMetrics.hairlineWidth,
                        dash: [NoopMetrics.spaceHalf, NoopMetrics.space1]))
                    .padding(PulseDashboardStyle.ringInset)
            }
            .overlay {
                VStack(spacing: NoopMetrics.space2) {
                    Image(systemName: systemImage)
                        .font(StrandFont.caption)
                        .foregroundStyle(tint)
                    readout()
                }
                .padding(NoopMetrics.space4)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: PulseDashboardStyle.ringMaxDiameter)
            .accessibilityHidden(true)
    }
}
