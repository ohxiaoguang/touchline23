// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. The choices are kept in UserDefaults. DM_LAUNCHER=0 in Documents/env.txt starts the game at once, as an app
// without launcher.json does.
//
// Game files: the App's own Documents is the scan root, searched at every depth by the shared module (dm/apple/ResourceDiscovery.swift, the same code the Mac launcher runs). The
// player drops the files in through the Files app - no picker, no copy - and the launcher shows what was identified and checks it against this App's prepared modules before Play.
import SwiftUI
import UIKit
import os

private let defaults = UserDefaults.standard

/// The title this App was packed for: main.m sets it from the game profile (DM_GAME_ID) during
/// boot; Info.plist's NXTitleID is the fallback, as on the Mac.
private var titleID: UInt64 {
    if let text = ProcessInfo.processInfo.environment["DM_TITLE_ID"], let value = UInt64(text, radix: 16) { return value }
    return UInt64(Bundle.main.object(forInfoDictionaryKey: "NXTitleID") as? String ?? "", radix: 16) ?? 0
}

private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

/// Scan, verify and hand the result to the host. Everything expensive runs off the main thread.
private final class ResourceScan: ObservableObject {
    @Published var busy = false
    @Published var message = "Looking for this game's files…"
    @Published var report: DiscoveryReport?
    @Published var chosen: ResourceCombination?
    @Published var checked = false
    private var revision = 0
    private var modules: [ModuleBuild] { ResourceDiscovery.preparedBuilds(bundle: .main) }
    var ready: Bool { checked && chosen != nil }
    var external: Bool { ProcessInfo.processInfo.environment["DM_RESOURCE_BACKEND"] == "nsp" }

    /// `note` replaces the report's own message (used after Play finds a changed file).
    func rescan(note: String? = nil) {
        revision += 1; let token = revision
        busy = true; checked = false; chosen = nil; report = nil; message = note ?? "Looking for this game's files…"
        let root = documents, title = titleID, modules = self.modules
        DispatchQueue.global(qos: .userInitiated).async {
            let report = ResourceDiscovery.scan(root: root, titleID: title, modules: modules)
            DispatchQueue.main.async {
                guard token == self.revision else { return }
                self.busy = false
                self.report = report
                self.message = note ?? report.message
                guard report.ready else { self.chosen = nil; return }
                report.applyEnvironment()
                report.excludeResourcesFromBackup()
                self.chosen = report.selection
                self.checked = true
            }
        }
    }

    /// A conflict, or an update this App cannot use: the player decides here.
    func choose(_ combination: ResourceCombination) {
        chosen = combination
        checked = true
        report = report?.selecting(combination)
        _ = report?.applyEnvironment()
        message = "Using " + combination.summary + "."
        fputs("launcher: using \(combination.summary)\n", stderr)
    }

    /// Read the selection once more before the game mounts: a file that changed or a
    /// drive that went away is reported here, not inside the game.
    func verify(_ play: @escaping () -> Void) {
        guard let chosen, let report else { return }
        busy = true; message = "Checking the selected files…"
        let modules = self.modules, title = report.titleID
        DispatchQueue.global(qos: .userInitiated).async {
            let problem = ResourceDiscovery.verify(base: chosen.base, update: chosen.update,
                                                   keys: chosen.keys, titleID: title, modules: modules)
                ?? ResourceDiscovery.verifyAddons(chosen, titleID: title)
            DispatchQueue.main.async {
                self.busy = false
                if let problem { self.checked = false; self.message = problem; return }
                self.report?.selecting(chosen).applyEnvironment()
                self.checked = true
                play()
            }
        }
    }

    /// The path as the player sees it in the Files app (Documents is "On My iPhone → <App>").
    func shown(_ file: ResourceFile?) -> String {
        guard let file else { return "Not found" }
        let relative = file.path.hasPrefix(documents.path) ? String(file.path.dropFirst(documents.path.count)) : file.path
        return file.detail + " · " + (relative.hasPrefix("/") ? String(relative.dropFirst()) : relative)
    }
}

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

/// The embedded-mode answer, computed once (a file-scope `let` initializes lazily) and logged so a player's log.txt
/// says which of the host's roots was used or what was missing. See BundledResources for why the roots are the host's.
private let bundledProblem: String? = {
    let problem = BundledResources.problem(environment: ProcessInfo.processInfo.environment,
                                           documents: documents.path,
                                           bundle: Bundle.main.resourcePath ?? "")
    fputs("launcher: embedded resources: \(problem ?? "ok")\n", stderr)
    return problem
}()

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @StateObject private var language = LanguagePreferences(key: "launcher.interface-language.v1")
    private func l(_ text: String) -> String { GUIText.launcher(text, language: language.language) }
    @State private var memory = os_proc_available_memory()
    @State private var about = false
    @StateObject private var resources = ResourceScan()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 16) {
                if let icon = appIcon() {
                    Image(uiImage: icon).resizable().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 22))
                }
                Text(l((info("CFBundleDisplayName") as? String) ?? "Game")).font(.title.weight(.bold)).multilineTextAlignment(.center)
                Text(l("Version \((info("CFBundleShortVersionString") as? String) ?? "")")).font(.callout).foregroundStyle(.secondary)
                playButton
                Text(l("Sound follows Silent Mode. Turn Silent Mode off and raise the media volume if the game is quiet."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            Form {
                if resources.external {
                    Section(l("Game files")) {
                        ForEach(ResourceRole.allCases, id: \.self) { role in
                            resourceRow(role)
                        }
                        if resources.busy { ProgressView() }
                        Button(l("Look again")) { resources.rescan() }
                            .buttonStyle(.bordered).disabled(resources.busy)
                        Text(GUIText.filesHint(info("CFBundleDisplayName") as? String ?? "App").render(language.language))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !choices.isEmpty {
                        Section(l(conflictTitle)) {
                            ForEach(choices) { combination in
                                Button {
                                    resources.choose(combination)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(l(combination.update?.name ?? combination.base.name)).font(.body).lineLimit(1)
                                            Text(l(combination.update == nil ? "Base game only" : "with the update above")).font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if combination.id == resources.chosen?.id { Image(systemName: "checkmark").foregroundStyle(.green) }
                                    }
                                }.buttonStyle(.plain).disabled(resources.busy)
                            }
                        }
                    }
                }
                LauncherLanguageRow()
                // External mode: what was found in Documents, what it matched, and the diagnostics when it did not. Embedded mode:
                // the files are in the App, so there is nothing to find, choose or diagnose — only a real problem, if the App is
                // incomplete. Scanning and its checks are not disabled there: main.m verifies the RomFS marker before any UI.
                if resources.external {
                    Section {
                        ResourceStatusView(external: true, busy: resources.busy,
                            verified: resources.ready, count: resources.chosen?.dlcs.count,
                            message: resources.message, notes: resources.report?.notes ?? [])
                    }
                } else if let problem = bundledProblem {
                    Section {
                        Text(l(problem)).font(.footnote).foregroundStyle(Color.red)
                    }
                }
                SettingsList(m: m)
                Section {
                    HStack {
                        Text(l("Memory available"))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button {
                        about = true
                    } label: {
                        HStack {
                            Label(l("About Touchline 23"), systemImage: "info.circle")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .environmentObject(language)
        .environment(\.locale, Locale(identifier: language.language.resolved.rawValue))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $about) {
            AboutTouchlineView().environmentObject(language)
        }
        .task {
            if resources.external { resources.rescan() }
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var choices: [ResourceCombination] {
        guard let report = resources.report else { return [] }
        return (report.state == .conflict || report.state == .updateMismatch) ? report.combinations : []
    }
    private var conflictTitle: String {
        resources.report?.state == .updateMismatch ? "The update here does not match this App" : "More than one match"
    }

    private func file(_ role: ResourceRole) -> ResourceFile? {
        if let chosen = resources.chosen {
            switch role {
            case .base: return chosen.base
            case .update: return chosen.update
            case .keys: return chosen.keys
            }
        }
        guard let report = resources.report else { return nil }
        switch role {
        case .base: return report.bases.first
        case .update: return report.updates.first
        case .keys: return report.keyFiles.first
        }
    }

    private func resourceRow(_ role: ResourceRole) -> some View {
        let found = file(role)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: found == nil ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(found == nil ? Color.secondary : (resources.ready ? Color.green : Color.blue))
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(l(role.label)).font(.body.weight(.medium))
                Text(l(resources.shown(found)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder var playButton: some View {
        let title = !resources.external ? "Play" : resources.busy ? "Checking…" : resources.ready ? "Play" : "Resources needed"
        let button = Button(action: { if resources.external { resources.verify(play) } else { play() } }) {
            Label(l(title), systemImage: resources.external && !resources.ready ? "lock.fill" : "play.fill")
                .font(.title3.weight(.semibold)).frame(maxWidth: 220)
        }.controlSize(.large).disabled(resources.busy || (resources.external && !resources.ready))
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

extension ResourceRole: CaseIterable {
    public static var allCases: [ResourceRole] { [.base, .update, .keys] }
    var label: String { self == .base ? "Base game" : self == .update ? "Update (optional)" : "Console keys" }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); return false }
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(file.settings)
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
