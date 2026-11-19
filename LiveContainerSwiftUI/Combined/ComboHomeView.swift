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
            Text("Add IPA files in the Apps tab. They show up here, ready to tap.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Go to Apps") { sharedModel.selectedTab = .apps }
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
                Text(app.displayName)
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
        .accessibilityLabel(running ? "\(app.displayName), running" : app.displayName)
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
            Button {
                sharedModel.selectedTab = .apps
            } label: {
                Label("Show in Apps list", systemImage: "list.bullet")
            }
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
                sharedModel.selectedTab = .apps
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
