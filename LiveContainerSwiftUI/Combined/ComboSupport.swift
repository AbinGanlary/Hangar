//
//  ComboSupport.swift
//  LiveContainer (combined-app fork)
//
//  Defaults and per-app launch memory for the combined app.
//  - Every launch goes to Multitask, full screen, one app on stage.
//  - Multitask apps get access to the whole private Documents folder. Without it, some
//    non-shared apps quit at launch ("App returned from its main function with code 0").
//  - An app that still quits right after a multitask launch is remembered and opens the
//    normal way from then on.
//

import Foundation

enum ComboDefaults {
    /// Bump when a new default should be applied once more to existing installs.
    private static let version = 1
    private static let appliedKey = "LCComboDefaultsVersion"

    static func applyOnce() {
        let std = UserDefaults.standard
        guard std.integer(forKey: appliedKey) < version else { return }
        let group = LCUtils.appGroupUserDefault

        std.set(true, forKey: "LCLaunchInMultitaskMode")
        std.set(true, forKey: "LCLaunchMultitaskMaximized")
        std.set(true, forKey: "LCSharePrivateDataWithLiveProcess")
        group.set(MultitaskMode.virtualWindow.rawValue, forKey: "LCMultitaskMode")
        group.set(true, forKey: "LCMaxOneAppOnStage")

        std.set(version, forKey: appliedKey)
    }
}

@objcMembers
class ComboNavigation: NSObject {
    /// Called when a multitask window is minimised, so the user lands on the home grid.
    static func showHome() {
        DispatchQueue.main.async {
            DataManager.shared.model.selectedTab = .home
        }
    }
}

@objcMembers
class ComboLaunchMemory: NSObject {
    /// How soon after a multitask launch an exit counts as "couldn't run in multitask".
    static let quickExitSeconds: TimeInterval = 8

    private static func key(_ bundleId: String) -> String { "LCComboPreferNormal.\(bundleId)" }

    /// Called from DecoratedAppSceneViewController when a multitask app exits or fails early.
    static func noteQuickExit(bundleId: String) {
        UserDefaults.standard.set(true, forKey: key(bundleId))
        var log = UserDefaults.standard.string(forKey: "LCLabLogD") ?? ""
        log.labAppend("\(bundleId) quit right after a multitask launch, will open normally next time")
        UserDefaults.standard.set(log, forKey: "LCLabLogD")
    }

    static func prefersNormalLaunch(bundleId: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(bundleId))
    }

    static func clear(bundleId: String) {
        UserDefaults.standard.removeObject(forKey: key(bundleId))
    }
}
