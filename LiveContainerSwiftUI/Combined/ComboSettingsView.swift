//
//  ComboSettingsView.swift
//  Hangar
//
//  One short Settings page: Apple ID, refresh, pairing, how running apps behave, and About.
//  The original LiveContainer and installer (SideStore) settings sit under Advanced as a fallback.
//

import SwiftUI

struct ComboSettingsView: View {
    @EnvironmentObject var sharedModel: SharedModel
    @ObservedObject private var account = HangarAccountModel.shared
    @ObservedObject private var installer = NativeInstallCenter.shared

    @AppStorage(ComboSettings.pauseHiddenKey, store: LCUtils.appGroupUserDefault) private var pauseHidden = true
    @AppStorage(ComboSettings.overlayKey, store: LCUtils.appGroupUserDefault) private var showOverlay = false

    @State private var showSignIn = false
    @State private var showAllSettings = false
    @State private var confirmSignOut = false
    @State private var choosingPairing = false
    @State private var note: String?
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            List {
                if UserDefaults.sideStoreExist() {
                    accountSection
                    pairingSection
                }
                runningSection
                advancedSection
                aboutSection
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showSignIn) { HangarSignInView() }
        .sheet(isPresented: $showAllSettings) {
            LCSettingsView()
                .environmentObject(sharedModel)
        }
        .confirmationDialog("Sign out of \(account.signedInAppleID ?? "your Apple ID")?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { account.signOut() }
        } message: {
            Text("Native apps keep working until they expire, but Hangar can't install or refresh them until you sign in again.")
        }
        .betterFileImporter(isPresented: $choosingPairing, types: [.item], multiple: false, callback: { urls in
            if let url = urls.first { importPairing(url) }
        }, onDismiss: {
            choosingPairing = false
        })
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: sections

    private var accountSection: some View {
        Section {
            if HangarAccountModel.available {
                Button {
                    showSignIn = true
                } label: {
                    HStack {
                        Label(account.signedInAppleID ?? "Sign in with Apple ID", systemImage: "person.crop.circle")
                        Spacer()
                        if account.signedInAppleID != nil {
                            Text("Signed in").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                if account.signedInAppleID != nil {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }
            }
            Button {
                installer.refreshAll()
            } label: {
                Label("Refresh all native apps now", systemImage: "arrow.clockwise")
            }
            .disabled(installer.isBusy)
        } header: {
            Text("Apple ID")
        } footer: {
            Text("Signs native apps. They last 7 days; Hangar refreshes them in the background while LocalDevVPN is on.")
        }
    }

    private var pairingSection: some View {
        Section {
            Button {
                choosingPairing = true
            } label: {
                Label("Import pairing file", systemImage: "link.badge.plus")
            }
            if let note {
                Text(note).font(.footnote).foregroundColor(.secondary)
            }
        } header: {
            Text("Pairing")
        } footer: {
            Text("Only needed if Hangar says it has no pairing file. Pick a .mobiledevicepairing or .plist file, for example one made by iLoader.")
        }
    }

    private var runningSection: some View {
        Section {
            Toggle("Pause apps hidden behind Home", isOn: $pauseHidden)
            Toggle("Show FPS and memory in apps", isOn: $showOverlay)
        } header: {
            Text("Running apps")
        } footer: {
            Text("When an app is hidden, games pause and go quiet; music apps that play in the background keep playing. The overlay applies to apps opened after you turn it on.")
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced") {
                Button {
                    showAllSettings = true
                } label: {
                    Label("All container settings", systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    LCTweakFolderView(baseUrl: LCPath.tweakPath, isRoot: true)
                } label: {
                    Label("lc.tabView.tweaks".loc, systemImage: "wrench.and.screwdriver")
                }
                if UserDefaults.sideStoreExist() {
                    Button {
                        LCUtils.openSideStore()
                    } label: {
                        Label("Installer settings", systemImage: "gearshape.2")
                    }
                }
            }
        } footer: {
            Text("Only for fixing problems, such as sign-in errors (anisette server) or pairing. Normal use doesn't need these.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(hangarVersion)
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("Based on")
                Spacer()
                Text(basedOn).foregroundColor(.secondary)
            }
            Link(destination: URL(string: "https://github.com/AbinGanlary/Hangar")!) {
                Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        } header: {
            Text("About Hangar")
        } footer: {
            Text("Hangar is built on LiveContainer (github.com/LiveContainer/LiveContainer) and SideStore (github.com/SideStore/SideStore), both licensed under the GNU AGPL v3. Hangar's source is available under the same licence.")
        }
    }

    // MARK: helpers

    private var hangarVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var basedOn: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "LiveContainer \(info["HangarBasedOnLiveContainer"] as? String ?? "?")"
    }

    /// Drops the chosen pairing file where Hangar's installer picks it up the next time it starts
    /// (SideStore fork: PairingFileManager.adoptWirelessPairingRecordIfNeeded imports and removes it).
    private func importPairing(_ picked: URL) {
        let ext = picked.pathExtension.lowercased()
        guard ["mobiledevicepairing", "mobiledevicepair", "plist", "xml"].contains(ext) else {
            errorText = "That isn't a pairing file. Pick a .mobiledevicepairing or .plist file."
            return
        }
        let accessing = picked.startAccessingSecurityScopedResource()
        defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
        do {
            let dir = LCPath.docPath.appendingPathComponent("SideStore/Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("ALTPairingFile.mobiledevicepairing")
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: picked, to: dest)
            note = "Pairing file added. Hangar uses it the next time it connects to your iPhone."
        } catch {
            errorText = error.localizedDescription
        }
    }
}
