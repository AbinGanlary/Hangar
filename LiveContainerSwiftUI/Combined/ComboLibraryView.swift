//
//  ComboLibraryView.swift
//  LiveContainer (combined-app fork)
//
//  One place for both kinds of app:
//  - Native apps, signed by built-in SideStore: days left, slots used (free Apple ID = 3).
//  - Install an IPA either into the container (unlimited) or natively (uses a slot).
//  - Settings for the combined app: pause hidden apps, game overlay.
//

import SwiftUI

struct ComboLibraryView: View {
    @EnvironmentObject var sharedModel: SharedModel

    @State private var snapshot: LabSideStoreSnapshot?
    @State private var snapshotURL: URL?

    @State private var choosingIPA = false
    @State private var pickedIPA: URL?
    @State private var errorText: String?

    @AppStorage(ComboSettings.pauseHiddenKey, store: LCUtils.appGroupUserDefault) private var pauseHidden = true
    @AppStorage(ComboSettings.overlayKey, store: LCUtils.appGroupUserDefault) private var showOverlay = false

    /// A free Apple ID can keep 3 sideloaded apps active at once.
    private let slotLimit = 3

    private var activeCount: Int { snapshot?.activeApps.count ?? 0 }
    private var slotsFull: Bool { activeCount >= slotLimit }

    var body: some View {
        NavigationView {
            List {
                installSection
                nativeSection
                containerSection
                settingsSection
            }
            .navigationTitle("Library")
            .refreshable { reload() }
        }
        .navigationViewStyle(.stack)
        .onAppear { reload() }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { urls in
            pickedIPA = urls.first
        }, onDismiss: {
            choosingIPA = false
        })
        .confirmationDialog(
            "Install \(pickedIPA?.deletingPathExtension().lastPathComponent ?? "app")",
            isPresented: Binding(get: { pickedIPA != nil }, set: { if !$0 { pickedIPA = nil } }),
            titleVisibility: .visible
        ) {
            if let url = pickedIPA {
                Button("In the container") { installInContainer(url) }
                Button(slotsFull ? "As a native app (slots full)" : "As a native app") { installNatively(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(slotsFull
                 ? "Container: no limit, runs next to other apps. Native: all \(slotLimit) slots are used, so SideStore will ask you to remove one."
                 : "Container: no limit, runs next to other apps. Native: a real app on your Home Screen, uses 1 of \(slotLimit) slots and 1 App ID this week.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: sections

    private var installSection: some View {
        Section {
            Button {
                choosingIPA = true
            } label: {
                Label("Install an IPA…", systemImage: "square.and.arrow.down")
            }
            .disabled(sharedModel.multiLCStatus == 2)
        } footer: {
            Text("You choose: in the container (unlimited) or as a native app (uses a slot). Pick native for apps that don't work in the container.")
        }
    }

    private var nativeSection: some View {
        Section {
            if let snapshot, !snapshot.allApps.isEmpty {
                ForEach(snapshot.allApps) { app in
                    HStack(spacing: 12) {
                        nativeIcon(for: app)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(app.bundleIdentifier).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(daysLeft(app.expirationDate))
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(daysColor(app.expirationDate))
                    }
                }
            } else {
                Text("Open SideStore once so its app list shows up here.")
                    .foregroundColor(.secondary)
            }
            if UserDefaults.sideStoreExist() {
                Button {
                    LCUtils.openSideStore()
                } label: {
                    Label("Open SideStore to refresh", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            HStack {
                Text("Native apps")
                Spacer()
                Text("\(activeCount) of \(slotLimit) slots")
                    .foregroundColor(slotsFull ? .orange : .secondary)
            }
        } footer: {
            if let updated = snapshot?.lastUpdated {
                Text("Updated \(updated.formatted(.relative(presentation: .named))). Native apps need refreshing every 7 days; SideStore does it in the background.")
            }
        }
    }

    private var containerSection: some View {
        Section {
            HStack {
                Label("Apps in the container", systemImage: "square.grid.2x2")
                Spacer()
                Text("\(sharedModel.apps.count + sharedModel.hiddenApps.count)").foregroundColor(.secondary)
            }
            Button {
                sharedModel.selectedTab = .apps
            } label: {
                Label("Manage container apps", systemImage: "list.bullet")
            }
        } header: {
            Text("Container")
        } footer: {
            Text("No limit and nothing expires on its own. Touch and hold an app on Home to open it the normal way, add it to your Home Screen or install it natively.")
        }
    }

    private var settingsSection: some View {
        Section {
            Toggle("Pause apps hidden behind Home", isOn: $pauseHidden)
            Toggle("Show FPS and memory in apps", isOn: $showOverlay)
            NavigationLink {
                LCTweakFolderView(baseUrl: LCPath.tweakPath, isRoot: true)
            } label: {
                Label("lc.tabView.tweaks".loc, systemImage: "wrench.and.screwdriver")
            }
        } header: {
            Text("Running apps")
        } footer: {
            Text("When an app is hidden, games pause and go quiet; music apps that play in the background keep playing. The overlay applies to apps opened after you turn it on.")
        }
    }

    // MARK: helpers

    private func reload() {
        let (snap, url, _) = LabSideStoreReader.load()
        snapshot = snap
        snapshotURL = url
    }

    private func nativeIcon(for app: LabSideStoreApp) -> some View {
        let iconURL = snapshotURL?.deletingLastPathComponent()
            .appendingPathComponent("WidgetIcons/\(app.bundleIdentifier).png")
        let image = iconURL.flatMap { UIImage(contentsOfFile: $0.path) }
        return Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.3))
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func days(_ date: Date) -> Int {
        Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
    }

    private func daysLeft(_ date: Date) -> String {
        let d = days(date)
        return d <= 0 ? "expired" : (d == 1 ? "1 day" : "\(d) days")
    }

    private func daysColor(_ date: Date) -> Color {
        let d = days(date)
        return d <= 0 ? .red : (d <= 2 ? .orange : .secondary)
    }

    private func installInContainer(_ url: URL) {
        do {
            let staged = try ComboNativeInstall.stageForContainer(url)
            sharedModel.selectedTab = .apps
            sharedModel.deepLink = staged
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func installNatively(_ url: URL) {
        do {
            try ComboNativeInstall.handOver(url)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
