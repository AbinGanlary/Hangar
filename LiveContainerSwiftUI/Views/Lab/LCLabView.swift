//
//  LCLabView.swift
//  LiveContainer (combined-app fork)
//
//  Phase 1 test tab. Each section answers one question on a real phone:
//  A native install through built-in SideStore, B reading SideStore's app list,
//  C home-screen icons, D several apps at once, E games (overlay, 120 Hz, controllers).
//  "Copy report" puts every result on the clipboard so it can be pasted back.
//

import SwiftUI
import os
import GameController
import UniformTypeIdentifiers

// MARK: - SideStore's widget snapshot (same shape as SideStore/Widget/WidgetData/WidgetModels.swift)

struct LabSideStoreApp: Codable, Identifiable {
    var name: String
    var bundleIdentifier: String
    var expirationDate: Date
    var refreshedDate: Date
    var tintColorHex: String?
    var id: String { bundleIdentifier }
}

struct LabSideStoreSnapshot: Codable {
    var activeApps: [LabSideStoreApp]
    var allApps: [LabSideStoreApp]
    var lastUpdated: Date
}

enum LabSideStoreReader {
    static let fileName = "widget_data.json"

    /// Places SideStore may have written widget_data.json to when it runs inside LiveContainer.
    /// The hooks map its app group to LiveContainer's own, but that can be missing after re-signing.
    static func candidateFolders() -> [URL] {
        var folders: [URL] = []
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LCSharedUtils.appGroupID()) {
            folders.append(group)
        }
        let doc = LCPath.docPath
        folders.append(doc.appendingPathComponent("SideStore"))
        folders.append(doc.appendingPathComponent("Data/AppGroup/group.com.SideStore.SideStore"))
        folders.append(doc.appendingPathComponent("Data/AppGroup/\(LCSharedUtils.appGroupID())"))
        return folders
    }

    static func find() -> (URL?, [String]) {
        var log: [String] = []
        let fm = FileManager.default
        for folder in candidateFolders() {
            let direct = folder.appendingPathComponent(fileName)
            if fm.fileExists(atPath: direct.path) {
                log.append("found: \(direct.path)")
                return (direct, log)
            }
            log.append("not at: \(direct.path)")
        }
        // Last resort: a shallow search under SideStore's home and the app group.
        for folder in candidateFolders() {
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { continue }
            var checked = 0
            for case let url as URL in e {
                checked += 1
                if checked > 4000 { break }
                if e.level > 5 { e.skipDescendants(); continue }
                if url.lastPathComponent == fileName {
                    log.append("found by search: \(url.path)")
                    return (url, log)
                }
            }
        }
        log.append("widget_data.json not found anywhere. Open SideStore once and tap Refresh All, then reload.")
        return (nil, log)
    }

    static func load() -> (LabSideStoreSnapshot?, URL?, [String]) {
        let (url, log) = find()
        guard let url else { return (nil, nil, log) }
        do {
            let snap = try JSONDecoder().decode(LabSideStoreSnapshot.self, from: Data(contentsOf: url))
            return (snap, url, log + ["decoded: \(snap.activeApps.count) active, \(snap.allApps.count) total, updated \(snap.lastUpdated)"])
        } catch {
            return (nil, url, log + ["decode error: \(error)"])
        }
    }
}

// MARK: - Saved log lines (survive LiveContainer relaunching after a normal app launch)

extension String {
    var labLines: [String] { isEmpty ? [] : components(separatedBy: "\n") }
    mutating func labAppend(_ line: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        var lines = labLines
        lines.append("\(f.string(from: Date())) \(line)")
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        self = lines.joined(separator: "\n")
    }
}

enum LabLog {
    /// Called from LCAppModel.runApp for every launch, from any tab.
    static func launch(_ name: String, multitask: Bool) {
        var log = UserDefaults.standard.string(forKey: "LCLabLogD") ?? ""
        log.labAppend("launch \(name) as \(multitask ? "multitask" : "normal (LiveContainer becomes the app)")")
        UserDefaults.standard.set(log, forKey: "LCLabLogD")
        UserDefaults.standard.synchronize() // a normal launch replaces this process right after

    }
}

// MARK: - View

struct LCLabView: View {
    @EnvironmentObject var sharedModel: SharedModel

    // A
    @State private var choosingIPA = false
    @AppStorage("LCLabLogA") private var nativeInstallLog: String = ""

    // B
    @State private var snapshot: LabSideStoreSnapshot?
    @State private var snapshotURL: URL?
    @State private var snapshotLog: [String] = []

    // C
    @State private var safariOpened = false
    @State private var safariURL = URL(string: "https://example.com")!
    @AppStorage("LCLabLogC") private var iconLog: String = ""

    // D
    @AppStorage("LCLaunchInMultitaskMode") private var launchInMultitask = false
    @AppStorage("LCLaunchMultitaskMaximized") private var launchMaximized = false
    @AppStorage("LCMaxOneAppOnStage", store: LCUtils.appGroupUserDefault) private var oneAppOnStage = false
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) private var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCLabLogD") private var runLog: String = ""

    // E
    @AppStorage("LCLabHUD", store: LCUtils.appGroupUserDefault) private var showHUD = false

    @State private var copied = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("Phase 1 test build. Try each section, then tap Copy report and paste it back in the chat.")
                        .font(.footnote)
                    Button(copied ? "Copied ✓" : "Copy report") {
                        UIPasteboard.general.string = report()
                        copied = true
                    }
                    Button("Clear logs", role: .destructive) {
                        nativeInstallLog = ""; iconLog = ""; runLog = ""
                        LCUtils.appGroupUserDefault.removeObject(forKey: "LCLabHUDReports")
                        copied = false
                    }
                }

                nativeInstallSection
                sideStoreListSection
                homeScreenSection
                multitaskSection
                gameSection
            }
            .navigationTitle("Lab")
        }
        .navigationViewStyle(.stack)
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { urls in
            if let url = urls.first { handOverToSideStore(url) }
        }, onDismiss: {
            choosingIPA = false
        })
        .fullScreenCover(isPresented: $safariOpened) {
            SafariView(url: $safariURL)
        }
        .onAppear { reloadSnapshot() }
    }

    // MARK: A — native install

    private var nativeInstallSection: some View {
        Section {
            Button("Pick an IPA and install natively") { choosingIPA = true }
                .disabled(!UserDefaults.sideStoreExist())
            if !UserDefaults.sideStoreExist() {
                Text("Built-in SideStore not found in this build.").foregroundColor(.red).font(.footnote)
            }
            logView(nativeInstallLog.labLines)
        } header: {
            Text("A · Native install via built-in SideStore")
        } footer: {
            Text("Copies the IPA into LiveContainer, then opens built-in SideStore with it. Pass = SideStore shows its install screen for that app. This uses one of your 3 slots and one App ID, so pick an app you're fine installing.")
        }
    }

    private func handOverToSideStore(_ picked: URL) {
        let accessing = picked.startAccessingSecurityScopedResource()
        defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
        let inbox = LCPath.docPath.appendingPathComponent("LabInbox", isDirectory: true)
        let dest = inbox.appendingPathComponent(picked.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: picked, to: dest)
            nativeInstallLog.labAppend("copied to \(dest.path)")
        } catch {
            nativeInstallLog.labAppend("copy failed: \(error.localizedDescription)")
            return
        }
        nativeInstallLog.labAppend("opening SideStore with file URL")
        LCUtils.openSideStore(urlStr: dest.absoluteString)
    }

    // MARK: B — SideStore's list of native apps

    private var sideStoreListSection: some View {
        Section {
            if let snapshot {
                ForEach(snapshot.allApps) { app in
                    HStack(spacing: 12) {
                        nativeIcon(for: app)
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.bundleIdentifier).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(daysLeft(app.expirationDate)).font(.caption.monospacedDigit())
                            .foregroundColor(snapshot.activeApps.contains { $0.bundleIdentifier == app.bundleIdentifier } ? .primary : .secondary)
                    }
                }
            }
            Button("Reload") { reloadSnapshot() }
            logView(snapshotLog)
        } header: {
            Text("B · Native apps (read from SideStore)")
        } footer: {
            Text("Pass = this lists the same apps and days left as SideStore's My Apps screen.")
        }
    }

    private func reloadSnapshot() {
        let (snap, url, log) = LabSideStoreReader.load()
        snapshot = snap
        snapshotURL = url
        snapshotLog = log
    }

    private func nativeIcon(for app: LabSideStoreApp) -> some View {
        let iconURL = snapshotURL?.deletingLastPathComponent()
            .appendingPathComponent("WidgetIcons/\(app.bundleIdentifier).png")
        let image = iconURL.flatMap { UIImage(contentsOfFile: $0.path) }
        return Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.3))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func daysLeft(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        return days <= 0 ? "expired" : "\(days)d"
    }

    // MARK: C — home-screen icons

    private var homeScreenSection: some View {
        Section {
            ForEach(sharedModel.apps, id: \.self) { app in
                HStack(spacing: 12) {
                    Image(uiImage: app.appInfo.iconIsDarkIcon(false) ?? UIImage())
                        .resizable().frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(app.displayName).lineLimit(1)
                    Spacer()
                    Button("Profile") { makeIconProfile(app) }
                        .buttonStyle(.bordered)
                    Button("Link") { copyLaunchLink(app) }
                        .buttonStyle(.bordered)
                }
            }
            logView(iconLog.labLines)
        } header: {
            Text("C · Home-screen icon")
        } footer: {
            Text("Profile = one-tap icon via a settings profile (approve it in Settings → Profile Downloaded). Link = copy the launch link for the Shortcuts method. Pass = the icon opens straight into the app. Note whether it opens LiveContainer's list first, and whether it shows up in the app switcher.")
        }
    }

    private func makeIconProfile(_ app: LCAppModel) {
        guard let profile = app.appInfo.generateWebClipConfig(withContainerId: app.uiSelectedContainer?.folderName, iconStyle: .Original),
              let data = try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0) else {
            iconLog.labAppend("\(app.displayName): profile generation failed")
            return
        }
        iconLog.labAppend("\(app.displayName): profile made (\(data.count) bytes), opening Safari")
        safariURL = URL(string: "data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariOpened = true
    }

    private func launchLink(_ app: LCAppModel) -> String? {
        guard let rel = app.appInfo.relativeBundlePath else { return nil }
        var s = "livecontainer://livecontainer-launch?bundle-name=\(rel)"
        if let folder = app.uiSelectedContainer?.folderName { s += "&container-folder-name=\(folder)" }
        return s
    }

    private func copyLaunchLink(_ app: LCAppModel) {
        guard let link = launchLink(app) else { return }
        UIPasteboard.general.string = link
        iconLog.labAppend("\(app.displayName): link copied")
    }

    // MARK: D — several apps at once

    private var liveProcessInstalled: Bool {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var multitaskSection: some View {
        Section {
            row("Helper process (LiveProcess)", liveProcessInstalled ? "installed" : "MISSING – reinstall with Keep App Extensions")
            Button("Apply game preset") {
                multitaskMode = .virtualWindow
                launchInMultitask = true
                launchMaximized = true
                oneAppOnStage = true
                runLog.labAppend("preset on: multitask launch, maximized, one app on stage")
            }
            Toggle("Every launch uses Multitask", isOn: $launchInMultitask)
            Toggle("Open full screen", isOn: $launchMaximized)
            Toggle("One app on stage", isOn: $oneAppOnStage)
            ForEach(sharedModel.apps, id: \.self) { app in
                HStack {
                    Text(app.displayName).lineLimit(1)
                    Spacer()
                    Button("Run") { run(app) }.buttonStyle(.borderedProminent)
                }
            }
            logView(runLog.labLines)
        } header: {
            Text("D · Several apps at once")
        } footer: {
            Text("Apply the preset, run one app, minimise it to the dock, run a second. Pass = both keep running and switching back resumes the first one where you left it. Try it with your heaviest game plus one other app.")
        }
    }

    private func run(_ app: LCAppModel) {
        runLog.labAppend("run \(app.displayName) (multitask)")
        Task {
            do {
                try await app.runApp(multitask: true)
            } catch {
                await MainActor.run { runLog.labAppend("\(app.displayName): \(error.localizedDescription)") }
            }
        }
    }

    // MARK: E — games

    private var gameSection: some View {
        Section {
            Toggle("Show overlay in apps (FPS, memory, controllers)", isOn: $showHUD)
            row("Screen max FPS", "\(UIScreen.main.maximumFramesPerSecond)")
            row("Controllers connected", "\(GCController.controllers().count)")
            row("App category", (Bundle.main.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String) ?? "-")
            row("Game Mode key", (Bundle.main.object(forInfoDictionaryKey: "LSSupportsGameMode") as? Bool) == true ? "on" : "off")
            row("Free memory (this screen)", "\(os_proc_available_memory() / 1_048_576) MB")
            row("Device RAM", "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        } header: {
            Text("E · Games")
        } footer: {
            Text("Turn the overlay on, then run a game (both normally and with Run above). Note the FPS and free memory it shows in each case, whether a controller works, and whether the Game Mode banner appears.")
        }
    }

    // MARK: helpers

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func logView(_ lines: [String]) -> some View {
        if !lines.isEmpty {
            Text(lines.joined(separator: "\n"))
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }

    private func report() -> String {
        var r: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        r.append("LiveContainer \(info["CFBundleShortVersionString"] ?? "?") (combined fork, lab 2), iOS \(UIDevice.current.systemVersion)")
        r.append("== A native install"); r += nativeInstallLog.labLines
        r.append("== B SideStore list"); r += snapshotLog
        for app in snapshot?.allApps ?? [] { r.append("  \(app.name) \(app.bundleIdentifier) \(daysLeft(app.expirationDate))") }
        r.append("== C icons"); r += iconLog.labLines
        r.append("== D multitask: LiveProcess=\(liveProcessInstalled) launchMT=\(launchInMultitask) max=\(launchMaximized) oneOnStage=\(oneAppOnStage)"); r += runLog.labLines
        r.append("== E games: maxFPS=\(UIScreen.main.maximumFramesPerSecond) controllers=\(GCController.controllers().count) hud=\(showHUD) category=\(info["LSApplicationCategoryType"] ?? "-") gameMode=\(info["LSSupportsGameMode"] ?? "-") freeMB=\(os_proc_available_memory() / 1_048_576)")
        if let lines = LCUtils.appGroupUserDefault.stringArray(forKey: "LCLabHUDReports") {
            r.append("== overlay reports from apps"); r += lines
        }
        return r.joined(separator: "\n")
    }
}
