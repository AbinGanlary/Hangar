//
//  ComboLibraryView.swift
//  Hangar
//
//  Installing and keeping apps:
//  - Install an IPA in the container (unlimited) or natively (uses one of the free Apple ID's 3 slots).
//  - Native apps with days left, and Refresh all to renew their 7 days now.
//  Account, pairing and app behaviour live in the Settings tab (ComboSettingsView).
//

import SwiftUI

struct ComboLibraryView: View {
    @EnvironmentObject var sharedModel: SharedModel
    @ObservedObject private var installer = NativeInstallCenter.shared
    @ObservedObject private var account = HangarAccountModel.shared

    @State private var snapshot: NativeAppsSnapshot?
    @State private var snapshotURL: URL?

    @State private var choosingIPA = false
    @State private var pickedIPA: URL?
    @State private var errorText: String?
    @State private var extensionIPA: URL?          // native install waiting for the extensions choice
    @State private var extensionCount = 0
    @State private var toggleApp: NativeApp?       // deactivate / activate confirmation

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
            }
            .navigationTitle("Library")
            .refreshable { reload() }
        }
        .navigationViewStyle(.stack)
        .onAppear { reload() }
        .onChange(of: installer.phase) { phase in
            if case .done = phase { reload() }
        }
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
                Button(slotsFull ? "As a native app (slots full)" : "As a native app") { startNativeInstall(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(slotsFull
                 ? "Container: no limit, runs next to other apps. Native: all \(slotLimit) slots are used, so you'll be asked to remove one."
                 : "Container: no limit, runs next to other apps. Native: a real app on your Home Screen, uses 1 of \(slotLimit) slots and 1 App ID this week.")
        }
        .confirmationDialog(
            "\(extensionIPA?.deletingPathExtension().lastPathComponent ?? "This app") has \(extensionCount) extension\(extensionCount == 1 ? "" : "s")",
            isPresented: Binding(get: { extensionIPA != nil }, set: { if !$0 { extensionIPA = nil } }),
            titleVisibility: .visible
        ) {
            if let url = extensionIPA {
                Button("Keep, share the app's ID (uses 1 App ID)") { installer.install(url, extensionChoice: "use-main-profile") }
                Button("Keep all (uses \(extensionCount + 1) App IDs)") { installer.install(url, extensionChoice: "keep-all") }
                Button("Remove them (uses 1 App ID)", role: .destructive) { installer.install(url, extensionChoice: "remove-all") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Extensions are widgets, share-sheet items and similar parts. A free Apple ID gets 10 new App IDs a week. Sharing the app's ID keeps them for free, but an extension that needs its own permissions may not fully work; keep all if so.")
        }
        .confirmationDialog(
            toggleTitle,
            isPresented: Binding(get: { toggleApp != nil }, set: { if !$0 { toggleApp = nil } }),
            titleVisibility: .visible
        ) {
            if let app = toggleApp {
                if isActive(app) {
                    Button("Deactivate", role: .destructive) { installer.setActive(false, bundleID: app.bundleIdentifier, name: app.name) }
                } else {
                    Button("Activate") { installer.setActive(true, bundleID: app.bundleIdentifier, name: app.name) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(toggleMessage)
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
            .disabled(sharedModel.multiLCStatus == 2 || installer.isBusy)
        } footer: {
            Text("You choose: in the container (unlimited) or as a native app (uses a slot). Pick native for apps that don't work in the container.")
        }
    }

    private var nativeSection: some View {
        Section {
            if let snapshot, !snapshot.allApps.isEmpty {
                ForEach(snapshot.allApps) { app in
                    Button {
                        if !isHangar(app) { toggleApp = app }
                    } label: {
                        HStack(spacing: 12) {
                            nativeIcon(for: app)
                                .opacity(isActive(app) ? 1 : 0.4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).foregroundColor(isActive(app) ? .primary : .secondary)
                                Text(app.bundleIdentifier).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if isActive(app) {
                                Text(daysLeft(app.expirationDate))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(daysColor(app.expirationDate))
                            } else {
                                Text("Inactive").font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                    }
                    .disabled(isHangar(app) || installer.isBusy)
                }
                Button {
                    installer.refreshAll()
                } label: {
                    Label("Refresh all now", systemImage: "arrow.clockwise")
                }
                .disabled(installer.isBusy)
            } else {
                Text(account.signedInAppleID == nil && HangarAccountModel.available
                     ? "Sign in with your Apple ID in Settings to install native apps. They show up here."
                     : "Native apps you install show up here.")
                    .foregroundColor(.secondary)
                if account.signedInAppleID == nil && HangarAccountModel.available {
                    Button("Go to Settings") { sharedModel.selectedTab = .settings }
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
                Text("Updated \(updated.formatted(.relative(presentation: .named))). Native apps last 7 days; Hangar refreshes them in the background while LocalDevVPN is on, or tap Refresh all now. Tap an app to deactivate it (frees a slot, keeps its data) or activate it again.")
            }
        }
    }

    private var containerSection: some View {
        Section {
            Button {
                sharedModel.selectedTab = .home
            } label: {
                HStack {
                    Label("Apps in the container", systemImage: "square.grid.2x2")
                    Spacer()
                    Text("\(sharedModel.apps.count + sharedModel.hiddenApps.count)").foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Container")
        } footer: {
            Text("No limit and nothing expires. Touch and hold an app on Home to rename, delete, change its settings, add it to your Home Screen or install it natively.")
        }
    }

    // MARK: helpers

    private func reload() {
        let (snap, url) = NativeAppsReader.load()
        snapshot = snap
        snapshotURL = url
    }

    private func nativeIcon(for app: NativeApp) -> some View {
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

    private func isActive(_ app: NativeApp) -> Bool {
        snapshot?.activeApps.contains { $0.bundleIdentifier == app.bundleIdentifier } ?? false
    }

    /// Hangar itself is in the list too; it can't deactivate itself.
    private func isHangar(_ app: NativeApp) -> Bool {
        Bundle.main.bundleIdentifier?.hasPrefix(app.bundleIdentifier) ?? false
    }

    private var toggleTitle: String {
        guard let app = toggleApp else { return "" }
        return isActive(app) ? "Deactivate \(app.name)?" : "Activate \(app.name)?"
    }

    private var toggleMessage: String {
        guard let app = toggleApp else { return "" }
        if isActive(app) {
            return "\(app.name) is removed from your Home Screen but its data is kept, and one of your \(slotLimit) slots is freed. Activate it again any time."
        }
        return slotsFull
            ? "All \(slotLimit) slots are in use. Deactivate another app first."
            : "\(app.name) is installed again with its data. Uses one of your \(slotLimit) slots."
    }

    private func startNativeInstall(_ url: URL) {
        let count = NativeInstallCenter.extensionCount(in: url)
        if count > 0 {
            extensionCount = count
            extensionIPA = url
        } else {
            installer.install(url)
        }
    }

    private func installInContainer(_ url: URL) {
        do {
            let staged = try ComboNativeInstall.stageForContainer(url)
            // installed by the hidden app list behind Home
            sharedModel.selectedTab = .home
            sharedModel.deepLink = staged
        } catch {
            errorText = error.localizedDescription
        }
    }
}
