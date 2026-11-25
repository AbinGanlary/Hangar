//
//  SideStore.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import Foundation
import AppIntents
import UserNotifications

@available(iOS 17.0, *)
func performIntentRefresh(identifier: String, mangledTypeName: String, intentProgress: Progress) async throws {
    intentProgress.totalUnitCount = 100
    if UserDefaults.isSideStore() {
        try await SideStoreIntentCaller.shared.callRefreshIntent(mangledTypeName: mangledTypeName)
    } else {
        RefreshHandler.shared.progress = intentProgress
        try await RefreshHandler.shared.startRefresh(identifier: identifier, mangledName: mangledTypeName)
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsWidgetIntent: AppIntent, ProgressReportingIntent
{
    public static var title: LocalizedStringResource { "Refresh Apps via Widget" }
    public static var isDiscoverable: Bool { false } // Don't show in Shortcuts or Spotlight.
    
    public init() {}
    
    public func perform() async throws -> some IntentResult
    {
        try await performIntentRefresh(identifier: "RefreshAllAppsWidgetIntent", mangledTypeName: "9SideStore26RefreshAllAppsWidgetIntentV", intentProgress: progress)
        return .result()
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    public static let intentClassName = "RefreshAllIntent"
    
    public static var title: LocalizedStringResource = "Refresh All Apps"
    public static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    public init() {}
    
    public static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    public func perform() async throws -> some IntentResult & ProvidesDialog
    {
        try await performIntentRefresh(identifier: "RefreshAllIntent", mangledTypeName: "9SideStore20RefreshAllAppsIntentV", intentProgress: progress)
        return .result(dialog: "All apps have been refreshed.")
    }
    
}


class RefreshHandler: NSObject, RefreshServer {
    var c: UnsafeContinuation<(), any Error>? = nil
    var launchContinuation: UnsafeContinuation<(), any Error>? = nil
    var progress: Progress? = nil
    var listener: NSXPCListener? = nil
    var sideStorePid: Int32 = 0
    var client: RefreshClient? = nil
    var ext: NSExtension? = nil
    
    static var shared = RefreshHandler()
    
    func startRefresh(identifier: String, mangledName: String, action: ((RefreshClient) -> Void)? = nil) async throws {
        if sideStorePid <= 0 || getpgid(sideStorePid) <= 0, let c {
            c.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore quit unexpectedly"]))
            self.c = nil
        }
        
        if c != nil {
            throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another refresh task is in progress."])
        }
        
        if listener == nil {
            guard let listener = startAnonymousListener(self) else {
                return
            }
            self.listener = listener
        }
        guard let listener = self.listener else {
            return
        }

        // launch SideStore if it's not running
        if (sideStorePid <= 0 || getpgid(sideStorePid) <= 0) && launchContinuation == nil {
            let lcHome = String(cString:getenv("LC_HOME_PATH"))
            let sideStoreHomeURL = URL(fileURLWithPath: lcHome).appendingPathComponent("Documents/SideStore")
            let bookmarkData = bookmarkForURL(sideStoreHomeURL)!

            // start LiveProcess
            let extensionItem = NSExtensionItem()
            extensionItem.userInfo = [
                "selected": "builtinSideStore",
                "bookmarks": [bookmarkData],
                "endpoint": listener.endpoint
            ]

            guard let liveProcessURL = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex"),
                  let liveProcessBundle = Bundle(url: liveProcessURL)
            else {
                NSLog("Unable to locate LiveProcess bundle")
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to locate LiveProcess bundle. To use the Refresh All Apps shortcut, reinstall LiveContainer+SideStore with LiveProcess installed. If you use SideStore, choose \"Keep App Extensions (Use Main Profile)\". If you use PlumeImpactor, choose \"Only Register Main Bundle\". For other sideloaders, select keep all extensions, i.e. DO NOT Remove any extension."])
            }
            
            var ext : NSExtension?
            do {
                ext = try NSExtension(identifier: liveProcessBundle.bundleIdentifier)
            } catch {
                NSLog("Failed to start extension \(error)")
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start extension \(error). To use the Refresh All Apps shortcut, reinstall LiveContainer+SideStore with LiveProcess installed. If you use SideStore, choose \"Keep App Extensions (Use Main Profile)\". If you use Impactor, choose \"Only Register Main Bundle\". For other sideloaders, select keep all extensions, i.e. DO NOT Remove any extension."])
            }
            guard let ext else {
                return
            }
            self.ext = ext
            
            ext.setRequestInterruptionBlock { uuid in
                self.c?.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore quit unexpectedly"]))
                self.c = nil
                self.sideStorePid = 0
                self.launchContinuation = nil
            }
            
            let uuid = await ext.beginRequest(withInputItems: [extensionItem])
            sideStorePid = ext.pid(forRequestIdentifier: uuid)
            
            try await withUnsafeThrowingContinuation { c in
                self.launchContinuation = c
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                    if let c = self.launchContinuation {
                        c.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore failed to start in reasonable time"]))
                        self.launchContinuation = nil
                        ext._kill(9)
                    }
                }
            }
        }
        if let action {
            // Hangar: run something other than an intent (e.g. sign-in) in the background SideStore
            guard let client = self.client else {
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Hangar's installer didn't connect. Try again."])
            }
            action(client)
        } else {
            self.client?.refreshAllApps(withIdentifier: identifier, mangledTypeName: mangledName)
        }
        
        try await withUnsafeThrowingContinuation { c in
            self.c = c
        }
        
    }
    
    func updateProgress(_ value: Double) {
        progress?.completedUnitCount = Int64(value*100)
    }
    
    func finish(_ error: String?) {
        if let error {
            c?.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))
            c = nil
        } else {
            c?.resume()
            c = nil
        }
    }
    
    func onConnection(_ connection: NSXPCConnection!) {
        connection.remoteObjectInterface = NSXPCInterface(with: RefreshClient.self)
        client = connection.remoteObjectProxy as? RefreshClient
    }
    
    /// Hangar: set while a Hangar sign-in runs; shows Hangar's 2FA code field.
    var hangarCodeRequester: ((String, String?, Bool, @escaping (String?) -> Void) -> Void)?

    func hangarRequestCode(withPrompt prompt: String, error: String?, canUseSMS: Bool, reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            guard let requester = self.hangarCodeRequester else {
                reply(nil)
                return
            }
            requester(prompt, error, canUseSMS, reply)
        }
    }

    func finishedLaunching() {
        launchContinuation?.resume()
        launchContinuation = nil
    }

    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Failed to add SideStore notification: \(error)")
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    
}

// MARK: - Hangar

/// Hangar's screenless native install. Hangar's UI (LiveContainerSwiftUI) can't link this framework,
/// which is loaded at runtime, so it calls this class by its Objective-C name:
/// +[HangarInstaller installStagedWithProgress:completion:].
/// Hangar stages the IPA and puts its path under HangarPendingInstallPath in the app-group defaults.
/// This starts built-in SideStore in the background (LiveProcess), like Refresh All Apps does,
/// and runs SideStore's InstallStagedIPAIntent there. Nothing of SideStore is shown.
@available(iOS 17.0, *)
@objc(HangarInstaller)
public class HangarInstaller: NSObject {
    @objc public static func installStaged(progress: Progress, completion: @escaping (NSString?) -> Void) {
        Task {
            do {
                progress.totalUnitCount = 100
                RefreshHandler.shared.progress = progress
                try await RefreshHandler.shared.startRefresh(identifier: "InstallStagedIPAIntent",
                                                             mangledName: "9SideStore22InstallStagedIPAIntentV")
                completion(nil)
            } catch {
                completion(error.localizedDescription as NSString)
            }
        }
    }
}

/// Hangar's own Apple ID sign-in. Runs SideStore's sign-in in the background SideStore (LiveProcess) with
/// HangarSignInHandler, so no SideStore screen appears; 2FA codes are asked for through codeRequester.
/// Called by Hangar's UI by its Objective-C name:
/// +[HangarAccount signInWithAppleID:password:codeRequester:completion:], +[HangarAccount signOutWithCompletion:].
@available(iOS 17.0, *)
@objc(HangarAccount)
public class HangarAccount: NSObject {
    @objc(signInWithAppleID:password:codeRequester:completion:)
    public static func signIn(appleID: String,
                                    password: String,
                                    codeRequester: @escaping (String, String?, Bool, @escaping (String?) -> Void) -> Void,
                                    completion: @escaping (NSString?) -> Void) {
        Task {
            RefreshHandler.shared.hangarCodeRequester = codeRequester
            defer { RefreshHandler.shared.hangarCodeRequester = nil }
            do {
                try await RefreshHandler.shared.startRefresh(identifier: "HangarSignIn", mangledName: "") { client in
                    client.hangarSignIn(withAppleID: appleID, password: password)
                }
                completion(nil)
            } catch {
                completion(error.localizedDescription as NSString)
            }
        }
    }

    @objc public static func signOut(completion: @escaping (NSString?) -> Void) {
        Task {
            do {
                try await RefreshHandler.shared.startRefresh(identifier: "HangarSignOut", mangledName: "") { client in
                    client.hangarSignOut()
                }
                completion(nil)
            } catch {
                completion(error.localizedDescription as NSString)
            }
        }
    }
}
