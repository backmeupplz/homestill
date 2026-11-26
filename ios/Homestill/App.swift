import AVFoundation
import SwiftUI

@main struct HomestillApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient) // muted cameras never stop the user's music
        Hooks.launch()
    }

    var body: some Scene {
        WindowGroup {
            Root()
                .onChange(of: phase, initial: true) { _, p in
                    if p == .active { Hooks.connect() } else if p == .background { ha.disconnect() }
                }
        }
    }
}

struct Root: View {
    @State private var tab = Hooks.string("tab") ?? "home"

    var body: some View {
        Group {
            if !ha.signedIn { SignIn() }
            else if ha.cameras.isEmpty { HomeView() }
            else {
                TabView(selection: $tab) {
                    Tab("Home", systemImage: "house.fill", value: "home") { HomeView() }
                    Tab("Cameras", systemImage: "video.fill", value: "cameras") { CamerasView() }
                }
            }
        }
        .toast()
        .animation(.smooth, value: ha.signedIn)
    }
}

extension View {
    /// The error toast; sheets and the full-screen camera cover Root, so they show it too.
    func toast() -> some View {
        overlay(alignment: .bottom) {
            if let t = ha.toast {
                Text(t).font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule).padding(.bottom, 90).padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: ha.toast)
    }
}

struct SignIn: View {
    @State private var server = UserDefaults.standard.string(forKey: "lastServer") ?? ""
    @State private var user = ""
    @State private var pass = ""
    @State private var code = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(systemName: "house.fill").font(.system(size: 56)).foregroundStyle(.tint)
                    Text(verbatim: "Homestill").font(.largeTitle.bold())
                    Text("Sign in to Home Assistant").foregroundStyle(.secondary)
                }
                .padding(.top, 60)
                VStack(spacing: 12) {
                    if ha.needsCode {
                        field("Code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    } else {
                        field("http://homeassistant.local:8123", text: $server).keyboardType(.URL).textContentType(.URL)
                        field("Username", text: $user).textContentType(.username)
                        SecureField("Password", text: $pass).textContentType(.password).padding(14)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 12)).onSubmit(go)
                    }
                }
                if let m = ha.signInMessage { Text(m).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
                Button(action: go) {
                    ZStack {
                        Text("Sign in").font(.headline).opacity(busy ? 0 : 1)
                        if busy { ProgressView() }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).disabled(busy)
            }
            .padding(.horizontal, 24).frame(maxWidth: 480)
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(14).background(.fill.tertiary, in: .rect(cornerRadius: 12)).onSubmit(go)
    }

    private func go() {
        busy = true
        Task {
            if ha.needsCode { await ha.submitCode(code) } else { await ha.signIn(server: server, user: user, password: pass) }
            if ha.signedIn { UserDefaults.standard.set(server, forKey: "lastServer"); pass = ""; code = "" }
            busy = false
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Server", value: ha.base ?? "")
                LabeledContent("User", value: ha.userName ?? "…")
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                Link("Privacy policy", destination: URL(string: "https://homestill.app/privacy/")!)
                Button("Sign out", role: .destructive) { dismiss(); ha.signOut() }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

/// Launch arguments for driving the app without taps (Debug only; Release ignores them):
/// `-signout 1`, `-server URL -user U -pass P` (when signed out), `-badtoken 1`, `-noconnect 1` (draw the cache only),
/// `-tab cameras`, `-settings 1`, `-edit 1` (Edit home), `-detail <entity_id>`, `-camera <entity_id>` (full screen),
/// `-tap <entity_id>` (taps a tile once synced; refused unless the server is localhost, so never on a real home).
@MainActor enum Hooks {
#if !DEBUG
    static func string(_ k: String) -> String? { nil }
    static func launch() {}
    static func connect() { ha.connect() }
#else
    static func string(_ k: String) -> String? { UserDefaults.standard.string(forKey: k) }
    private static var badTokenDone = false

    static func launch() {
        let d = UserDefaults.standard
        if d.bool(forKey: "signout") { ha.signOut(revoke: false) } // tests never call a server but the demo; wipes the layout
        if let s = d.string(forKey: "server"), let u = d.string(forKey: "user"), let p = d.string(forKey: "pass"), !ha.signedIn {
            Task { await ha.signIn(server: s, user: u, password: p) }
        }
        if let id = d.string(forKey: "tap") {
            ha.onSync = {
                guard let host = ha.base.flatMap({ URL(string: $0)?.host() }), ["127.0.0.1", "localhost"].contains(host) else {
                    logger.error("-tap refused: not a local demo server"); return
                }
                if let t = ha.tile(id) { ha.tap(t) }
            }
        }
    }

    static func connect() {
        let d = UserDefaults.standard
        if d.bool(forKey: "noconnect") { return }
        if d.bool(forKey: "badtoken"), !badTokenDone, ha.signedIn {
            badTokenDone = true
            ha.access = "x"; ha.expiry = .now + 1800
        }
        ha.connect()
    }
#endif
}
