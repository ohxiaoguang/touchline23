"""The build ID check on a reused module directory (--patched).

dm/tools/patch_nso.py records the build ID of the module it rewrote in that module's fixups table, read from the NSO
header. Everything a profile pins to a build depends on it: the rewriter's fixed addresses and observation gates, the
display version row, and the host's module_t.build_id checks. A directory left over from another build would run all of
that against code the addresses were not found in, so touchline_build.py refuses it instead of building.

These checks use a synthetic profile and a synthetic module table: no game files.
"""
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import touchline_build as tb  # noqa: E402

MAIN_1_0_3 = '4b713267a882da35b4789a5e45823ac4'
MAIN_1_0_0 = 'da9da20e1649759ab2e3ebfbd6307c11'
SDK = '43211771ed39e7fcef03d88e27091831'


class Game:
    """The part of dm/games/game.py this check uses."""
    id = '01001C8016B4E000'

    def __init__(self, builds, modules=('main', 'sdk')):
        self._builds, self._modules = builds, list(modules)

    def builds(self):
        return self._builds

    def words(self, key, default=''):
        return list(self._modules) if key == 'modules' else default


class ModuleBuildId(unittest.TestCase):
    def table(self, root, name, build_id):
        """A module directory as patch_nso.py leaves it: the rewriter's header, then its rows."""
        header = '# KEY\tvalue\n' + (f'# BUILD_ID\t{build_id}\n' if build_id else '')
        (Path(root) / (name + '.fixups.tsv')).write_text(header)
        (Path(root) / (name + '.patched.bin')).write_bytes(b'\0')

    def test_the_id_comes_from_the_table_the_rewriter_wrote(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.table(tmp, 'main', MAIN_1_0_3)
            self.assertEqual(tb.module_build_id(tmp, 'main'), MAIN_1_0_3)
            self.assertIsNone(tb.module_build_id(tmp, 'sdk'))   # no table, no ID - not a guess

    def test_a_declared_build_passes(self):
        game = Game({'v196608': {'display': '1.0.3', 'main': MAIN_1_0_3, 'sdk': SDK},
                     'v0': {'display': '1.0.0', 'main': MAIN_1_0_0, 'sdk': SDK}})
        with tempfile.TemporaryDirectory() as tmp:
            self.table(tmp, 'main', MAIN_1_0_3)
            self.table(tmp, 'sdk', SDK)
            self.assertTrue(tb.check_module_builds(tmp, ['main', 'sdk'], game))

    def test_an_older_declared_build_also_passes(self):
        """The profile ships both retail versions; the host picks the row by build ID."""
        game = Game({'v196608': {'display': '1.0.3', 'main': MAIN_1_0_3, 'sdk': SDK},
                     'v0': {'display': '1.0.0', 'main': MAIN_1_0_0, 'sdk': SDK}})
        with tempfile.TemporaryDirectory() as tmp:
            self.table(tmp, 'main', MAIN_1_0_0)
            self.table(tmp, 'sdk', SDK)
            self.assertTrue(tb.check_module_builds(tmp, ['main', 'sdk'], game))

    def test_an_undeclared_build_stops_the_build_and_says_why(self):
        game = Game({'v196608': {'display': '1.0.3', 'main': MAIN_1_0_3, 'sdk': SDK}})
        with tempfile.TemporaryDirectory() as tmp:
            self.table(tmp, 'main', 'ffffffffffffffffffffffffffffffff')
            self.table(tmp, 'sdk', SDK)
            with self.assertRaises(tb.Failure) as caught:
                tb.check_module_builds(tmp, ['main', 'sdk'], game)
            message = str(caught.exception)
            self.assertIn('ffffffffffffffffffffffffffffffff', message)
            self.assertIn(MAIN_1_0_3, message)          # what the profile does declare
            self.assertIn('main', message)

    def test_a_table_without_a_build_id_is_refused(self):
        game = Game({'v196608': {'display': '1.0.3', 'main': MAIN_1_0_3, 'sdk': SDK}})
        with tempfile.TemporaryDirectory() as tmp:
            self.table(tmp, 'main', None)
            self.table(tmp, 'sdk', SDK)
            with self.assertRaises(tb.Failure) as caught:
                tb.check_module_builds(tmp, ['main', 'sdk'], game)
            self.assertIn('BUILD_ID', str(caught.exception))

    def test_the_comparison_ignores_case(self):
        game = Game({'v196608': {'display': '1.0.3', 'main': MAIN_1_0_3, 'sdk': SDK}})
        with tempfile.TemporaryDirectory() as tmp:
            self.table(tmp, 'main', MAIN_1_0_3.upper())
            self.table(tmp, 'sdk', SDK.upper())
            self.assertTrue(tb.check_module_builds(tmp, ['main', 'sdk'], game))

    def test_a_module_the_profile_does_not_version_is_left_alone(self):
        """No build row for it means nothing to compare; the rewriter still produced it from this game's ExeFS."""
        game = Game({'v196608': {'display': '1.0.3', 'main': MAIN_1_0_3}}, modules=('main', 'rtld'))
        with tempfile.TemporaryDirectory() as tmp:
            self.table(tmp, 'main', MAIN_1_0_3)
            self.table(tmp, 'rtld', '567cdd4c5251494c5cd70822e3ccc740')
            self.assertTrue(tb.check_module_builds(tmp, ['main', 'rtld'], game))


if __name__ == '__main__':
    unittest.main()
