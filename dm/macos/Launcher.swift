// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The build decides where the game data comes from: bundled in the App (directory) or
// an external container the player points at (nsp, the name external containers keep for
// now). Everything else - settings, storage folder, how the game is started - is the same.
private let packedGameData = (Bundle.main.object(forInfoDictionaryKey: "NXResourceBackend") as? String ?? "nsp") == "directory"

private var titleID: UInt64 { UInt64(Bundle.main.object(forInfoDictionaryKey: "NXTitleID") as? String ?? "", radix: 16) ?? 0 }

@MainActor
private enum ActiveSession {
    static var process: Process?
    static var output: FileHandle?
    static func note(_ message: String) {
        try? output?.write(contentsOf: Data(("[launcher] " + message + "\n").utf8))
    }
}

// The player picks one folder - the game's own files inside it, at any depth, are found
// by the shared module (dm/apple/ResourceDiscovery.swift), which iOS uses unchanged.
// Nothing is copied: the containers are read where they lie, read-only.
@MainActor
private final class Resources: ObservableObject {
    @Published var folder: URL?
    @Published var report: DiscoveryReport?
    @Published var workspace: URL?
    @Published var modsFolder: URL?
    @Published var modsProblem: String?
    @Published var busy = false
    @Published var running = false
    @Published var hasError = false
    @Published var message = "Choose the folder that holds this game's files."
    private var scopes: [String: URL] = [:]
    private var revision = 0
    private var autoStarted = false
    private var pendingAutoStart: LauncherModel?   // an autoplay that arrived while the first scan was still running
    private var task: Process?
    private var output: FileHandle?
    private var interfaceLanguage: InterfaceLanguage {
        InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: "launcher.interface-language.v1") ?? "system") ?? .system
    }
    private var res: URL { Bundle.main.resourceURL! }
    private var romfs: URL { res.appendingPathComponent("romfs") }
    private var modules: [ModuleBuild] { ResourceDiscovery.preparedBuilds(bundle: .main) }
    /// A combination the player picked in a conflict, kept per title so a restart
    /// does not ask again. It only ever wins among combinations that already verify.
    private var picked: PreferredSelection? {
        let key = String(titleID, radix: 16)
        guard let base = UserDefaults.standard.string(forKey: "resource.pick.base." + key) else { return nil }
        let update = UserDefaults.standard.string(forKey: "resource.pick.update." + key) ?? ""
        return PreferredSelection(base: URL(fileURLWithPath: base),
                                  update: update.isEmpty ? nil : URL(fileURLWithPath: update))
    }
    var selection: ResourceCombination? { report?.selection }
    var ready: Bool { packedGameData ? workspace != nil : (report?.ready ?? false) && selection != nil }
    var conflict: [ResourceCombination] { (report?.state == .conflict || report?.state == .updateMismatch) ? (report?.combinations ?? []) : [] }

    init() {
        folder = restore("folder")
        workspace = restore("workspace") ?? Resources.defaultWorkspace()
        modsFolder = restore("mods")
        if packedGameData {
            refreshPacked()
        } else if folder != nil {
            rescan()
        }
    }
    /// Saves, logs and temporary files start in the user's own Application Support
    /// folder; start() puts the single Touchline23-<title> folder inside it. The player
    /// may point the storage elsewhere instead.
    private static func defaultWorkspace() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return FileManager.default.fileExists(atPath: base.path) ? base : nil
    }
    private func restore(_ key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "resource.bookmark." + key) else { return nil }
        var stale = false
        // A plain bookmark: this App is not sandboxed, so a security-scoped bookmark
        // cannot be created here at all; the plain one survives a relaunch and follows
        // the folder when it moves on the same volume.
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        hold(url, key: key)
        if stale { remember(url, key: key) }
        return url
    }
    private func hold(_ url: URL, key: String) {
        scopes.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { scopes[key] = url }
    }
    private func remember(_ url: URL, key: String) {
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: "resource.bookmark." + key)
        }
    }

    /// One folder, chosen once: the scan finds the base game, the update and the keys.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = GUIText(key: "Choose the folder that holds this game's files. Sub-folders are searched too.").render(interfaceLanguage)
        panel.prompt = "Choose folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = folder ?? workspace ?? Bundle.main.bundleURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        hold(url, key: "folder"); folder = url; remember(url, key: "folder")
        clearPick()
        rescan()
    }
    func rescan() {
        guard !packedGameData, let folder else { return }
        revision += 1; let token = revision
        busy = true; hasError = false; report = nil; message = "Looking for this game's files…"
        let root = folder, title = titleID, modules = self.modules, preferred = picked
        DispatchQueue.global(qos: .userInitiated).async {
            let report = ResourceDiscovery.scan(root: root, titleID: title, modules: modules, preferred: preferred)
            DispatchQueue.main.async {
                guard token == self.revision else { return }
                self.busy = false
                self.report = report
                self.hasError = !report.ready
                self.message = report.message
                if report.ready { self.savePick(report.selection) }
                if let settings = self.pendingAutoStart, report.ready {   // an autoplay that had to wait for this scan
                    self.pendingAutoStart = nil
                    self.play(settings)
                }
            }
        }
    }
    /// A conflict, or an update this App cannot use: the player decides, in one click.
    func choose(_ combination: ResourceCombination) {
        guard let current = report else { return }
        let resolved = current.selecting(combination)
        report = resolved
        hasError = false
        message = resolved.message
        savePick(combination)
    }
    private func savePick(_ combination: ResourceCombination?) {
        guard let combination else { return }
        let key = String(titleID, radix: 16)
        UserDefaults.standard.set(combination.base.path, forKey: "resource.pick.base." + key)
        UserDefaults.standard.set(combination.update?.path ?? "", forKey: "resource.pick.update." + key)
    }
    private func clearPick() {
        let key = String(titleID, radix: 16)
        UserDefaults.standard.removeObject(forKey: "resource.pick.base." + key)
        UserDefaults.standard.removeObject(forKey: "resource.pick.update." + key)
    }
    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.message = GUIText(key: "Choose a writable folder on your game drive for saves, logs and temporary files. Game resources stay in their original location.").render(interfaceLanguage)
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspace ?? folder ?? Bundle.main.bundleURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        hold(url, key: "workspace"); workspace = url; remember(url, key: "workspace")
        if packedGameData { refreshPacked() }
    }
    func chooseModsFolder() {
        let panel = NSOpenPanel()
        panel.message = GUIText(key: "Choose the MOD resource folder. Choose mods/romfs or the folder containing the individual MODs.").render(interfaceLanguage)
        panel.prompt = GUIText(key: "Choose folder").render(interfaceLanguage)
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder]
        panel.directoryURL = modsFolder ?? workspace ?? folder
        // Let SwiftUI's main actor keep processing while the native panel is open.
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { _ = try ModOverlay.applying(folder: url, to: [:]) }
            catch { self.modsProblem = "Cannot read the MOD folder. Choose it again or clear the selection."; return }
            self.hold(url, key: "mods"); self.modsFolder = url; self.remember(url, key: "mods")
            self.modsProblem = nil
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
    func clearModsFolder() {
        scopes.removeValue(forKey: "mods")?.stopAccessingSecurityScopedResource()
        UserDefaults.standard.removeObject(forKey: "resource.bookmark.mods")
        modsFolder = nil
        modsProblem = nil
    }
    private func refreshPacked() {
        guard FileManager.default.fileExists(atPath: romfs.path) else {
            hasError = true; message = "This App carries no game files: rebuild it in directory mode."; return
        }
        hasError = false
        message = workspace == nil ? "Choose a storage folder for saves and logs."
                                   : "Game files are inside this App. Ready to play."
    }
    /// DM_LAUNCHER=0 starts the game once, as soon as the resources check passes.
    func autoplay(_ settings: LauncherModel) {
        guard !autoStarted else { return }
        autoStarted = true
        guard !busy else { pendingAutoStart = settings; return }   // the first scan is still running: start when it lands (rescan)
        play(settings)
    }
    /// Before the game starts: the selection is re-read once, so a drive that was
    /// removed (or a file that changed) is reported instead of failing inside the game.
    func play(_ settings: LauncherModel) {
        // Read the settings once, on the main thread: the check below runs in the
        // background and must not carry the view model with it.
        settings.apply()
        let chosen = settings.values
        guard !packedGameData else { return start(chosen) }
        guard let selection, let report else { return }
        revision += 1; let token = revision
        busy = true; message = "Checking the selected files…"
        let modules = self.modules
        DispatchQueue.global(qos: .userInitiated).async {
            let problem = ResourceDiscovery.verify(base: selection.base, update: selection.update,
                                                   keys: selection.keys, titleID: report.titleID, modules: modules)
                ?? ResourceDiscovery.verifyAddons(selection, titleID: report.titleID)
            DispatchQueue.main.async {
                guard token == self.revision else { return }
                self.busy = false
                guard let problem else { return self.start(chosen) }
                self.hasError = true; self.message = problem
            }
        }
    }
    func detail(_ file: ResourceFile?) -> String {
        guard let file else { return "Not found" }
        return file.detail + " · " + file.path
    }
    func icon(_ file: ResourceFile?) -> String { file == nil ? "circle.dashed" : "checkmark.circle.fill" }
    private func start(_ chosen: [String: String]) {
        guard let workspace else { return }
        if !packedGameData && selection == nil { return }
        var baseEnvironment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DM_") }
        for (key, value) in chosen { baseEnvironment[key] = value }
        do { baseEnvironment = try ModOverlay.applying(folder: modsFolder, to: baseEnvironment) }
        catch { modsProblem = "Cannot read the MOD folder. Choose it again or clear the selection."; return }
        modsProblem = nil
        do {
            let title = Bundle.main.object(forInfoDictionaryKey: "NXTitleID") as? String ?? "game"
            let run = workspace.appendingPathComponent("Touchline23-" + title, isDirectory: true)
            let fm = FileManager.default
            for name in ["", "save", "temp"] { try fm.createDirectory(at: run.appendingPathComponent(name), withIntermediateDirectories: true) }
            let log = run.appendingPathComponent("log.txt")
            if fm.fileExists(atPath: log.path) { try fm.moveItem(at: log, to: run.appendingPathComponent("log-" + UUID().uuidString + ".txt")) }
            guard fm.createFile(atPath: log.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
            let output = try FileHandle(forWritingTo: log)
            var env = baseEnvironment
            var runtime = ["DM_WINDOW": "1", "DM_AUDIO": "1", "DM_ROOT": run.path,
                           "DM_SAVE": run.appendingPathComponent("save").path, "DM_TEMP": run.appendingPathComponent("temp").path,
                           "DM_MSL_DIR": res.appendingPathComponent("msl").path,
                           "DM_NVN_SHMAP": res.appendingPathComponent("profile/shader_map.tsv").path,
                           "DM_FONT_DIR": res.appendingPathComponent("font").path]
            if packedGameData {
                // The bundled RomFS: the host's directory backend reads it in place.
                runtime["DM_RESOURCE_BACKEND"] = "directory"
                runtime["DM_ROMFS"] = romfs.path
                let aoc = res.appendingPathComponent("aoc")
                if fm.fileExists(atPath: aoc.path) { runtime["DM_AOC_DIR"] = aoc.path }
            } else if let selection {
                runtime.merge(["DM_RESOURCE_BACKEND": "nsp", "DM_RESOURCE_NSP": selection.base.path,
                               "DM_RESOURCE_KEYS": selection.keys.path, "DM_RESOURCE_UPDATE": selection.update?.path ?? ""],
                              uniquingKeysWith: { _, new in new })
            }
            if !packedGameData, let selection { runtime.merge(selection.aocEnvironment, uniquingKeysWith: { _, new in new }) }
            env.merge(runtime, uniquingKeysWith: { _, new in new })
            try output.write(contentsOf: Data(("[launcher] MOD overlay: " + (env["DM_ROMFS_OVERLAY"] ?? "off") + "\n").utf8))
            let process = Process()
            let started = Date()
            let selectedSettings = chosen
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dmhost")
            process.arguments = [res.appendingPathComponent("program").path]
            process.currentDirectoryURL = run; process.environment = env
            process.standardOutput = output; process.standardError = output
            process.terminationHandler = { done in
                DispatchQueue.main.async {
                    let summary: [String: Any] = ["pid": done.processIdentifier, "status": done.terminationStatus,
                        "reason": done.terminationReason == .exit ? "exit" : "signal",
                        "started": started.timeIntervalSince1970, "ended": Date().timeIntervalSince1970,
                        "settings": selectedSettings]
                    if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: run.appendingPathComponent("session-result.json"), options: .atomic)
                    }
                    ActiveSession.note("Game ended: status \(done.terminationStatus), reason \(done.terminationReason == .exit ? "exit" : "signal")")
                    try? output.close(); self.output = nil; self.task = nil; self.running = false; ActiveSession.process = nil; ActiveSession.output = nil
                    self.message = done.terminationStatus == 0 ? "Game closed. Ready to play." : "Game exited with status \(done.terminationStatus). Log: \(log.path)"
                    self.hasError = done.terminationStatus != 0
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            self.output = output
            try process.run(); task = process; ActiveSession.process = process; ActiveSession.output = output
            ActiveSession.note("Game started: pid \(process.processIdentifier)")
            running = true; hasError = false
            message = packedGameData ? "Game running." : "Game running. Keep the resource drive connected."
        } catch { try? output?.close(); output = nil; hasError = true; message = "Cannot start the game: " + error.localizedDescription + ". Check the storage folder." }
    }
    func stop() {
        if task?.isRunning == true { ActiveSession.note("Stop game requested"); task?.terminate() }
    }
}

@MainActor
private struct MacLauncher: View {
    @ObservedObject var settings: LauncherModel
    @ObservedObject var resources: Resources
    @EnvironmentObject private var language: LanguagePreferences
    @State private var about = false
    private func l(_ text: String) -> String { GUIText.launcher(text, language: language.language) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 18) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 64)).foregroundStyle(.tint)
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Touchline 23").font(.title.bold()).multilineTextAlignment(.center)
                Text(l("Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))).foregroundStyle(.secondary)
                Button { resources.play(settings) } label: {
                    Label(l(resources.running ? "Playing" : resources.busy ? "Checking…" : resources.ready ? "Play" : "Resources needed"), systemImage: "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!resources.ready || resources.workspace == nil || resources.busy || resources.running)
                ResourceStatusView(external: !packedGameData, busy: resources.busy,
                    verified: resources.ready && !resources.hasError, count: resources.selection?.dlcs.count,
                    message: resources.message, notes: resources.report?.notes ?? [])
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if resources.workspace == nil { Text(l("Choose a storage folder before playing.")).font(.caption).foregroundStyle(.secondary) }
                if resources.running { Button(l("Stop game")) { resources.stop() } }
                Spacer()
                Text(l(packedGameData ? "The game files are inside this App; they are read only."
                                    : "Files stay where they are. Keep the drive connected while playing."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 280)
            Form {
                if packedGameData {
                    Section(l("Game files")) {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(l("Bundled in this App")).font(.body.weight(.medium))
                                Text(l("Contents/Resources/romfs · nothing to select")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                } else {
                    Section(l("Game folder")) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(l(resources.folder == nil ? "No folder chosen" : "Searched, including every sub-folder"))
                                Text(l(resources.folder?.path ?? "Pick the folder that holds this game's files"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            }
                            Spacer()
                            Button(l(resources.folder == nil ? "Choose folder" : "Change")) { resources.chooseFolder() }
                                .disabled(resources.running || resources.busy)
                            Button(l("Rescan")) { resources.rescan() }
                                .disabled(resources.folder == nil || resources.running || resources.busy)
                        }
                    }
                    Section(l("Found automatically")) {
                        row("Base game", resources.selection?.base ?? resources.report?.bases.first)
                        row("Update (optional)", resources.selection?.update ?? resources.report?.updates.first)
                        row("Console keys", resources.selection?.keys ?? resources.report?.keyFiles.first)
                        if resources.busy { ProgressView().controlSize(.small) }

                    }
                    if !resources.conflict.isEmpty {
                        Section(l(resources.report?.state == .updateMismatch ? "Choose what to run" : "More than one match")) {
                            ForEach(resources.conflict) { combination in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(l(combination.base.name)).font(.body).lineLimit(1)
                                        Text(l(combination.update?.name ?? "Base game only")).font(.caption)
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Button(l(combination.update == nil ? "Use base only" : "Use these")) { resources.choose(combination) }
                                        .disabled(resources.busy || resources.running)
                                }
                            }
                        }
                    }
                }
                SettingsList(m: settings).disabled(resources.running)
                LauncherLanguageRow()
                Section(l("Storage location")) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(l("Saves and logs"))
                            Text(l(resources.workspace?.path ?? "Not selected · choose a folder on your game drive"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        Button(l(resources.workspace == nil ? "Choose folder" : "Change")) { resources.chooseWorkspace() }.disabled(resources.running || resources.busy)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l("MOD folder (optional)"))
                            Text(l(resources.modsFolder?.path ?? "Not selected · MODs will not be loaded"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        Button(l(resources.modsFolder == nil ? "Choose folder" : "Change")) { resources.chooseModsFolder() }
                            .disabled(resources.running || resources.busy)
                        if resources.modsFolder != nil {
                            Button(l("Clear")) { resources.clearModsFolder() }.disabled(resources.running || resources.busy)
                        }
                    }
                    Text(l("Choose the MOD resource folder. Choose mods/romfs or the folder containing the individual MODs."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let problem = resources.modsProblem {
                        Text(l(problem)).font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        about = true
                    } label: {
                        HStack {
                            Label(l("About Touchline 23"), systemImage: "info.circle")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                }
            }.formStyle(.grouped)
        }.frame(minWidth: 900, minHeight: 660)
            .sheet(isPresented: $about) { AboutTouchlineView().environmentObject(language) }
    }
    private func row(_ title: String, _ file: ResourceFile?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: resources.icon(file)).font(.title3)
                .foregroundStyle(file == nil ? Color.secondary : (resources.report?.ready == true ? Color.green : Color.blue))
            VStack(alignment: .leading, spacing: 4) {
                Text(l(title)).font(.body.weight(.medium))
                Text(l(resources.detail(file))).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
    // The game has its own process and window. Closing the launcher must not
    // implicitly quit it; explicit Quit still ends the active session.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if ActiveSession.process?.isRunning == true {
            ActiveSession.note("Launcher termination requested; ending game session")
            ActiveSession.process?.terminate()
        }
    }
}

// DM_LAUNCHER=0 starts the game as soon as it can, the switch the iPhone launcher
// has: the screen is then only a status line, for a machine that runs one game.
private let launcherOff = ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0"

@MainActor
private struct AutoStart: View {
    @ObservedObject var settings: LauncherModel
    @ObservedObject var resources: Resources
    @EnvironmentObject private var language: LanguagePreferences
    private func l(_ text: String) -> String { GUIText.launcher(text, language: language.language) }
    var body: some View {
        VStack(spacing: 14) {
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Touchline 23").font(.title2.bold())
            ResourceStatusView(external: !packedGameData, busy: resources.busy,
                verified: resources.ready && !resources.hasError, count: resources.selection?.dlcs.count,
                message: resources.message, notes: resources.report?.notes ?? [])
            if resources.running { Button(l("Stop game")) { resources.stop() } }
        }.padding(28).frame(minWidth: 460, minHeight: 200)
            .onAppear { resources.autoplay(settings) }
    }
}

@main
struct MacPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings: LauncherModel
    @StateObject private var resources = Resources()
    @StateObject private var language = LanguagePreferences(key: "launcher.interface-language.v1")
    init() {
        let url = Bundle.main.resourceURL!.appendingPathComponent("profile/launcher.json")
        let file = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SettingsFile.self, from: $0) }
        _settings = StateObject(wrappedValue: LauncherModel(file?.settings ?? []))
    }
    var body: some Scene {
        Window(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Touchline 23", id: "launcher") {
            Group {
                if launcherOff { AutoStart(settings: settings, resources: resources) }
                else { MacLauncher(settings: settings, resources: resources) }
            }
            .environmentObject(language)
            .environment(\.locale, Locale(identifier: language.language.resolved.rawValue))
        }
            .defaultSize(width: 1000, height: 760).windowResizability(.contentMinSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
