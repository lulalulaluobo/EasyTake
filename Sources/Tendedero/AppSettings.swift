import Foundation

enum AppSettings {
    static let defaults = UserDefaults(suiteName: "local.suiqu.app")!
    static let dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Suiqu", isDirectory: true)

    static var revealDelay: TimeInterval {
        get {
            guard defaults.object(forKey: "revealDelay") != nil else { return 0.5 }
            return min(2, max(0.2, defaults.double(forKey: "revealDelay")))
        }
        set { defaults.set(newValue, forKey: "revealDelay") }
    }
}
