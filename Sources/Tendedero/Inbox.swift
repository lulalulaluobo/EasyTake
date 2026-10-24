import Foundation

/// Direct hanging only changes the floating thumbnail. Screenshot locations and targets remain the user's own.
enum Inbox {
    private static let domain = "com.apple.screencapture" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString
    private static let savedKey = "screenshotThumbnailBackup"
    static let folder = AppSettings.dataDirectory.appendingPathComponent("Clipboard", isDirectory: true)

    static var isEnabled: Bool {
        get { AppSettings.defaults.bool(forKey: "directScreenshots") }
        set { AppSettings.defaults.set(newValue, forKey: "directScreenshots") }
    }

    static var hasPendingRestore: Bool { AppSettings.defaults.dictionary(forKey: savedKey) != nil }

    static func apply() {
        CFPreferencesAppSynchronize(domain)
        let current = CFPreferencesCopyAppValue(thumbnailKey, domain) as? Bool
        if hasPendingRestore {
            // A user change made after our write relinquishes ownership of the setting.
            if current != false { AppSettings.defaults.removeObject(forKey: savedKey); isEnabled = false }
            return
        }
        // Already disabled: we don't own it and must not restore it on exit.
        guard current != false else { return }
        var saved: [String: Any] = ["hadValue": current != nil]
        if let current { saved["value"] = current }
        AppSettings.defaults.set(saved, forKey: savedKey)
        CFPreferencesSetAppValue(thumbnailKey, false as CFPropertyList, domain)
        CFPreferencesAppSynchronize(domain)
    }

    static func restore() {
        guard let saved = AppSettings.defaults.dictionary(forKey: savedKey) else { return }
        CFPreferencesAppSynchronize(domain)
        if (CFPreferencesCopyAppValue(thumbnailKey, domain) as? Bool) == false {
            let value = saved["hadValue"] as? Bool == true ? saved["value"] as? Bool : nil
            CFPreferencesSetAppValue(thumbnailKey, value as CFPropertyList?, domain)
            CFPreferencesAppSynchronize(domain)
        }
        AppSettings.defaults.removeObject(forKey: savedKey)
    }
}
