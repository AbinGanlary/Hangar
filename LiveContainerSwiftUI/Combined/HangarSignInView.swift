//
//  HangarSignInView.swift
//  Hangar
//
//  Hangar's own Apple ID sign-in. The work happens in the background installer (Hangar's SideStore
//  build) through +[HangarAccount signInWithAppleID:password:codeRequester:completion:]
//  (SideStoreSupport, loaded at runtime, so it is called by name). 2FA codes are asked for here.
//

import SwiftUI

@MainActor
final class HangarAccountModel: ObservableObject {
    static let shared = HangarAccountModel()
    static let appleIDKey = "HangarSignedInAppleID"

    enum Phase: Equatable {
        case form
        case working(String)
        case code(prompt: String, error: String?, canUseSMS: Bool)
        case done
        case failed(String)
    }

    @Published var phase: Phase = .form
    @Published private(set) var signedInAppleID: String? = LCUtils.appGroupUserDefault.string(forKey: HangarAccountModel.appleIDKey)

    private var codeReply: ((String?) -> Void)?

    /// True when this build's installer supports Hangar's own sign-in.
    static var available: Bool { NSClassFromString("HangarAccount") != nil }

    func reset() {
        if codeReply != nil { submitCode(nil) }
        phase = .form
    }

    func signIn(appleID: String, password: String) {
        let appleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appleID.isEmpty, !password.isEmpty else { return }
        phase = .working("Signing in…")

        typealias CodeRequester = @convention(block) (NSString, NSString?, Bool, @escaping @convention(block) (NSString?) -> Void) -> Void
        typealias Completion = @convention(block) (NSString?) -> Void
        typealias Fn = @convention(c) (AnyObject, Selector, NSString, NSString, CodeRequester, Completion) -> Void

        let sel = NSSelectorFromString("signInWithAppleID:password:codeRequester:completion:")
        guard let cls = NSClassFromString("HangarAccount"), let method = class_getClassMethod(cls, sel) else {
            phase = .failed("This Hangar build can't sign in by itself. Use Installer settings instead.")
            return
        }

        let requester: CodeRequester = { prompt, error, canUseSMS, reply in
            Task { @MainActor in
                let model = HangarAccountModel.shared
                model.codeReply = { code in reply(code as NSString?) }
                model.phase = .code(prompt: prompt as String, error: error as String?, canUseSMS: canUseSMS)
            }
        }
        let completion: Completion = { error in
            Task { @MainActor in
                let model = HangarAccountModel.shared
                model.codeReply = nil
                if let error {
                    model.phase = .failed(Self.friendly(error as String))
                } else {
                    LCUtils.appGroupUserDefault.set(appleID, forKey: Self.appleIDKey)
                    model.signedInAppleID = appleID
                    model.phase = .done
                }
            }
        }
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        fn(cls, sel, appleID as NSString, password as NSString, requester, completion)
    }

    /// code: the 6 digits, "sms" to get a text message instead, or nil to cancel.
    func submitCode(_ code: String?) {
        guard let reply = codeReply else { return }
        codeReply = nil
        phase = code == nil ? .working("Cancelling…") : .working(code == "sms" ? "Sending a text message…" : "Checking the code…")
        reply(code)
    }

    func signOut() {
        typealias Completion = @convention(block) (NSString?) -> Void
        typealias Fn = @convention(c) (AnyObject, Selector, Completion) -> Void
        let sel = NSSelectorFromString("signOutWithCompletion:")
        LCUtils.appGroupUserDefault.removeObject(forKey: Self.appleIDKey)
        signedInAppleID = nil
        guard let cls = NSClassFromString("HangarAccount"), let method = class_getClassMethod(cls, sel) else { return }
        let completion: Completion = { _ in }
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        fn(cls, sel, completion)
    }

    private static func friendly(_ message: String) -> String {
        let m = message.lowercased()
        if m.contains("503") || m.contains("unparseable") {
            return "Apple's sign-in server refused the request. Wait a few minutes and try once more.\n\n(\(message))"
        }
        if m.contains("-22406") || m.contains("incorrect") && m.contains("password") || m.contains("invalid credentials") {
            return "The Apple ID or password is wrong.\n\n(\(message))"
        }
        if m.contains("pairing") {
            return "Hangar has no pairing file yet. Use Library → Import pairing file, then sign in again.\n\n(\(message))"
        }
        if m.contains("vpn") || m.contains("deviceendpoint") || m.contains("tunnel") {
            return "Turn on LocalDevVPN, then sign in again.\n\n(\(message))"
        }
        if m.contains("cancel") {
            return "Sign-in was cancelled."
        }
        return message
    }
}

struct HangarSignInView: View {
    @ObservedObject var model = HangarAccountModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var appleID = HangarAccountModel.shared.signedInAppleID ?? ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationView {
            Form {
                switch model.phase {
                case .form, .failed:
                    formSection
                case .working(let text):
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(text)
                        }
                    } footer: {
                        Text("This can take up to a minute. Keep Hangar open and LocalDevVPN on.")
                    }
                case .code(let prompt, let error, let canUseSMS):
                    codeSection(prompt: prompt, error: error, canUseSMS: canUseSMS)
                case .done:
                    Section {
                        Label("Signed in", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Button("Done") { dismiss() }
                    } footer: {
                        Text("Hangar can now install and refresh native apps.")
                    }
                }
            }
            .navigationTitle("Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.reset()
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            if case .done = model.phase { model.phase = .form }
            if case .failed = model.phase { model.phase = .form }
        }
    }

    private var formSection: some View {
        Group {
            if case .failed(let message) = model.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.footnote)
                }
            }
            Section {
                TextField("Apple ID (email)", text: $appleID)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button {
                    model.signIn(appleID: appleID, password: password)
                    password = ""
                } label: {
                    Text("Sign in").frame(maxWidth: .infinity)
                }
                .disabled(appleID.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            } footer: {
                Text("Used to sign native apps, like any sideloading tool. Your password is sent only to Apple and kept in this iPhone's Keychain for refreshing apps. A free Apple ID works; a separate one is safest.")
            }
        }
    }

    private func codeSection(prompt: String, error: String?, canUseSMS: Bool) -> some View {
        Section {
            Text(prompt)
            if let error, !error.isEmpty {
                Text(error).font(.footnote).foregroundColor(.orange)
            }
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.title2.monospacedDigit())
                .focused($codeFocused)
                .onAppear { codeFocused = true }
                .onChange(of: code) { value in
                    let digits = String(value.filter(\.isNumber).prefix(6))
                    if digits != value { code = digits }
                }
            Button {
                let c = code
                code = ""
                model.submitCode(c)
            } label: {
                Text("Verify").frame(maxWidth: .infinity)
            }
            .disabled(code.count != 6)
            if canUseSMS {
                Button("Text me a code instead") {
                    code = ""
                    model.submitCode("sms")
                }
            }
            Button("Cancel", role: .destructive) {
                code = ""
                model.submitCode(nil)
            }
        } header: {
            Text("Two-factor authentication")
        }
    }
}
