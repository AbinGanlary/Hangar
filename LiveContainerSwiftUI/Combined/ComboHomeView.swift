//
//  ComboHomeView.swift
//  LiveContainer (combined-app fork)
//
//  The app's own home screen: a grid of container apps only. One tap runs the app
//  (multitask, full screen). Running apps get a dot under their name, and tapping a running
//  app brings its window back. Touch and hold for more options.
//

import SwiftUI

struct ComboHomeView: View {
    @EnvironmentObject var sharedModel: SharedModel
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    @State private var runningContainers: Set<String> = []
    @State private var errorText: String?
    @State private var safariOpened = false
    @State private var safariURL = URL(string: "https://example.com")!
    @State private var fixApp: LCAppModel? // a private app that quit in multitask
    @State private var nativeApp: LCAppModel? // "Install natively…" asked for this app
    @State private var choosingIPA = false
    @State private var settingsApp: LCAppModel?   // App settings sheet
    @State private var renameApp: LCAppModel?     // Rename alert
    @State private var renameText = ""
    @State private var deleteApp: LCAppModel?     // Delete confirmation

    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let columns = [GridItem(.adaptive(minimum: 74, maximum: 96), spacing: 14, alignment: .top)]

    private var apps: [LCAppModel] {
        sharedModel.apps.filter { !$0.appInfo.isHidden }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                if apps.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(apps, id: \.self) { app in
                            appIcon(app)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .background(homeBackground.ignoresSafeArea())
            .navigationTitle("Home")
        }
        .navigationViewStyle(.stack)
        .onReceive(refresh) { _ in updateRunning() }
        .onAppear { updateRunning() }
        .alert("Couldn't open app", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .fullScreenCover(isPresented: $safariOpened) {
            SafariView(url: $safariURL)
        }
        .sheet(item: Binding(get: { settingsApp.map(IdentifiedApp.init) }, set: { settingsApp = $0?.app })) { item in
            NavigationView {
                LCAppSettingsView(model: item.app)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { settingsApp = nil }
                        }
                    }
            }
            .navigationViewStyle(.stack)
            .environmentObject(sharedModel)
        }
        .alert("Rename", isPresented: Binding(get: { renameApp != nil }, set: { if !$0 { renameApp = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let app = renameApp { ComboNames.setName(renameText, for: app) }
                renameApp = nil
            }
            Button("Reset to original") {
                if let app = renameApp { ComboNames.setName("", for: app) }
                renameApp = nil
            }
            Button("Cancel", role: .cancel) { renameApp = nil }
        } message: {
            Text("Only changes the name shown in Hangar.")
        }
        .confirmationDialog(
            "Delete \(deleteApp.map { ComboNames.name(for: $0) } ?? "app")?",
            isPresented: Binding(get: { deleteApp != nil }, set: { if !$0 { deleteApp = nil } }),
            titleVisibility: .visible
        ) {
            if let app = deleteApp {
                Button("Delete app and its data", role: .destructive) { delete(app, removeData: true) }
                Button("Delete app, keep its data") { delete(app, removeData: false) }
            }
            Button("Cancel", role: .cancel) { deleteApp = nil }
        } message: {
            Text("Deleting its data removes saves and sign-ins and can't be undone. Kept data is used again if you reinstall the same app.")
        }
        .confirmationDialog(
            "\(fixApp?.displayName ?? "This app") quit when opened next to other apps",
            isPresented: Binding(get: { fixApp != nil }, set: { if !$0 { fixApp = nil } }),
            titleVisibility: .visible
        ) {
            if let app = fixApp {
                Button("Make it a Shared App and open") { makeSharedAndOpen(app) }
                Button("Open the normal way") { open(app, multitask: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shared Apps run next to other apps. Its data moves with it. \"The normal way\" closes other running apps.")
        }
        .alert("Install \(nativeApp?.displayName ?? "app") natively", isPresented: Binding(get: { nativeApp != nil && !choosingIPA }, set: { if !$0 { nativeApp = nil } })) {
            Button("Choose IPA file") { choosingIPA = true }
            Button("Cancel", role: .cancel) { nativeApp = nil }
        } message: {
            Text("Pick this app's original IPA file. Hangar installs it as a real app: it uses 1 of your 3 slots and 1 App ID this week. The container copy and its data stay as they are.")
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { urls in
            nativeApp = nil
            guard let url = urls.first else { return }
            // Home has no extensions dialog: share the app's ID so no extra App IDs are used.
            let choice = NativeInstallCenter.extensionCount(in: url) > 0 ? "use-main-profile" : nil
            NativeInstallCenter.shared.install(url, extensionChoice: choice)
        }, onDismiss: {
            choosingIPA = false
            nativeApp = nil
        })
    }

    // MARK: pieces

    private var homeBackground: some View {
        LinearGradient(colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)
            Text("No apps yet").font(.headline)
            Text("Add IPA files in Library. They show up here, ready to tap.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Go to Library") { sharedModel.selectedTab = .library }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func appIcon(_ app: LCAppModel) -> some View {
        let running = isRunning(app)
        return Button {
            open(app, multitask: nil)
        } label: {
            VStack(spacing: 6) {
                Image(uiImage: app.appInfo.iconIsDarkIcon(darkModeIcon) ?? UIImage())
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 62, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
                Text(ComboNames.name(for: app))
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 80)
                Circle()
                    .fill(running ? Color.accentColor : Color.clear)
                    .frame(width: 5, height: 5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(running ? "\(ComboNames.name(for: app)), running" : ComboNames.name(for: app))
        .contextMenu {
            Button {
                open(app, multitask: nil)
            } label: {
                Label(running ? "Show" : "Open", systemImage: "play.fill")
            }
            Button {
                open(app, multitask: false)
            } label: {
                Label("Open the normal way", systemImage: "arrow.up.forward.app")
            }
            if let rel = app.appInfo.relativeBundlePath, ComboLaunchMemory.prefersNormalLaunch(bundleId: rel) {
                Button {
                    ComboLaunchMemory.clear(bundleId: rel)
                } label: {
                    Label("Try multitask again", systemImage: "rectangle.on.rectangle")
                }
            }
            Button {
                addToHomeScreen(app)
            } label: {
                Label("Add to Home Screen", systemImage: "plus.app")
            }
            if UserDefaults.sideStoreExist() {
                Button {
                    nativeApp = app
                } label: {
                    Label("Install natively…", systemImage: "iphone.badge.play")
                }
            }
            Divider()
            Button {
                renameText = ComboNames.name(for: app)
                renameApp = app
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                settingsApp = app
            } label: {
                Label("App settings", systemImage: "gearshape")
            }
            Button(role: .destructive) {
                deleteApp = app
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(running)
        }
    }

    // MARK: actions

    private func isRunning(_ app: LCAppModel) -> Bool {
        guard let folder = app.uiSelectedContainer?.folderName else { return false }
        return runningContainers.contains(folder)
    }

    private func updateRunning() {
        var set: Set<String> = []
        for app in apps {
            for container in app.uiContainers where MultitaskManager.isUsing(container: container.folderName) {
                set.insert(container.folderName)
            }
        }
        if set != runningContainers { runningContainers = set }
    }

    private func launchURL(_ app: LCAppModel) -> URL? {
        guard let rel = app.appInfo.relativeBundlePath else { return nil }
        var c = URLComponents()
        c.scheme = "livecontainer"
        c.host = "livecontainer-launch"
        var items = [URLQueryItem(name: "bundle-name", value: rel)]
        if let folder = app.uiSelectedContainer?.folderName {
            items.append(URLQueryItem(name: "container-folder-name", value: folder))
        }
        c.queryItems = items
        return c.url
    }

    private func open(_ app: LCAppModel, multitask: Bool?) {
        // Locked apps and apps that need JIT go through the Apps list, which owns Face ID and the JIT flow.
        if app.appInfo.isLocked || app.appInfo.isJITNeeded {
            if let url = launchURL(app) {
                // handled by the hidden app list behind Home (Face ID and JIT live there)
                sharedModel.selectedTab = .home
                sharedModel.deepLink = url
            }
            return
        }
        if multitask == nil, !app.uiIsShared, let rel = app.appInfo.relativeBundlePath,
           ComboLaunchMemory.hadQuickExit(bundleId: rel) {
            fixApp = app
            return
        }
        Task {
            do {
                try await app.runApp(multitask: multitask)
            } catch {
                await MainActor.run { errorText = error.localizedDescription }
            }
        }
    }

    private func makeSharedAndOpen(_ app: LCAppModel) {
        do {
            try ComboSharing.makeShared(app, sharedModel: sharedModel)
        } catch {
            errorText = error.localizedDescription
            return
        }
        Task {
            do {
                try await app.runApp(multitask: true)
            } catch {
                await MainActor.run { errorText = error.localizedDescription }
            }
        }
    }

    /// Same steps as the old Apps list's Uninstall (LCAppBannerViewController.uninstall), without its alerts.
    private func delete(_ app: LCAppModel, removeData: Bool) {
        deleteApp = nil
        let appInfo = app.appInfo
        let containers = appInfo.containers
        do {
            guard let bundlePath = appInfo.bundlePath() else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.removeItem(atPath: bundlePath)
            sharedModel.apps.removeAll { $0 == app }
            sharedModel.hiddenApps.removeAll { $0 == app }
            if removeData {
                for container in containers {
                    let base = container.isShared ? LCPath.lcGroupDataPath : LCPath.dataPath
                    try? FileManager.default.removeItem(at: base.appendingPathComponent(container.folderName))
                    LCUtils.removeAppKeychain(dataUUID: container.folderName)
                    sharedModel.appDataFolderNames.removeAll { $0 == container.folderName }
                }
            }
            ComboNames.setName("", for: app)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func addToHomeScreen(_ app: LCAppModel) {
        guard let profile = app.appInfo.generateWebClipConfig(withContainerId: app.uiSelectedContainer?.folderName, iconStyle: .Original),
              let data = try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0) else {
            errorText = "Couldn't make the home-screen icon."
            return
        }
        safariURL = URL(string: "data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariOpened = true
    }
}

/// Wraps an app model for `.sheet(item:)`.
struct IdentifiedApp: Identifiable {
    let app: LCAppModel
    var id: ObjectIdentifier { ObjectIdentifier(app) }
}

/// Hangar-only display names for container apps (Rename on Home). Stored per app bundle folder.
enum ComboNames {
    private static func key(_ app: LCAppModel) -> String? {
        app.appInfo.relativeBundlePath.map { "HangarName.\($0)" }
    }

    static func name(for app: LCAppModel) -> String {
        if let key = key(app), let custom = LCUtils.appGroupUserDefault.string(forKey: key), !custom.isEmpty {
            return custom
        }
        return app.displayName
    }

    static func setName(_ name: String, for app: LCAppModel) {
        guard let key = key(app) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == app.displayName {
            LCUtils.appGroupUserDefault.removeObject(forKey: key)
        } else {
            LCUtils.appGroupUserDefault.set(trimmed, forKey: key)
        }
        app.objectWillChange.send()
    }
}
