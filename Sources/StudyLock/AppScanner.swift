import AppKit
import Foundation

enum AppScanner {
    static func installedApps() -> [InstalledApp] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]

        var appsByID: [String: InstalledApp] = [:]
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else {
                    continue
                }
                enumerator.skipDescendants()

                guard let bundle = Bundle(url: url) else {
                    continue
                }
                let displayName =
                    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent

                guard let key = AppIdentity.key(
                    bundleIdentifier: bundle.bundleIdentifier,
                    bundleURL: url
                ) else {
                    continue
                }

                let app = InstalledApp(
                    id: key,
                    name: displayName,
                    bundleIdentifier: bundle.bundleIdentifier,
                    url: url
                )
                appsByID[key] = appsByID[key] ?? app
            }
        }

        return appsByID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
