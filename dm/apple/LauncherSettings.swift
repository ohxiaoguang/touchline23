// SPDX-License-Identifier: MIT
// Shared iOS/macOS settings schema, persistence and controls.
import SwiftUI
import Foundation
import Darwin

struct Setting: Decodable, Identifiable {
    let env, kind, label, note, def: String
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    // The meta keys dm/games/settings.py writes (docs: settings.tsv's header). They are optional on purpose: a
    // launcher.json from a build that did not know them still reads, and a key this reader does not know is ignored.
    var section: String?   // the heading it is drawn under: Game, Controls or Performance
    var level: String?   // "basic": shown first; without it the front end decides
    var needs: String?   // "<VAR>=<value>": drawn only while that setting has that value
    var on, off: String?   // what a toggle writes; nil means 1 / 0, which is what a row without values writes
    var id: String { env }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", options, min, max, step, section, level, needs, on, off }

    /// The value a toggle writes when it is on. A row that does not name one writes 1 / 0, as it always did.
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    /// The value this row accepts for `v`, in the row's own vocabulary, or nil when it is not one of its values.
    /// A toggle also takes the 1 / 0 an older launcher saved, so a saved choice survives this change; a row that
    /// writes on / off never hands 1 / 0 to the host, whose DM_FPS_HOLD reads anything but "off" as on.
    func accepts(_ v: String) -> String? {
        if kind == "toggle" {
            if v == onValue || v == offValue { return v }
            if v == "1" { return onValue }
            if v == "0" { return offValue }
            return nil
        }
        return options == nil || options!.contains { $0[0] == v } ? v : nil
    }
}
struct SettingsFile: Decodable { let settings: [Setting] }

/// A heading and the rows under it.
struct SettingSection: Identifiable {
    let id: String
    let title: String?
    var rows: [Setting]
}


final class LauncherModel: ObservableObject {
    private let defaults: UserDefaults
    let settings: [Setting]
    let fromFile: Set<String>   // set by an env file: shown, not changed
    @Published var values: [String: String] = [:]

    init(_ settings: [Setting], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if os(iOS)
        // The three iPhone/iPad virtual-gamepad settings. They are separate switches on purpose: whether the game
        // receives the touch screen, whether the overlay is drawn, and whether pressing it vibrates are different
        // questions, each with its own environment variable (DM_TOUCH_INPUT, DM_TOUCH_CONTROLS, DM_TOUCH_HAPTICS).
        let settings = settings + [
            Setting(env: "DM_TOUCH_INPUT", kind: "toggle", label: "Enable touchscreen input", note: "The game receives taps, drags and gestures. The virtual controller and this screen keep working when it is off.", def: "1", options: nil, min: nil, max: nil, step: nil),
            Setting(env: "DM_TOUCH_CONTROLS", kind: "toggle", label: "Show virtual controller", note: "External controllers and game touch input remain available.", def: "1", options: nil, min: nil, max: nil, step: nil),
            Setting(env: "DM_RIGHT_STICK_VISIBLE", kind: "toggle", label: "Show right stick in 3D mode", note: "Changes appearance only. The right stick is drawn in the 3D layout.", def: "0", options: nil, min: nil, max: nil, step: nil)]
        #endif
        #if os(macOS)
        // Touch feedback is the virtual gamepad's haptic click (dm/ios/Sources/DmGamepad.m is its only reader), so a
        // Mac launcher must not offer it even when a profile's settings name it. The three switches above are added
        // under #if os(iOS) and never reach this list. Game rumble (DM_RUMBLE) stays: a controller on a Mac rumbles.
        let settings = settings.filter { $0.env != "DM_TOUCH_HAPTICS" && $0.env != "DM_MOUSE_HID" } + [
            Setting(env: "DM_MOUSE_HID", kind: "toggle", label: "Enable native Mouse HID (experimental)", note: "Keeps left-button touch emulation. The game must read Switch Mouse HID; this does not add a game-specific pointer bridge.", def: "0", options: nil, min: nil, max: nil, step: nil)]
        #endif
        self.settings = settings
        fromFile = Set((ProcessInfo.processInfo.environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        for s in settings {
            if fromFile.contains(s.env), let v = ProcessInfo.processInfo.environment[s.env] { values[s.env] = v; continue }
            let saved = defaults.string(forKey: "launcher." + s.env)
            values[s.env] = saved.flatMap { s.accepts($0) } ?? s.def   // a saved choice the game no longer offers: its default
        }
    }

    func set(_ s: Setting, _ value: String) {
        guard !fromFile.contains(s.env) else { return }
        values[s.env] = value
        defaults.set(value, forKey: "launcher." + s.env)
    }
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.set(s, $0) }) }
    // Editable while the virtual controller is on, in every layout: the saved layout only decides whether the stick is
    // drawn (3D yes, 2D and Tap no), so a setting changed in 2D or Tap must not be locked out until the player switches.
    var rightStickSettingEnabled: Bool {
        values["DM_TOUCH_CONTROLS"] != "0"
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default)
    func apply() {
        for s in settings {
            let v = values[s.env] ?? s.def
            if fromFile.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (env file)\n", stderr); continue }
            defaults.set(v, forKey: "launcher." + s.env)
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\n", stderr)
        }
    }

    // The headings the screen is drawn with, in the order settings.tsv lists them. A row whose `needs` names a value
    // another row does not currently have is left out, and `level=basic` rows come first inside their heading - which
    // is what that key means ("a setting a front end shows first").
    var sections: [SettingSection] {
        var out: [SettingSection] = []
        for s in settings where shown(s) {
            let title = s.section
            if let i = out.firstIndex(where: { $0.title == title }) { out[i].rows.append(s) }
            else { out.append(SettingSection(id: title ?? "", title: title, rows: [s])) }
        }
        for i in out.indices where out[i].rows.contains(where: { $0.level == "basic" }) {
            out[i].rows = out[i].rows.filter { $0.level == "basic" } + out[i].rows.filter { $0.level != "basic" }
        }
        return out
    }
    /// Whether a row is drawn: `needs=<VAR>=<value>` holds only while that variable has that value. A setting that
    /// needs nothing is always drawn, and a malformed `needs` is not a reason to hide a setting.
    func shown(_ s: Setting) -> Bool {
        guard let need = s.needs, let eq = need.firstIndex(of: "=") else { return true }
        return values[String(need[need.startIndex..<eq])] == String(need[need.index(after: eq)...])
    }
}

struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel
    @EnvironmentObject private var language: LanguagePreferences
    private func l(_ s: String) -> String { GUIText(key: s).render(language.language) }
    var body: some View {
        let locked = m.fromFile.contains(s.env)
        VStack(alignment: .leading, spacing: 2) {
            switch s.kind {
            case "choice":
                Picker(l(s.label), selection: m.binding(s)) { ForEach(s.options ?? [], id: \.[0]) { Text(l($0[1])).tag($0[0]) } }
            case "range":
                let lo = s.min ?? 0, hi = s.max ?? 1
                let v = Binding<Double>(get: { Double(m.values[s.env] ?? s.def) ?? hi }, set: { m.set(s, String(format: "%.2f", $0)) })
                HStack {
                    Text(l(s.label))
                    Slider(value: v, in: lo...hi, step: s.step ?? 0.05)
                    Text("\(Int((v.wrappedValue * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                }
            default:
                // The row names the two values it writes (on/off, or 1/0 when it names none). The host reads this
                // variable itself: hle_nvn.c takes everything but "off" as on for DM_FPS_HOLD, so a switch that
                // wrote 1/0 would show off and still hold frames.
                Toggle(l(s.label), isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue },
                                                 set: { m.set(s, $0 ? s.onValue : s.offValue) }))
            }
            let note = locked ? (s.note.isEmpty ? "" : l(s.note) + " · ") + l("Set by an env file") : l(s.note)
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(locked || (s.env == "DM_RIGHT_STICK_VISIBLE" && !m.rightStickSettingEnabled))
    }
}

/// The settings of one game, under the headings settings.tsv gives them. A game whose rows carry no section is drawn
/// as the one list it used to be, so a launcher.json written before that column existed still fills the screen.
struct SettingsList: View {
    @ObservedObject var m: LauncherModel
    @EnvironmentObject private var language: LanguagePreferences
    var body: some View {
        ForEach(m.sections) { section in
            if let title = section.title {
                Section(GUIText(key: title).render(language.language)) { rows(section) }
            } else {
                Section { rows(section) }
            }
        }
    }
    private func rows(_ section: SettingSection) -> some View {
        ForEach(section.rows) { SettingRow(s: $0, m: m) }
    }
}



struct LauncherLanguageRow: View {
    @EnvironmentObject private var language: LanguagePreferences
    var body: some View {
        Picker(GUIText(key: "Interface language").render(language.language), selection: $language.language) {
            ForEach(InterfaceLanguage.allCases, id: \.self) { item in Text(item == .system ? GUIText(key: "System language").render(language.language) : item.displayName).tag(item) }
        }
    }
}

struct ResourceStatusView: View {
    let external, busy, verified: Bool
    let count: Int?
    let message: String
    let notes: [String]
    @EnvironmentObject private var language: LanguagePreferences
    private func l(_ text: GUIText) -> String { text.render(language.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l(busy ? "Checking the selected files…" : verified ? (external ? "Resources verified for this App." : "The game files are inside this App; they are read only.") : "Resources need attention. Open the diagnostics below."))
                .font(.footnote).foregroundStyle(verified ? Color.green : Color.secondary)
            Text(l(DLCDiscoveryText.summary(external: external, busy: busy, verified: verified, count: count)))
                .font(.footnote)
            Text(l("This count is discovery only, not a runtime loaded count.")).font(.caption2).foregroundStyle(.secondary)
            if !notes.isEmpty && !busy {
                Text(l("Resource notices: \(notes.count). Open diagnostics.")).font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup(l("Resource diagnostics")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(GUIText(key: message).render(language.language)).font(.caption)
                        ForEach(Array(notes.prefix(20).enumerated()), id: \.offset) { _, note in
                            Text(GUIText(key: note).render(language.language)).font(.caption)
                        }
                        if notes.count > 20 { Text(l("Showing the first 20 of \(notes.count) diagnostics.")).font(.caption2) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
            }
        }
    }
}
