"""The settings table, what settings.py writes from it, and what the two front ends can read back.

dm/games/settings.py turns dm/games/settings.tsv into the launcher.json a front end draws; dm/apple/LauncherSettings.swift
is that front end's model, shared by the Mac and the iOS launcher. The two sides agree only by convention - nothing
type-checks the JSON across the language boundary - so these checks pin the convention down:

  * a toggle names the two values it writes, and its default is one of them;
  * a value the host has to recognise as "off" is the word the host actually compares against;
  * every column settings.py writes is a column the Swift model decodes, and the switch uses the row's values instead of
    a hard-coded 1 / 0 (the DM_FPS_HOLD defect: a switch that showed off and wrote "0" while hle_nvn.c reads anything
    but "off" as on).

Synthetic inputs only: no game files, and the control data is absent, so the language row drops out exactly as it does
for a build without control.nacp.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SETTINGS_PY = ROOT / 'dm/games/settings.py'
SETTINGS_TSV = ROOT / 'dm/games/settings.tsv'
SWIFT = ROOT / 'dm/apple/LauncherSettings.swift'
GAME_ID = '01001C8016B4E000'


def rows():
    """-> [(line number, [columns])] of settings.tsv, comments and blank lines skipped."""
    out = []
    for n, line in enumerate(SETTINGS_TSV.read_text(encoding='utf-8').splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        out.append((n, line.split('\t') + [''] * 9))
    return out


def launcher_json(platform):
    """settings.py's output for this profile, as the packagers produce it."""
    with tempfile.TemporaryDirectory() as tmp:
        patched = Path(tmp) / 'patched'
        patched.mkdir()
        # The rewriter's key table: empty, so the rows shown "when the rewriter has that key" stay out.
        (patched / 'main.fixups.tsv').write_text('# KEY\tvalue\n')
        out = Path(tmp) / 'launcher.json'
        env = dict(os.environ, SETTINGS_PLATFORM=platform, DM_GAME=GAME_ID)
        p = subprocess.run([sys.executable, str(SETTINGS_PY), GAME_ID, str(patched),
                            str(Path(tmp) / 'nonexistent/control.nacp'), str(out)],
                           capture_output=True, text=True, env=env)
        if p.returncode:
            raise AssertionError(f'settings.py failed for {platform}: {p.stderr.strip()}')
        return json.loads(out.read_text())


class ToggleValues(unittest.TestCase):
    def test_every_toggle_names_the_two_values_it_writes(self):
        for n, c in rows():
            var, kind, values, default = c[0], c[1], c[2], c[3]
            if kind != 'toggle':
                continue
            on, off = ('1', '0') if values == '-' else tuple(values.split('/'))
            self.assertTrue(on and off, f'settings.tsv:{n} {var}: a toggle needs an on and an off value')
            self.assertNotEqual(on, off, f'settings.tsv:{n} {var}: on and off are the same value')
            # The default is a value, the profile's macro, the build's switch or a platform pair: all of them land on
            # one of the two values, which test_the_written_default_is_one_of_the_values checks on the real output.
            self.assertTrue(default, f'settings.tsv:{n} {var}: a toggle needs a default')

    def test_the_written_default_is_one_of_the_values_the_front_end_draws(self):
        for platform in ('mac', 'ios'):
            for s in launcher_json(platform)['settings']:
                if s['kind'] != 'toggle':
                    continue
                self.assertIn('on', s, f"{platform}: {s['env']} is a toggle without an on value")
                self.assertIn('off', s, f"{platform}: {s['env']} is a toggle without an off value")
                self.assertIn(s['default'], (s['on'], s['off']),
                              f"{platform}: {s['env']} defaults to {s['default']!r}, which its switch cannot show")

    def test_fps_hold_is_on_by_default_and_its_off_is_really_off(self):
        for platform in ('mac', 'ios'):
            row = next(s for s in launcher_json(platform)['settings'] if s['env'] == 'DM_FPS_HOLD')
            self.assertEqual((row['on'], row['off'], row['default']), ('on', 'off', 'on'), platform)
            self.assertEqual(row['section'], 'Performance')

    def test_the_host_compares_against_the_word_the_row_writes(self):
        """A toggle whose off value is not 0 is off only if the host tests that exact string."""
        sources = {}
        for pattern in ('dm/**/*.c', 'dm/**/*.m', 'dm/**/*.h'):
            for path in ROOT.glob(pattern):
                if 'tests' not in path.parts:
                    sources[path] = path.read_text(encoding='utf-8', errors='replace')
        checked = 0
        for n, c in rows():
            var, kind, values = c[0], c[1], c[2]
            if kind != 'toggle' or values == '-':
                continue
            off = values.split('/')[1]
            if off == '0':
                continue                      # 0 is an ordinary value: nothing to match in the host
            readers = [p for p, text in sources.items() if f'getenv("{var}")' in text]
            self.assertTrue(readers, f'settings.tsv:{n}: nothing in dm/ reads {var}')
            self.assertTrue(any(f'"{off}"' in sources[p] for p in readers),
                            f'{var} writes {off!r} but no reader of it compares against that string: '
                            f'{", ".join(str(p.relative_to(ROOT)) for p in readers)}')
            checked += 1
        self.assertGreater(checked, 0, 'no toggle writes a word other than 0, so this check never ran')


class FrontEndAgreement(unittest.TestCase):
    def test_the_swift_model_decodes_every_column_settings_py_writes(self):
        source = SWIFT.read_text()
        keys = re.search(r'enum CodingKeys: String, CodingKey \{([^}]*)\}', source)
        self.assertIsNotNone(keys, 'LauncherSettings.swift has no CodingKeys')
        decoded = set()
        for part in keys[1].split(','):
            part = part.strip().removeprefix('case ').strip()
            name = part.partition('=')[2].strip().strip('"') if '=' in part else part
            if name:
                decoded.add(name)
        # The keys settings.py puts in its meta column, plus the two a toggle needs, and the base block it may add.
        meta = re.search(r'^META = \{(.*?)^\}', (ROOT / 'dm/games/settings.py').read_text(), re.M | re.S)[1]
        for key in re.findall(r"^\s*'([a-z]+)':", meta, re.M):
            self.assertIn(key, decoded, f'LauncherSettings.swift does not decode {key!r}, which settings.py writes')
        for key in ('on', 'off'):
            self.assertIn(key, decoded, f'LauncherSettings.swift does not decode {key!r}')
        self.assertIn('section', decoded)

    def test_a_toggle_switch_writes_the_rows_own_values(self):
        source = SWIFT.read_text()
        start = source.index('struct SettingRow')
        row = source[start:source.index('struct SettingsList', start)]
        self.assertIn('Toggle(', row)
        self.assertNotIn('"1" : "0"', row, 'the switch still hard-codes 1 / 0')
        self.assertIn('onValue', row)
        self.assertIn('offValue', row)

    def test_both_launchers_draw_through_the_shared_list(self):
        for name in ('dm/macos/Launcher.swift', 'dm/ios/Sources/Launcher.swift'):
            source = (ROOT / name).read_text()
            self.assertIn('SettingsList(m:', source, f'{name} does not draw the grouped settings')
            self.assertNotIn('ForEach(m.settings)', source, f'{name} still draws a flat list')
            self.assertNotIn('ForEach(settings.settings)', source, f'{name} still draws a flat list')

    def test_every_platform_gets_the_rows_it_can_use(self):
        mac = launcher_json('mac')
        ios = launcher_json('ios')
        self.assertEqual(mac['schema'], 1)
        for s in mac['settings']:
            self.assertIn(s['section'], ('Game', 'Controls', 'Performance'), s['env'])
        self.assertIn('DM_FULLSCREEN', [s['env'] for s in mac['settings']])
        self.assertNotIn('DM_FULLSCREEN', [s['env'] for s in ios['settings']])
        self.assertNotIn('DM_PICTURE_FIT', [s['env'] for s in mac['settings']])
        self.assertIn('DM_PICTURE_FIT', [s['env'] for s in ios['settings']])
        # A sub-setting names a row that exists and a value that row really takes.
        values = {s['env']: s for s in mac['settings']}
        for s in mac['settings'] + ios['settings']:
            need = s.get('needs')
            if not need:
                continue
            var, _, want = need.partition('=')
            self.assertIn(var, values, f"{s['env']} needs {var}, which no row sets")
            row = values[var]
            taken = {row.get('on'), row.get('off')} - {None} if row['kind'] == 'toggle' else \
                {o[0] for o in row.get('options') or []}
            self.assertIn(want, taken, f"{s['env']} needs {var}={want}, which it never takes")


if __name__ == '__main__':
    unittest.main()
