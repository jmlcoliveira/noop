import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

/// A lightweight, chronological readout for the selected Home day.
///
/// The caller supplies the already-resolved sleep session, its asleep duration, and that day's workouts.
/// This view does no repository reads, day-window filtering, or sleep-stage decoding. The sleep row is
/// intentionally read-only: `TabRoute.sleep` opens the latest Sleep page, which could mislabel a past day.
struct PulseDayActivitiesView: View {
    let selectedDayKey: String
    /// The selected day's canonical/main sleep session, selected by local wake day by the caller.
    let sleepSession: CachedSleepSession?
    /// Asleep minutes resolved by the caller from the matching stages, falling back to its DailyMetric.
    /// This is not inferred from the session's in-bed start/end times.
    let totalSleepMinutes: Double?
    /// Workouts already loaded and scoped by the caller to the selected Home day.
    let workouts: [WorkoutRow]
    var isLoading = false

    @EnvironmentObject private var repo: Repository
    @Environment(\.locale) private var locale
    @AppStorage(ClockFormatPreference.defaultsKey) private var clockFormatRaw = ClockFormatPreference.system.rawValue
    @State private var selectedWorkout: WorkoutDetailTarget?

    private struct WorkoutDetailTarget: Identifiable {
        let row: WorkoutRow
        let id = UUID()
    }

    private struct ActivityItem: Identifiable {
        enum Kind {
            case sleep
            case workout(WorkoutRow)
        }

        let id: String
        let kind: Kind
        let title: String
        let duration: String
        let startTs: Int?
        let endTs: Int?
        let tint: Color

        var workout: WorkoutRow? {
            guard case .workout(let row) = kind else { return nil }
            return row
        }

        var timeRange: String {
            guard let startTs, let endTs else { return String(localized: "Times unavailable") }
            let start = Night.clockString(startTs)
            let end = Night.clockString(endTs)
            return "\(start) – \(end)"
        }
    }

    private var selectedDayLabel: String {
        let parts = selectedDayKey.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return selectedDayKey
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Calendar.current.date(from: components) else { return selectedDayKey }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    private var items: [ActivityItem] {
        var result: [ActivityItem] = []
        if let sleepSession {
            result.append(ActivityItem(
                id: "sleep-\(sleepSession.startTs)-\(sleepSession.endTs)",
                kind: .sleep,
                title: String(localized: "Sleep"),
                duration: sleepDuration(totalSleepMinutes),
                startTs: sleepSession.effectiveStartTs,
                endTs: sleepSession.endTs,
                tint: PulseDashboardStyle.sleep))
        } else if let totalSleepMinutes, totalSleepMinutes > 0 {
            // The daily total exists, but there is no session with honest start/end times to show.
            result.append(ActivityItem(
                id: "sleep-summary-\(selectedDayKey)",
                kind: .sleep,
                title: String(localized: "Sleep"),
                duration: sleepDuration(totalSleepMinutes),
                startTs: nil,
                endTs: nil,
                tint: PulseDashboardStyle.sleep))
        }

        for workout in workouts {
            result.append(ActivityItem(
                id: "workout-\(workout.startTs)-\(workout.endTs)-\(workout.sport)-\(workout.source)",
                kind: .workout(workout),
                title: WorkoutSource.displaySport(workout.sport),
                duration: workoutDuration(workout),
                startTs: workout.startTs,
                endTs: workout.endTs,
                tint: PulseDashboardStyle.strain))
        }

        return result.sorted { lhs, rhs in
            switch (lhs.startTs, rhs.startTs) {
            case let (left?, right?) where left != right: return left < right
            case (nil, nil): return lhs.id < rhs.id
            case (nil, _?): return true // Unknown sleep timing stays before timed entries.
            case (_?, nil): return false
            default: return lhs.id < rhs.id
            }
        }
    }

    var body: some View {
        let _ = clockFormatRaw
        let activityItems = items
        NoopCard(tint: PulseDashboardStyle.strain) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                SectionHeader("Sleep & activity", trailing: selectedDayLabel)

                if isLoading {
                    HStack(spacing: NoopMetrics.space2) {
                        ProgressView().controlSize(.small)
                        Text("Loading this day…")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: NoopMetrics.controlHeight, alignment: .leading)
                } else if activityItems.isEmpty {
                    emptyMessage("No sleep or activities recorded for this day.", symbol: "moon.zzz.fill")
                } else {
                    VStack(spacing: 0) {
                        if sleepSession == nil && (totalSleepMinutes ?? 0) <= 0 {
                            emptyMessage("No sleep recorded for this day.", symbol: "moon.zzz.fill")
                        }

                        ForEach(Array(activityItems.enumerated()), id: \.element.id) { index, item in
                            activityRow(item)
                            if index < activityItems.count - 1 || workouts.isEmpty {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }

                        if workouts.isEmpty {
                            emptyMessage("No activities recorded for this day.", symbol: "figure.run")
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedWorkout) { target in
            // Match WorkoutsView's read-only detail presentation: a NavigationStack in the sheet
            // keeps its toolbar and dismiss controls local to this first-hop detail.
            NavigationStack {
                WorkoutDetailView(row: target.row)
                    .environmentObject(repo)
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #else
            .frame(minWidth: NoopMetrics.detailSheetMinWidth, minHeight: NoopMetrics.detailSheetMinHeight)
            #endif
        }
    }

    @ViewBuilder
    private func activityRow(_ item: ActivityItem) -> some View {
        if let workout = item.workout {
            Button { selectedWorkout = WorkoutDetailTarget(row: workout) } label: {
                rowContents(item, showsChevron: true)
            }
            .buttonStyle(LiquidPressStyle())
        } else {
            rowContents(item, showsChevron: false)
        }
    }

    private func rowContents(_ item: ActivityItem, showsChevron: Bool) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            VStack(spacing: NoopMetrics.space1) {
                if let workout = item.workout {
                    WorkoutTypeIcon(workoutType: workout.sport, size: PulseScreenStyle.activityIconSize, weight: .semibold, color: item.tint)
                } else {
                    Image(systemName: "moon.zzz.fill")
                        .font(StrandFont.headline)
                        .foregroundStyle(item.tint)
                }
                Text(item.duration)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(item.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: PulseScreenStyle.activityTileWidth, height: PulseScreenStyle.activityTileHeight)
            .background(item.tint.opacity(PulseScreenStyle.activityTintOpacity),
                        in: RoundedRectangle(cornerRadius: NoopVisualStyle.compactRadius, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(item.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.timeRange)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, NoopMetrics.space2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(item.title), \(item.duration), \(item.timeRange)"))
        .accessibilityAddTraits(showsChevron ? .isButton : [])
    }

    private func emptyMessage(_ message: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: symbol)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text(message)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.controlHeight, alignment: .leading)
        .padding(.vertical, NoopMetrics.space1)
    }

    private func sleepDuration(_ minutes: Double?) -> String {
        guard let minutes, minutes.isFinite, minutes > 0 else { return "—" }
        return durationLabel(seconds: minutes * 60)
    }

    private func workoutDuration(_ workout: WorkoutRow) -> String {
        let seconds = workout.durationS.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? Double(max(0, workout.endTs - workout.startTs))
        return durationLabel(seconds: seconds)
    }

    private func durationLabel(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds) ?? "—"
    }
}
