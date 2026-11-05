"""The prewarm seed list a profile ships beside its shader map.

nvn_mtl.m's warm_worker reads it line by line and, for every line it has not already seen, loads the shader (S), builds
the render pipeline (R) or builds the compute pipeline (C). Two kinds of mistake cost the whole list its value and are
invisible in a build:

  * a line the reader cannot parse or a key the shader map does not have - the row is skipped, so the pipeline it was
    meant to warm is compiled on the spot on the first frame that needs it, which is the stutter the list exists to
    avoid (the run logs "shader keys not in the shader map ... 0" when the list is clean);
  * a shader warmed twice - an S row for a compute shader, which the reader would load as a shader, next to the C row
    that builds the pipeline, or the same line repeated, which the reader skips by its own seen set and the list
    counts as warmed anyway.

The reader's own limits decide what is valid here: stage is `c[2].intValue`, so a vertex or fragment shader is 0 or 1,
and a compute shader belongs to C (the C branch warms it with stage 5 itself).
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
KEY = re.compile(r'[0-9a-f]{16}_b')
# sizeof(pso_skey): char vs[24] + char fs[24] + 4 bytes of flags + pso_fz_desc + pso_key, hex-encoded by pso_skey_hex.
PIPELINE_HEX = 864


def profiles():
    """-> [(profile dir, manifest rows)] for every profile that ships a prewarm list."""
    out = []
    for path in sorted((ROOT / 'dm/games').glob('*/pso_manifest.tsv')):
        rows = []
        for n, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            if not line.strip() or line.startswith('#'):
                continue
            rows.append((n, line.split('\t')))
        out.append((path.parent, rows))
    return out


def shader_keys(profile):
    """The 16-hex keys a profile's shader map names (column 3; column 0 is the module file)."""
    keys = set()
    for line in (profile / 'shader_map.tsv').read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        keys.add(line.split('\t')[3])
    return keys


class PrewarmList(unittest.TestCase):
    def test_there_is_one_to_check(self):
        self.assertTrue(profiles(), 'no profile ships a pso_manifest.tsv')

    def test_every_row_is_a_shape_the_reader_understands(self):
        for profile, rows in profiles():
            for n, c in rows:
                where = f'{profile.name}:{n}'
                self.assertIn(c[0], ('S', 'R', 'C'), f'{where}: unknown row type {c[0]!r}')
                if c[0] == 'S':
                    self.assertEqual(len(c), 3, f'{where}: S takes a key and a stage')
                    self.assertRegex(c[1], KEY, where)
                    self.assertIn(c[2], ('0', '1'), f'{where}: S stage {c[2]!r} is neither vertex (0) nor fragment (1)')
                elif c[0] == 'C':
                    self.assertEqual(len(c), 2, f'{where}: C takes a key')
                    self.assertRegex(c[1], KEY, where)
                else:
                    self.assertEqual(len(c), 2, f'{where}: R takes the pipeline key')
                    self.assertRegex(c[1], r'[0-9a-f]{%d}' % PIPELINE_HEX, where)

    def test_no_row_is_warmed_twice(self):
        for profile, rows in profiles():
            seen = {}
            for n, c in rows:
                self.assertNotIn((c[0], c[1]), seen,
                                 f'{profile.name}:{n}: {c[0]} {c[1]} is already warmed on line {seen.get((c[0], c[1]))}')
                seen[(c[0], c[1])] = n
            # A compute shader is warmed by its C row; an S row for it would load the same shader as a shader first.
            for n, c in rows:
                if c[0] == 'S' and c[2] not in ('0', '1'):
                    self.fail(f'{profile.name}:{n}: compute shader {c[1]} listed as S; the C row warms it')

    def test_every_key_exists_in_the_shader_map(self):
        for profile, rows in profiles():
            keys = shader_keys(profile)
            self.assertTrue(keys, profile.name)
            for n, c in rows:
                if c[0] == 'R':
                    raw = bytes.fromhex(c[1])
                    names = [raw[0:24].rstrip(b'\0').decode('ascii'), raw[24:48].rstrip(b'\0').decode('ascii')]
                else:
                    names = [c[1]]
                for name in filter(None, names):
                    if c[0] == 'R' and not name.endswith('_b'):
                        continue        # no shader of that stage: the reader builds the pipeline with what it has
                    self.assertIn(name[:-2], keys,
                                  f"{profile.name}:{n}: {c[0]} names {name}, which this build's shader map does not have")

    def test_the_rows_add_up(self):
        for profile, rows in profiles():
            counts = {t: sum(1 for _, c in rows if c[0] == t) for t in ('S', 'R', 'C')}
            self.assertEqual(sum(counts.values()), len(rows), f'{profile.name}: a row is not S, R or C')
            for kind, count in counts.items():
                self.assertGreater(count, 0, f'{profile.name}: no {kind} row, so the list warms nothing of that kind')


if __name__ == '__main__':
    unittest.main()
