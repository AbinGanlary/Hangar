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
    /// How soon after a multitask launch a plain exit counts as "couldn't run in multitask".
    static let quickExitSeconds: TimeInterval = 8
    /// A launch error (the app's main returned, or it crashed) counts within this window.
    static let quickErrorSeconds: TimeInterval = 30

    private static func key(_ bundleId: String) -> String { "LCComboPreferNormal.\(bundleId)" }

    /// Called from DecoratedAppSceneViewController when a multitask app exits or fails early.
    static func noteQuickExit(bundleId: String) {
        UserDefaults.standard.set(true, forKey: key(bundleId))
    }

    /// True after a quick exit. Private apps are offered "make shared" by the Home screen
    /// (Shared Apps run in multitask where private ones may not); shared apps fall back to a normal launch.
    static func hadQuickExit(bundleId: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(bundleId))
    }

    static func prefersNormalLaunch(bundleId: String) -> Bool {
        hadQuickExit(bundleId: bundleId)
    }

    static func clear(bundleId: String) {
        UserDefaults.standard.removeObject(forKey: key(bundleId))
    }
}

enum ComboSharing {
    enum Failure: LocalizedError {
        case runningElsewhere(String)
        var errorDescription: String? {
            switch self {
            case .runningElsewhere(let lc): return "Close the app in \(lc) first."
            }
        }
    }

    /// Same steps as App Settings → Convert to Shared App (LCAppSettingsView.moveToAppGroup),
    /// without its confirmation alert: move the bundle, its data containers and its tweak folder
    /// into the shared app group.
    @MainActor
    static func makeShared(_ model: LCAppModel, sharedModel: SharedModel) throws {
        let appInfo = model.appInfo
        guard !appInfo.isShared, let rel = appInfo.relativeBundlePath, let bundlePath = appInfo.bundlePath() else { return }
        for container in appInfo.containers {
            if let runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
                throw Failure.runningElsewhere(runningLC)
            }
        }
        try LCPath.ensureAppGroupPaths()

        var moves: [(URL, URL)] = [(URL(fileURLWithPath: bundlePath), LCPath.lcGroupBundlePath.appendingPathComponent(rel))]
        for container in model.uiContainers where container.storageBookMark == nil {
            moves.append((LCPath.dataPath.appendingPathComponent(container.folderName),
                          LCPath.lcGroupDataPath.appendingPathComponent(container.folderName)))
        }
        if let tweakFolder = appInfo.tweakFolder, !tweakFolder.isEmpty {
            moves.append((LCPath.tweakPath.appendingPathComponent(tweakFolder),
                          LCPath.lcGroupTweakPath.appendingPathComponent(tweakFolder)))
        }
        try LCUtils.moveFilesAtomicallyAfterPreflight(moves)

        for container in model.uiContainers where container.storageBookMark == nil {
            sharedModel.appDataFolderNames.removeAll { $0 == container.folderName }
            container.isShared = true
        }
        if let tweakFolder = appInfo.tweakFolder, !tweakFolder.isEmpty {
            sharedModel.tweakFolderNames.removeAll { $0 == tweakFolder }
        }
        appInfo.setBundlePath(LCPath.lcGroupBundlePath.appendingPathComponent(rel).path)
        appInfo.isShared = true
        model.uiIsShared = true
        ComboLaunchMemory.clear(bundleId: rel)
    }
}

@objcMembers
class ComboSettings: NSObject {
    static let pauseHiddenKey = "LCComboPauseHidden"
    static let overlayKey = "LCLabHUD" // read by TweakLoader/LabHUD.m inside apps

    /// Hidden multitask apps go to the background (games pause). On unless turned off in Library.
    static var pauseHiddenApps: Bool {
        LCUtils.appGroupUserDefault.object(forKey: pauseHiddenKey) as? Bool ?? true
    }
}

enum ComboNativeInstall {
    /// Copies an IPA into LiveContainer and hands it to built-in SideStore, which shows its install screen.
    /// Installing natively uses one of the free account's 3 app slots and one App ID.
    static func handOver(_ picked: URL) throws {
        let accessing = picked.startAccessingSecurityScopedResource()
        defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
        let inbox = LCPath.docPath.appendingPathComponent("LabInbox", isDirectory: true)
        let dest = inbox.appendingPathComponent(picked.lastPathComponent)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: picked, to: dest)
        LCUtils.openSideStore(urlStr: dest.absoluteString)
    }

    /// Copies a picked IPA somewhere LiveContainer can read later, for a container install via the Apps tab.
    static func stageForContainer(_ picked: URL) throws -> URL {
        let accessing = picked.startAccessingSecurityScopedResource()
        defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ComboInstall", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(picked.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: picked, to: dest)
        return dest
    }
}
