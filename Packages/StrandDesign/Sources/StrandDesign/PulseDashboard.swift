import SwiftUI

/// Shared visual tokens for the Pulse landing page. Scores retain their existing domain scales.
public enum PulseDashboardStyle {
    public static let backdropTop = Color(light: "#E6F3F1", dark: "#0A2026")
    public static let sleep = Color(light: "#507395", dark: "#7E9DBD")
    public static let recovery = Color(light: "#087F75", dark: "#23BFAE")
    public static let strain = Color(light: "#287AAF", dark: "#4098D0")
    public static let pagePadding: CGFloat = 20
    public static let headerSpacing: CGFloat = 36
    public static let ringSpacing: CGFloat = 10
    public static let ringWidth: CGFloat = 5
    public static let ringInset: CGFloat = 12
    public static let ringMaxDiameter: CGFloat = 164
    public static let brandTracking: CGFloat = 4
    public static let labelTracking: CGFloat = 1.5
    public static let titleTracking: CGFloat = -1
    public static let title = Font.system(.largeTitle, design: .rounded, weight: .bold)
    public static let score = Font.system(.title, design: .rounded, weight: .semibold).monospacedDigit()
}

public struct PulseWordmark: View {
    public init() {}

    public var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: "waveform.path.ecg")
                .font(StrandFont.title1)
                .foregroundStyle(NoopVisualStyle.mint)
            Text(verbatim: "PULSE")
                .font(StrandFont.headline)
                .tracking(PulseDashboardStyle.brandTracking)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Pulse"))
    }
}

/// A status label; its host owns navigation and the live device connection.
public struct PulseDeviceStatus: View {
    public let connected: Bool
    public let syncing: Bool

    public init(connected: Bool, syncing: Bool) {
        self.connected = connected
        self.syncing = syncing
    }

    public var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Circle()
                .fill(connected ? NoopVisualStyle.mint : StrandPalette.textSecondary)
                .frame(width: NoopMetrics.spaceHalf * 3, height: NoopMetrics.spaceHalf * 3)
            Text(syncing ? String(localized: "Syncing…", bundle: .module)
                         : String(localized: "Device", bundle: .module))
                .font(StrandFont.subhead)
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(StrandFont.subhead)
        }
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.horizontal, NoopMetrics.space3)
        .frame(minHeight: NoopMetrics.controlHeight)
        .background(StrandPalette.surfaceRaised, in: Capsule())
    }
}

/// Responsive, static ring for a real score. Missing data stays empty rather than reading as zero.
public struct PulseScoreSummary: View {
    public let label: String
    public let systemImage: String
    public let score: Double?
    public let tint: Color
    public var maxValue: Double
    public var decimals: Int
    public var caption: String?
    @Environment(\.locale) private var locale

    public init(label: String, systemImage: String, score: Double?, tint: Color,
                maxValue: Double = 100, decimals: Int = 0, caption: String? = nil) {
        self.label = label
        self.systemImage = systemImage
        self.score = score
        self.tint = tint
        self.maxValue = maxValue
        self.decimals = decimals
        self.caption = caption
    }

    private var validScore: Double? { score.flatMap { $0.isFinite ? $0 : nil } }
    private var progress: Double {
        guard let score = validScore, maxValue.isFinite, maxValue > 0 else { return 0 }
        return min(1, max(0, score / maxValue))
    }
    private var valueText: String {
        guard let score = validScore else { return "—" }
        return score.formatted(.number.precision(.fractionLength(decimals)).locale(locale))
    }
    private var statusText: String {
        caption ?? (validScore == nil ? String(localized: "Not available", bundle: .module)
                                     : String(localized: "out of \(maxValue.formatted(.number.locale(locale)))", bundle: .module))
    }

    public var body: some View {
        VStack(spacing: NoopMetrics.space2) {
            Circle()
                .strokeBorder(tint.opacity(0.22), lineWidth: PulseDashboardStyle.ringWidth)
                .overlay {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: PulseDashboardStyle.ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
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
                        Text(valueText)
                            .font(PulseDashboardStyle.score)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .padding(NoopMetrics.space4)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: PulseDashboardStyle.ringMaxDiameter)
            Text(label.uppercased(with: locale))
                .font(StrandFont.overline)
                .tracking(PulseDashboardStyle.labelTracking)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(statusText)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label), \(valueText), \(statusText)"))
    }
}
