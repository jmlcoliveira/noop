import Foundation

/// Keeps background task registration aligned with the installed app's permitted identifiers.
/// Sideloaders can rewrite CFBundleIdentifier while retaining this Info.plist list unchanged.
enum BackgroundTaskIdentifier {
    static func identifier(_ task: String, bundle: Bundle = .main) -> String {
        resolve(task, permitted: bundle.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? [],
                bundleIdentifier: bundle.bundleIdentifier)
    }

    static func resolve(_ task: String, permitted: [String], bundleIdentifier: String?) -> String {
        let expected = (bundleIdentifier ?? "com.noopapp.noop") + "." + task
        if permitted.contains(expected) { return expected }
        let matching = permitted.filter { $0.hasSuffix("." + task) }.sorted()
        return matching.first ?? expected
    }
}
