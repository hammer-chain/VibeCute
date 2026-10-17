import Foundation

/// Permission requests can terminate the app; persist their window until explicit continuation.
struct OnboardingProgress {
    enum Step: String { case greeting, permissions, interaction, feedback, connection, farewell, complete }
    static let version = 1
    static func prepare(_ defaults: UserDefaults) {
        guard defaults.object(forKey: "onboardingVersion") == nil else { return }
        let existing = ["trackedHarnesses", "companionEnabled", "characterBindings", "fontSize", "audioEnabled", "selection"]
            .contains { defaults.object(forKey: $0) != nil }
        defaults.set(version, forKey: "onboardingVersion")
        defaults.set(existing ? Step.complete.rawValue : Step.greeting.rawValue, forKey: "onboardingStep")
        guard !existing else { return }
        defaults.set(true, forKey: "companionEnabled")
        defaults.set("deepseek", forKey: "companionCharacter")
        defaults.set([String](), forKey: "trackedHarnesses")
        defaults.set(true, forKey: "claudeTrackingMigrated")
        defaults.set(true, forKey: "doubaoTrackingMigrated")
        for key in ["audioEnabled", "autoAvoidanceEnabled", "autoWindowPeekEnabled", "speechKeywordEnabled"] {
            defaults.set(false, forKey: key)
        }
    }
    private static let permissionResumeKey = "onboardingPermissionResume"
    static func permissionReplay(_ defaults: UserDefaults) -> Bool? {
        (defaults.dictionary(forKey: permissionResumeKey) as? [String: Bool])?["replay"]
    }
    static func checkpointPermissions(_ defaults: UserDefaults, replay: Bool) {
        defaults.set(["replay": replay], forKey: permissionResumeKey)
        // A system permission dialog may quit us immediately after this call.
        defaults.synchronize()
    }
    static func clearPermissionResume(_ defaults: UserDefaults) {
        guard defaults.object(forKey: permissionResumeKey) != nil else { return }
        defaults.removeObject(forKey: permissionResumeKey)
        defaults.synchronize()
    }
    static func step(_ defaults: UserDefaults) -> Step {
        Step(rawValue: defaults.string(forKey: "onboardingStep") ?? "") ?? .complete
    }
}
