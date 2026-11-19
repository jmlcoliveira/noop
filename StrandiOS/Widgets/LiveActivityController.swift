#if os(iOS)
import Foundation
import ActivityKit
import Combine
import UIKit

/// Starts, updates, and ends the live-HR Live Activity on the Lock Screen and in the Dynamic Island: the heart rate
/// during a manually started workout. It follows the workout and strap from process start (`follow`).
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    /// What the banner reads — the live heart rate, the link, the day's recovery and effort — set once by `follow`.
    private weak var model: AppModel?
    private var workoutStartSec: Int? {
        model?.activeWorkout.map { Int($0.start.timeIntervalSince1970) }
    }
    /// Whether the Lift Log banner is on screen, which the heart rate banner makes room for.
    private var standsAside: () -> Bool = { false }
    private var cancellables: Set<AnyCancellable> = []
    private var activityObservation: Task<Void, Never>?
    private var lastPush: Date = .distantPast
    /// What the banner was last pushed with, so an unchanged banner is not pushed again
    /// (`LiveHRBannerPushPolicy`). Nil until this controller pushes, and again once it ends the activity.
    private var shownState: NOOPActivityAttributes.ContentState?
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
    private var isStarting = false
    /// When the banner being fed was started, for iOS's eight-hour limit (`LiveHRBannerLifecycle.renewAfter`). Kept in
    /// the defaults with the banner's id, because a banner outlives the run that started it. Nil when unknown.
    private var startedAt: Date?
    private static let startedKey = "liveActivity.hr.startedAt"
    /// iOS refused a start, and it was logged: once, not on every tick while NOOP is on screen.
    private var refusalLogged = false
    /// Banners NOOP has asked iOS to remove (`removeLeftovers`), so a tick that arrives before iOS has dropped one from
    /// its list neither asks again nor logs it twice.
    private var removing: Set<String> = []
    /// How long after the last push iOS treats the banner as fresh; after that the banner draws the dash
    /// (`NOOPLiveActivity.shownBpm`). A WHOOP 5.0 taken off the wrist goes quiet, and with nothing arriving iOS
    /// suspends NOOP, so no timer of NOOP's can clear the number: iOS's own stale date is what does it, in at most
    /// this long (a tester's log, 23 Sep 2026). A steady number is re-pushed once half of this has passed
    /// (`LiveHRBannerPushPolicy`), so a banner fed by a worn strap never goes stale.
    static let staleAfter: TimeInterval = 30

    deinit {
        activityObservation?.cancel()
    }

    /// Reconcile from process start, including background launches that never build a screen. The model
    /// already restores its persisted manual workout before this is called.
    func follow(_ model: AppModel, standsAside: @escaping () -> Bool) {
        self.model = model
        self.standsAside = standsAside
        // Refreshed once a change has landed, never from inside it (`LiveHRBannerInputs`). AppModel's median (`bpm`)
        // is an input in its own right: it moves on the R-R alone, and a clear that reached it that way refreshed
        // nothing, so the banner kept the last number until iOS's stale date drew the dash.
        let workoutChanges = model.$activeWorkout.map { $0?.start }.removeDuplicates()
        let readings = Publishers.Merge3(model.live.$heartRate.map { _ in () },
                                         model.live.$connected.map { _ in () },
                                         model.$bpm.map { _ in () })
            .filter { [weak model] _ in model?.activeWorkout != nil }
        LiveHRBannerInputs.settled([workoutChanges.map { _ in () }.eraseToAnyPublisher(),
                                   readings.eraseToAnyPublisher()])
            .sink { [weak self] in self?.refreshBanner() }
            .store(in: &cancellables)
        // Apply preference changes even when there are no heart-rate samples.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in UnitPrefs.liveActivityEnabled() }
            .prepend(UnitPrefs.liveActivityEnabled())
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.refreshBanner() }
            .store(in: &cancellables)

        // ActivityKit can surface a retained banner after the first launch-time refresh.
        activityObservation = Task { [weak self] in
            for await candidate in Activity<NOOPActivityAttributes>.activityUpdates {
                guard let self else { return }
                if !belongsToWorkout(candidate, startSec: workoutStartSec)
                    || !UnitPrefs.liveActivityEnabled() || !authInfo.areActivitiesEnabled || self.standsAside() {
                    remove(candidate)
                }
                refreshBanner()
            }
        }
    }

    /// NOOP came on screen, the only time iOS lets it start the banner: offered now rather than at the next heart-rate
    /// change, which a strap off the wrist may not bring for a long while. Said by the caller, from the scene phase,
    /// because `applicationState` can still read inactive while the scene turns active.
    func appBecameActive() {
        refreshBanner(appActive: true)
    }

    private func refreshBanner(appActive: Bool? = nil) {
        guard let model else { return }
        let workoutStartSec = self.workoutStartSec
        let connected = model.live.connected
        let switchOn = UnitPrefs.liveActivityEnabled() && authInfo.areActivitiesEnabled
        let appActive = appActive ?? (UIApplication.shared.applicationState == .active)

        // First dispose of stale or legacy activities. A banner is reusable only for the same
        // manual workout, including when that workout has been restored after a relaunch.
        if let activity,
           !Self.isShowing(activity) || removing.contains(activity.id)
            || !belongsToWorkout(activity, startSec: workoutStartSec) {
            if workoutStartSec == nil { log("ending: manual workout finished") }
            remove(activity)
            clearCurrentActivity()
        }
        if activity == nil {
            let listed = Activity<NOOPActivityAttributes>.activities
            for candidate in listed where !belongsToWorkout(candidate, startSec: workoutStartSec) {
                remove(candidate)
            }
            removeLeftovers(listed, beside: nil)
            if let adopted = listed.first(where: {
                belongsToWorkout($0, startSec: workoutStartSec) && Self.isShowing($0) && !removing.contains($0.id)
            }) {
                activity = adopted
                startedAt = (UserDefaults.standard.dictionary(forKey: Self.startedKey)?[adopted.id] as? Double)
                    .map(Date.init(timeIntervalSince1970:))
                log("picked up the one already on the Lock Screen")
            }
        }

        let now = Date()
        let age = startedAt.map { now.timeIntervalSince($0) }
        let step = LiveHRBannerLifecycle.step(
            workoutInProgress: workoutStartSec != nil, switchOn: switchOn, standsAside: standsAside(),
            linkUp: connected, showing: activity != nil, age: age, appActive: appActive)
        switch step {
        case .nothing: return
        case .end:
            if let activity { remove(activity) }
            for candidate in Activity<NOOPActivityAttributes>.activities { remove(candidate) }
            clearCurrentActivity()
            log("ended: workout Live Activity is no longer eligible")
            return
        case .start, .push, .renew: break
        }

        guard let workoutStartSec else { return }
        // #911: use the same memoized daily recovery and effort as the widget and watch.
        let day = model.repo.cachedWidgetAnchor()
        let state = NOOPActivityAttributes.ContentState(
            bpm: connected ? (model.bpm ?? model.live.heartRate) : nil,
            recovery: day?.recovery.map { Int($0.rounded()) }, bonded: connected,
            effort: day?.strain.map { Int($0.rounded()) })

        if step == .renew, activity != nil {
            // The fresh banner first, then the old one goes, so the Lock Screen is never without one; if iOS refuses
            // the fresh one, the old one stays.
            if start(state, workoutStartSec: workoutStartSec, at: now) {
                log("renewed after \(age.map { "\(Int($0 / 60)) min" } ?? "an unknown time"), "
                    + "so iOS's eight-hour limit starts again")
                removeLeftovers(Activity<NOOPActivityAttributes>.activities, beside: activity)
            }
        } else if let activity {
            // The number giving way to the dash (the strap off the wrist, the link dropping) is pushed at once: no
            // tick follows it, so a push skipped for spacing would leave the last number standing.
            guard LiveHRBannerPushPolicy.due(shown: shownState, next: state, reading: \.bpm,
                                             sinceLastPush: now.timeIntervalSince(lastPush),
                                             staleAfter: Self.staleAfter) else { return }
            if let shown = shownState, (shown.bpm == nil) != (state.bpm == nil) { logReading(state) }
            lastPush = now
            shownState = state
            let staleDate = now.addingTimeInterval(Self.staleAfter)
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else if start(state, workoutStartSec: workoutStartSec, at: now) {
            log(state.bpm == nil ? "started, showing – until a heart rate arrives" : "started")
            removeLeftovers(Activity<NOOPActivityAttributes>.activities, beside: activity)
        }
    }

    /// Removes at once each banner in `listed` that `LiveHRBannerLifecycle.removes` says goes: one iOS has ended, which
    /// stays on the Lock Screen frozen on its last number and takes no update, and — once NOOP has started `fresh` —
    /// any other one still showing. Each removal of an ended one leaves a line: it is what a second banner beside the
    /// live one would have been.
    private func removeLeftovers(_ listed: [Activity<NOOPActivityAttributes>],
                                 beside fresh: Activity<NOOPActivityAttributes>?) {
        for act in listed where act.id != fresh?.id {
            let state = Self.listed(act)
            guard LiveHRBannerLifecycle.removes(state, besideFresh: fresh != nil) else { continue }
            remove(act)
        }
    }

    /// Ask iOS for a new banner, which it grants only while NOOP is on screen. Returns whether it did.
    @discardableResult
    private func start(_ state: NOOPActivityAttributes.ContentState, workoutStartSec: Int, at now: Date) -> Bool {
        // Set the start gate SYNCHRONOUSLY before any await so a second `update` arriving on the
        // main actor while `Activity.request` is still in flight bails here instead of issuing a
        // second request. The 2-second throttle above only guards the update path.
        guard !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }
        do {
            let started = try Activity.request(
                attributes: NOOPActivityAttributes(title: String(localized: "Live HR"), workoutStartSec: workoutStartSec),
                content: ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter)),
                pushType: nil
            )
            activity = started
            startedAt = now
            UserDefaults.standard.set([started.id: now.timeIntervalSince1970], forKey: Self.startedKey)
            lastPush = now
            shownState = state
            refusalLogged = false
            return true
        } catch {
            if !refusalLogged {
                refusalLogged = true
                log("iOS did not start it: \(error.localizedDescription)")
            }
            return false
        }
    }

    /// The banner turning to the dash, or back to a number: pushed at once (`LiveHRBannerPushPolicy`), and logged.
    private func logReading(_ state: NOOPActivityAttributes.ContentState) {
        if state.bpm != nil {
            log("heart rate again")
        } else {
            log(state.bonded ? "– (strap connected, no heart rate)" : "– (strap not connected)")
        }
    }

    /// One line in NOOP's strap log for each thing that happens to the banner: started, picked up, renewed, ended,
    /// gone, and each turn to the dash and back. Rare, so always on. A tester's banner once showed the dash for a
    /// strap he was wearing, and a log without a word about the banner could not say why (24 Sep 2026).
    private func log(_ line: String) {
        model?.live.append(log: AppModel.stamped("Live HR banner: " + line))
    }

    /// Still on the Lock Screen and able to take an update: not ended by iOS, the user or NOOP.
    private static func isShowing(_ activity: Activity<NOOPActivityAttributes>) -> Bool {
        listed(activity) == .showing
    }

    /// The banner's state in `LiveHRBannerLifecycle`'s terms. `pending` (a start iOS 26 schedules) never comes from
    /// NOOP, which only starts banners at once, so it counts as gone: not NOOP's to feed or remove.
    private static func listed(_ activity: Activity<NOOPActivityAttributes>) -> LiveHRBannerLifecycle.Listed {
        switch activity.activityState {
        case .active, .stale: return .showing
        case .ended: return .ended
        default: return .gone
        }
    }

    private func belongsToWorkout(_ activity: Activity<NOOPActivityAttributes>, startSec: Int?) -> Bool {
        guard let startSec else { return false }
        return activity.attributes.workoutStartSec == startSec
    }

    private func remove(_ activity: Activity<NOOPActivityAttributes>) {
        guard Self.listed(activity) != .gone, removing.insert(activity.id).inserted else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func clearCurrentActivity() {
        activity = nil
        shownState = nil
        startedAt = nil
    }
}
#endif
