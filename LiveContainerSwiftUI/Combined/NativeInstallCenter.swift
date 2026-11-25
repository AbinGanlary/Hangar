//
//  NativeInstallCenter.swift
//  Hangar
//
//  Screenless native installs. The IPA is copied into the shared app group, its path is
//  written to HangarPendingInstallPath, and +[HangarInstaller installStagedWithProgress:completion:]
//  (SideStoreSupport, loaded at runtime) runs the installer in the background. Progress and the
//  result show in a banner over every tab.
//

import Foundation
import SwiftUI

@MainActor
final class NativeInstallCenter: ObservableObject {
    static let shared = NativeInstallCenter()

    enum Phase: Equatable {
        case idle
        case running(title: String, fraction: Double)
        case done(text: String)
        case failed(title: String, message: String)
    }

    @Published private(set) var phase: Phase = .idle

    private static let pendingPathKey = "HangarPendingInstallPath"
    private static let resultKey = "HangarLastInstallResult"

    var isBusy: Bool {
        if case .running = phase { return true }
        return false
    }

    /// True when this build has the background installer (Hangar's SideStore build with InstallStagedIPAIntent).
    static var backgroundInstallerAvailable: Bool {
        NSClassFromString("HangarInstaller") != nil
    }

    func dismiss() { phase = .idle }

    /// extensionChoice: "keep-all", "use-main-profile", "remove-all", or nil for the installer's default.
    func install(_ picked: URL, extensionChoice: String? = nil) {
        guard !isBusy else { return }
        let name = picked.deletingPathExtension().lastPathComponent

        guard Self.backgroundInstallerAvailable else {
            // Older installer build: fall back to showing the installer's own screen.
            do { try ComboNativeInstall.handOver(picked) } catch { phase = .failed(title: "Couldn't install \(name)", message: error.localizedDescription) }
            return
        }

        let staged: URL
        do {
            staged = try Self.stage(picked)
        } catch {
            phase = .failed(title: "Couldn't install \(name)", message: error.localizedDescription)
            return
        }

        let defaults = LCUtils.appGroupUserDefault
        defaults.removeObject(forKey: Self.resultKey)
        if let extensionChoice {
            defaults.set(extensionChoice, forKey: "HangarExtensionChoice")
        } else {
            defaults.removeObject(forKey: "HangarExtensionChoice")
        }
        defaults.set(staged.path, forKey: Self.pendingPathKey)

        let progress = Progress(totalUnitCount: 100)
        phase = .running(title: "Installing \(name)", fraction: 0)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                let center = NativeInstallCenter.shared
                guard case .running = center.phase else { return }
                center.phase = .running(title: "Installing \(name)", fraction: progress.fractionCompleted)
            }
        }

        Self.callInstaller(progress: progress) { error in
            Task { @MainActor in
                timer.invalidate()
                try? FileManager.default.removeItem(at: staged)
                let center = NativeInstallCenter.shared
                let result = defaults.string(forKey: Self.resultKey)
                if let error {
                    center.phase = .failed(title: "Couldn't install \(name)", message: Self.friendly(error))
                } else if let result, result.hasPrefix("error:") {
                    center.phase = .failed(title: "Couldn't install \(name)", message: Self.friendly(String(result.dropFirst(6))))
                } else {
                    center.phase = .done(text: "\(name) is installed on your Home Screen")
                }
            }
        }
    }

    /// Renews every native app's 7 days now, in the background: SideStore's Refresh All Apps,
    /// run through +[HangarInstaller refreshAllWithProgress:completion:].
    func refreshAll() {
        guard !isBusy else { return }
        typealias Completion = @convention(block) (NSString?) -> Void
        typealias Fn = @convention(c) (AnyObject, Selector, Progress, Completion) -> Void
        let sel = NSSelectorFromString("refreshAllWithProgress:completion:")
        guard let cls = NSClassFromString("HangarInstaller"), let method = class_getClassMethod(cls, sel) else {
            phase = .failed(title: "Couldn't refresh apps", message: "This Hangar build has no background refresh.")
            return
        }
        let progress = Progress(totalUnitCount: 100)
        phase = .running(title: "Refreshing native apps", fraction: 0)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                let center = NativeInstallCenter.shared
                guard case .running = center.phase else { return }
                center.phase = .running(title: "Refreshing native apps", fraction: progress.fractionCompleted)
            }
        }
        let completion: Completion = { error in
            Task { @MainActor in
                timer.invalidate()
                let center = NativeInstallCenter.shared
                if let error {
                    center.phase = .failed(title: "Couldn't refresh apps", message: Self.friendly(error as String))
                } else {
                    center.phase = .done(text: "Native apps refreshed for 7 more days")
                }
            }
        }
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        fn(cls, sel, progress, completion)
    }

    /// Deactivate (frees a slot, keeps the app's data) or activate a native app, in the background.
    func setActive(_ active: Bool, bundleID: String, name: String) {
        guard !isBusy else { return }
        typealias Completion = @convention(block) (NSString?) -> Void
        typealias Fn = @convention(c) (AnyObject, Selector, NSString, NSString, Completion) -> Void
        let sel = NSSelectorFromString("appAction:bundleID:completion:")
        guard let cls = NSClassFromString("HangarInstaller"), let method = class_getClassMethod(cls, sel) else {
            phase = .failed(title: "Couldn't change \(name)", message: "This Hangar build can't do that yet.")
            return
        }
        phase = .running(title: active ? "Activating \(name)" : "Deactivating \(name)", fraction: 0.5)
        let completion: Completion = { error in
            Task { @MainActor in
                let center = NativeInstallCenter.shared
                if let error {
                    center.phase = .failed(title: active ? "Couldn't activate \(name)" : "Couldn't deactivate \(name)",
                                           message: Self.friendly(error as String))
                } else {
                    center.phase = .done(text: active ? "\(name) is back on your Home Screen" : "\(name) is deactivated; its data is kept")
                }
            }
        }
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        fn(cls, sel, (active ? "activate" : "deactivate") as NSString, bundleID as NSString, completion)
    }

    /// Number of app extensions inside an IPA (PlugIns/*.appex and Extensions/*.appex of the main app).
    /// Reads only the end of the file, where a zip keeps its list of file names.
    nonisolated static func extensionCount(in ipa: URL) -> Int {
        let accessing = ipa.startAccessingSecurityScopedResource()
        defer { if accessing { ipa.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: ipa) else { return 0 }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 32 * 1024 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .isoLatin1),
              let regex = try? NSRegularExpression(pattern: "Payload/[^/]+\\.app/(?:PlugIns|Extensions)/([^/]+)\\.appex/Info\\.plist")
        else { return 0 }
        var names = Set<String>()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(match.range(at: 1), in: text) { names.insert(String(text[r])) }
        }
        return names.count
    }

    // MARK: helpers

    /// The background installer runs in a separate process that can read the shared app group.
    private static func stage(_ picked: URL) throws -> URL {
        let accessing = picked.startAccessingSecurityScopedResource()
        defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LCSharedUtils.appGroupID()) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Hangar's shared folder is missing. Reinstall Hangar with app extensions kept."])
        }
        let dir = group.appendingPathComponent("HangarInstall", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(picked.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: picked, to: dest)
        return dest
    }

    private static func callInstaller(progress: Progress, completion: @escaping (String?) -> Void) {
        typealias Fn = @convention(c) (AnyObject, Selector, Progress, @escaping @convention(block) (NSString?) -> Void) -> Void
        let sel = NSSelectorFromString("installStagedWithProgress:completion:")
        guard let cls = NSClassFromString("HangarInstaller"),
              let method = class_getClassMethod(cls, sel) else {
            completion("This Hangar build has no background installer.")
            return
        }
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        fn(cls, sel, progress) { error in completion(error as String?) }
    }

    /// Turns the installer's common errors into plain advice.
    private static func friendly(_ message: String) -> String {
        let m = message.lowercased()
        if m.contains("not signed in") || m.contains("no account") || (m.contains("apple id") && m.contains("sign")) {
            return "Sign in to your Apple ID first: Library → Sign in with Apple ID.\n\n(\(message))"
        }
        if m.contains("pairing") {
            return "Hangar has no pairing file. Add one with Library → Import pairing file, or pair this iPhone under Library → Installer settings → Settings → Pairing File Management → Wireless Pairing.\n\n(\(message))"
        }
        if m.contains("vpn") || m.contains("minimuxer") || m.contains("device not connected") || m.contains("heartbeat") {
            return "Turn on LocalDevVPN, then try again.\n\n(\(message))"
        }
        if m.contains("maximum") || m.contains("limit") || m.contains("active apps") {
            return "All 3 native slots are in use. Remove a native app first.\n\n(\(message))"
        }
        return message
    }
}

/// Banner shown over every tab while a native install runs, and with its result.
struct NativeInstallBanner: View {
    @ObservedObject var center = NativeInstallCenter.shared

    var body: some View {
        Group {
            switch center.phase {
            case .idle:
                EmptyView()
            case .running(let title, let fraction):
                card {
                    HStack(spacing: 12) {
                        ProgressView().progressViewStyle(.circular)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.subheadline.weight(.semibold))
                            ProgressView(value: fraction)
                        }
                    }
                }
            case .done(let text):
                card {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.title2)
                        Text(text).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("OK") { center.dismiss() }
                    }
                }
            case .failed(let title, let message):
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("OK") { center.dismiss() }
                        }
                        Text(message).font(.footnote).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: center.phase)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
