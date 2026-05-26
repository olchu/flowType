import Foundation

final class SettingsStorageService {
    private let defaults: UserDefaults
    private let key = "appSettings"
    private let onboardingCompletedKey = "hasCompletedOnboarding"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard
            let data = defaults.data(forKey: key),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }

        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }

    func hasCompletedOnboarding() -> Bool {
        defaults.bool(forKey: onboardingCompletedKey)
    }

    func setOnboardingCompleted(_ isCompleted: Bool) {
        defaults.set(isCompleted, forKey: onboardingCompletedKey)
    }
}
