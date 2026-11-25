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

    @State private var snapshot: LabSideStoreSnapshot?
    @State private var snapshotURL: URL?

    @State private var choosingIPA = false
    @State private var pickedIPA: URL?
    @State private var errorText: String?

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
                Button(slotsFull ? "As a native app (slots full)" : "As a native app") { installer.install(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(slotsFull
                 ? "Container: no limit, runs next to other apps. Native: all \(slotLimit) slots are used, so you'll be asked to remove one."
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
            .disabled(sharedModel.multiLCStatus == 2 || installer.isBusy)
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
                Text("Updated \(updated.formatted(.relative(presentation: .named))). Native apps last 7 days. Hangar refreshes them in the background while LocalDevVPN is on, or tap Refresh all now.")
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
            // installed by the hidden app list behind Home
            sharedModel.selectedTab = .home
            sharedModel.deepLink = staged
        } catch {
            errorText = error.localizedDescription
        }
    }
}
