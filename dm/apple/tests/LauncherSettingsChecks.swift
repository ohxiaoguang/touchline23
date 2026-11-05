import Foundation
@main struct SettingsChecks {
    @MainActor static func main() {
        let suite = "org.nxnative.launcher-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pad = Setting(env: "DM_TOUCH_CONTROLS", kind: "toggle", label: "Show virtual controller", note: "", def: "1", options: nil, min: nil, max: nil, step: nil)
        let right = Setting(env: "DM_RIGHT_STICK_VISIBLE", kind: "toggle", label: "Show right stick in 3D mode", note: "", def: "0", options: nil, min: nil, max: nil, step: nil)
        let model = LauncherModel([pad, right], defaults: defaults)
        assert(model.values[pad.env] == "1" && model.values[right.env] == "0")
        model.binding(pad).wrappedValue = "0"
        model.binding(right).wrappedValue = "1"
        let restored = LauncherModel([pad, right], defaults: defaults)
        assert(restored.values[pad.env] == "0" && restored.values[right.env] == "1")
        // The saved layout decides whether the stick is drawn, never whether the setting can be edited: Tap (2), 2D (0)
        // and 3D (1) all leave it editable while the virtual controller is on.
        restored.set(pad, "1")
        for layout in [0, 1, 2] {
            defaults.set(layout, forKey: "DmPadLayout")
            assert(restored.rightStickSettingEnabled)
        }
        restored.set(pad, "0")
        assert(!restored.rightStickSettingEnabled)   // virtual controller off: its stick settings go with it
        restored.set(pad, "1")
        setenv("DM_ENV_FILE_KEYS", "DM_TOUCH_CONTROLS", 1)
        setenv("DM_TOUCH_CONTROLS", "0", 1)
        let locked = LauncherModel([pad, right], defaults: defaults)
        locked.set(pad, "1")
        assert(locked.values[pad.env] == "0")
        assert(!locked.rightStickSettingEnabled)
        // Enable touchscreen input is a switch of its own: on by default, persisted like the others, and it never
        // depends on the overlay's switch (that one may be off while the game still gets touches, and the reverse).
        let input = Setting(env: "DM_TOUCH_INPUT", kind: "toggle", label: "Enable touchscreen input", note: "", def: "1", options: nil, min: nil, max: nil, step: nil)
        let suite2 = "org.nxnative.launcher-input." + UUID().uuidString
        let d2 = UserDefaults(suiteName: suite2)!
        defer { d2.removePersistentDomain(forName: suite2) }
        unsetenv("DM_TOUCH_INPUT"); unsetenv("DM_ENV_FILE_KEYS")
        let fresh = LauncherModel([input, pad], defaults: d2)
        assert(fresh.values[input.env] == "1")                       // default on
        fresh.set(input, "0")
        assert(fresh.values[pad.env] == "1")                         // the overlay switch is untouched by it
        let kept = LauncherModel([input, pad], defaults: d2)
        assert(kept.values[input.env] == "0")                        // persisted for the next launch
        assert(kept.values[pad.env] == "1")
        #if os(macOS)
        // The virtual gamepad's haptic click is an iPhone/iPad setting; a Mac launcher must not list it, while the
        // game's own rumble stays (a controller on a Mac rumbles).
        let haptics = Setting(env: "DM_TOUCH_HAPTICS", kind: "toggle", label: "Touch feedback", note: "", def: "1", options: nil, min: nil, max: nil, step: nil)
        let rumble = Setting(env: "DM_RUMBLE", kind: "toggle", label: "Game rumble", note: "", def: "1", options: nil, min: nil, max: nil, step: nil)
        let mac = LauncherModel([haptics, rumble], defaults: d2)
        assert(!mac.settings.contains { $0.env == "DM_TOUCH_HAPTICS" })
        assert(mac.settings.contains { $0.env == "DM_RUMBLE" })
        let mouse = mac.settings.first { $0.env == "DM_MOUSE_HID" }!
        assert(mac.values[mouse.env] == "0")
        mac.set(mouse, "1")
        let restoredMouse = LauncherModel([], defaults: d2)
        assert(restoredMouse.values[mouse.env] == "1")
        assert(restoredMouse.settings.filter { $0.env == "DM_MOUSE_HID" }.count == 1)
        #endif
        // The meta columns dm/games/settings.py writes, decoded from a launcher.json exactly as the packagers write it.
        // SHOW_FPS (not basic) is listed before OPMODE (basic) inside "Game" so the basic-first order is really tested.
        let json = """
        {"schema":1,"game":"01001C8016B4E000","settings":[
         {"env":"DM_FPS_HOLD","kind":"toggle","section":"Performance","label":"Hold frames when late","note":"","default":"on","on":"on","off":"off"},
         {"env":"DM_RUMBLE","kind":"toggle","section":"Controls","label":"Game rumble","note":"","default":"1","level":"basic","on":"1","off":"0"},
         {"env":"DM_RUMBLE_GAIN","kind":"range","section":"Controls","label":"Rumble strength","note":"","default":"1.0","needs":"DM_RUMBLE=1","min":0,"max":3,"step":0.1},
         {"env":"DM_SHOW_FPS","kind":"toggle","section":"Game","label":"Frame-rate counter","note":"","default":"0","on":"1","off":"0"},
         {"env":"DM_OPMODE","kind":"choice","section":"Game","label":"Console mode","note":"","default":"1","level":"basic","options":[["1","Docked"],["0","Handheld"]]}
        ]}
        """
        let suite3 = "org.nxnative.launcher-meta." + UUID().uuidString
        let d3 = UserDefaults(suiteName: suite3)!
        defer { d3.removePersistentDomain(forName: suite3) }
        let rows = try! JSONDecoder().decode(SettingsFile.self, from: Data(json.utf8)).settings
        assert(rows.count == 5)
        let hold = rows[0], rumRow = rows[1], gainRow = rows[2], modeRow = rows[4]
        assert(hold.section == "Performance" && hold.on == "on" && hold.off == "off" && hold.def == "on")
        assert(gainRow.needs == "DM_RUMBLE=1" && modeRow.level == "basic" && rumRow.level == "basic")
        // A launcher.json written before these columns existed still reads: the keys are optional and a toggle that
        // names no values keeps writing 1 / 0.
        let old = try! JSONDecoder().decode(SettingsFile.self, from: Data(#"{"settings":[{"env":"DM_SHOW_FPS","kind":"toggle","label":"Frame-rate counter","note":"","default":"0"}]}"#.utf8)).settings
        assert(old.count == 1 && old[0].section == nil && old[0].onValue == "1" && old[0].offValue == "0" && old[0].def == "0")
        // FPS Hold: the switch is on for the value the row writes as on. hle_nvn.c reads the variable itself and takes
        // everything but "off" as on, so the value written when the switch goes off has to be exactly that word.
        func hostHolds(_ v: String) -> Bool { v != "off" }   // hle_nvn.c: h = e ? strcmp(e, "off") != 0 : DM_GAME_FPS_HOLD
        let meta = LauncherModel(rows, defaults: d3)
        assert(meta.values[hold.env] == "on")                        // default on shows as on, not as off
        assert(hold.accepts("on") == "on" && hold.accepts("off") == "off")
        assert(hold.accepts("1") == "on" && hold.accepts("0") == "off")   // a value an older build saved
        assert(hold.def == hold.onValue && hostHolds(hold.def))      // the untouched switch matches what the host does
        meta.set(hold, hold.offValue)
        assert(meta.values[hold.env] == "off" && !hostHolds("off"))   // off really reaches the host as off
        meta.set(hold, hold.onValue)
        assert(hostHolds(meta.values[hold.env]!))
        d3.set("0", forKey: "launcher." + hold.env)                   // saved by the build that wrote 1 / 0
        let migrated = LauncherModel([hold], defaults: d3)
        assert(migrated.values[hold.env] == "off")                    // read back in this row's own vocabulary
        d3.set("on", forKey: "launcher." + hold.env)
        assert(LauncherModel([hold], defaults: d3).values[hold.env] == "on")   // and it survives a restart
        // Headings, and a sub-setting drawn only while the row it needs has that value.
        let grouped = LauncherModel(rows, defaults: d3)
        // The profile's headings come first, in settings.tsv's order; the switches the launcher adds itself carry no
        // section and keep their own group at the end (DM_MOUSE_HID here, the touch switches on iOS).
        assert(grouped.sections.prefix(3).map { $0.title } == ["Performance", "Controls", "Game"])
        assert(grouped.sections.dropFirst(3).allSatisfy { $0.title == nil })
        func group(_ title: String) -> [String] {
            grouped.sections.first { $0.title == title }?.rows.map(\.env) ?? []
        }
        assert(group("Performance") == ["DM_FPS_HOLD"])
        assert(group("Game") == ["DM_OPMODE", "DM_SHOW_FPS"])                          // basic first, order kept otherwise
        assert(group("Controls") == ["DM_RUMBLE", "DM_RUMBLE_GAIN"])
        grouped.set(rumRow, rumRow.offValue)
        assert(group("Controls") == ["DM_RUMBLE"])                                     // rumble off: strength goes with it
        grouped.set(rumRow, rumRow.onValue)
        assert(group("Controls") == ["DM_RUMBLE", "DM_RUMBLE_GAIN"])
        print("Launcher defaults, persistence, editability independent of layout, separate touch input switch and platform filter checks passed")
        print("Launcher meta columns, FPS Hold on/off and the host's own reading of it, legacy 1/0 migration, sections and needs checks passed")
    }
}
