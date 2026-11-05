#!/usr/bin/env python3
"""Build Touchline 23 (FIFA 23 Legacy Edition, Nintendo Switch) for macOS or iOS.

    ./scripts/build-mac.sh --nsp-dir "/path/to/fifa23"
    ./scripts/build-ios.sh --nsp-dir "/path/to/fifa23"

The game files are yours: this project extracts the ExeFS and the control data
from them, rewrites the two program modules, builds the Metal Shader library from
the game's EASF archives (or reuses a library a previous run built), compiles the
host, and packages an App or an unsigned IPA that carries no game data.

Stages, all rooted at this repository:

  inputs   ExeFS and control.nacp (nx_extract, from your own NSP/XCI)
  modules  the rewriter's patched main/sdk (dm/tools/patch_nso.py)
  shaders  b-<chain> for macOS and for iOS (dm/gfx/tools/dmsh_build.py)
  package  macOS App (scripts/build_mac_app.py) or unsigned IPA (dm/ios/tools/build_ipa.sh)

Every stage can be skipped by pointing at output a previous run produced
(--exefs, --patched, --shaders, --ios-shaders, --shader-pack). Nothing is
downloaded, signed or installed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
GAME_ID = '01001C8016B4E000'
PROFILE = ROOT / 'dm/games' / GAME_ID
DEFAULT_APP_NAME = 'Touchline 23'
MAC_APP_NAME = 'Touchline23.app'
IOS_IPA_NAME = 'Touchline23.ipa'
# The project's own artwork, used for both targets; no game image is shipped.
# assets/app-icon/make_icon.swift draws them (iOS wants an opaque square and
# rounds it itself; macOS shows a rounded icon with clear corners).
PROJECT_ICON = ROOT / 'assets/app-icon/touchline23.png'
PROJECT_MAC_ICON = ROOT / 'assets/app-icon/touchline23-mac.png'
# Game data and private key material must never end up inside an artifact.
FORBIDDEN = ('.nsp', '.xci', '.nsz', '.ncz', '.xcz', '.nca', '.keys', '.tik')


class Failure(SystemExit):
    def __init__(self, message):
        super().__init__('[RED] ' + message)


def say(*parts):
    print('[%s]' % time.strftime('%H:%M:%S'), *parts, flush=True)


def run(argv, what, env=None, quiet=False):
    """Run one build step; stop with its last lines when it fails."""
    shown = ' '.join(str(a) for a in argv)
    try:
        if quiet:
            p = subprocess.run([str(a) for a in argv], env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, errors='replace')
        else:
            p = subprocess.run([str(a) for a in argv], env=env)
    except FileNotFoundError as exc:
        raise Failure('%s: %s is not installed' % (what, exc.filename)) from exc
    if p.returncode:
        tail = ''
        if quiet and p.stdout:
            tail = '\n' + '\n'.join(p.stdout.strip().splitlines()[-25:])
        raise Failure('%s failed (exit %d): %s%s' % (what, p.returncode, shown, tail))
    return p.stdout if quiet else ''


def tool_env():
    env = dict(os.environ)
    env.setdefault('LC_ALL', 'C')
    # nx_extract and dmsh_xlate are framework-dependent .NET apps: launched
    # directly they need DOTNET_ROOT, which Homebrew keeps out of PATH.
    if not env.get('DOTNET_ROOT'):
        binary = shutil.which('dotnet')
        root = None
        if binary:
            for parent in Path(binary).resolve().parents:
                if (parent / 'shared').is_dir():
                    root = parent
                    break
        if not root:
            for guess in ('/opt/homebrew/opt/dotnet/libexec', '/usr/local/share/dotnet',
                          '/usr/local/share/dotnet/x64'):
                if Path(guess, 'shared').is_dir():
                    root = Path(guess)
                    break
        if root:
            env['DOTNET_ROOT'] = str(root)
    return env


def need_tools(names, why):
    missing = [n for n in names if not shutil.which(n)]
    if missing:
        raise Failure('%s needs %s on PATH (missing: %s)' % (why, ' and '.join(names), ', '.join(missing)))


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def chain_version():
    text = (ROOT / 'dm/gfx/nvn/dmsh_chain.h').read_text()
    m = re.search(r'#define\s+DMSH_CHAIN\s+"([^"]+)"', text)
    if not m:
        raise Failure('dm/gfx/nvn/dmsh_chain.h has no DMSH_CHAIN')
    return m.group(1)


def profile():
    sys.path.insert(0, str(ROOT / 'dm/games'))
    import game  # noqa: E402
    return game.load(GAME_ID)


def bundle_id(g):
    value = g.get('bundle_id', '')
    if not value:
        raise Failure('%s/game.tsv has no bundle_id row' % g.dir)
    return value


# --------------------------------------------------------------------------
# inputs: ExeFS and control data
# --------------------------------------------------------------------------

def find_extractor(args, work):
    for candidate in (args.nx_extract, Path(os.environ.get('DM_NX_EXTRACT', '')),
                      work / 'tools/nx_extract/nx_extract', ROOT / 'build/tools/nx_extract/nx_extract'):
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    return build_extractor(work)


def build_extractor(work):
    out = work / 'tools/nx_extract'
    need_tools(['dotnet'], 'building nx_extract')
    out.mkdir(parents=True, exist_ok=True)
    say('building nx_extract into', out.relative_to(ROOT) if out.is_relative_to(ROOT) else out)
    run(['dotnet', 'build', ROOT / 'dm/tools/nx_extract/nx_extract.csproj', '-c', 'Release', '-o', out],
        'dotnet build dm/tools/nx_extract (the first run restores LibHac from NuGet)')
    binary = out / 'nx_extract'
    if not binary.is_file():
        raise Failure('dotnet build produced no %s' % binary)
    return binary


def probe_containers(folder, keys, work):
    """Ask the project's own reader which container is the base and which the update."""
    sys.path.insert(0, str(ROOT))
    from tools.packaging_gui import folder as nxfold
    from tools.nxrom.resourcefs import build_library
    library = work / 'tools/nxrom.dylib'
    library.parent.mkdir(parents=True, exist_ok=True)
    if not library.is_file():
        say('compiling the native container reader')
        build_library(library)
    title = int(GAME_ID, 16)
    base = update = None
    for path in nxfold.candidates(folder):
        try:
            facts = nxfold.probe(library, path, keys)
        except OSError as exc:
            if path.suffix.lower() in ('.nsz', '.ncz', '.xcz'):
                raise Failure('%s is compressed: decompress it first (nsz -D)' % path.name) from exc
            say('not a readable container, left alone:', path.name)
            continue
        if facts['title'] not in (title, title + 0x800):
            continue
        if facts['patched']:
            if update and update != path:
                raise Failure('two update containers in %s: pass --update' % folder)
            update = path
        else:
            if base and base != path:
                raise Failure('two base containers in %s: pass --base' % folder)
            base = path
    return base, update


def resolve_inputs(args, work):
    folder = args.nsp_dir
    if not folder:
        return args
    if not folder.is_dir():
        raise Failure('--nsp-dir %s is not a directory' % folder)
    if not args.keys and (folder / 'prod.keys').is_file():
        args.keys = folder / 'prod.keys'
    if not args.keys:
        raise Failure('--keys <prod.keys> is required to read the game containers '
                      '(none was given and %s has no prod.keys)' % folder)
    if args.base and args.update:
        return args
    say('identifying the base and update containers in', folder)
    base, update = probe_containers(folder, args.keys, work)
    if not args.base:
        if not base:
            raise Failure('no base container for %s in %s' % (GAME_ID, folder))
        args.base = base
    if not args.update:
        args.update = update
    say('base:', args.base.name)
    say('update:', args.update.name if args.update else 'none (the base game only)')
    return args


def extract(args, work):
    if args.exefs:
        exefs = Path(args.exefs)
        if (exefs / 'ExeFS').is_dir():
            exefs = exefs / 'ExeFS'
        if not exefs.is_dir():
            raise Failure('--exefs %s is not a directory' % args.exefs)
        return exefs
    if not args.base:
        raise Failure("give --nsp-dir (or --base and --keys) so the game's own ExeFS can be read, "
                      'or --exefs with an already extracted ExeFS')
    if not args.keys:
        raise Failure('--keys <prod.keys> is required to read the game containers')
    out = work / 'extract'
    binary = find_extractor(args, work)
    bundled = getattr(args, 'resource_backend', 'nsp') == 'directory' and args.target == 'mac'
    say('extracting ExeFS, control data and the RomFS (bundled App)' if bundled
        else 'extracting ExeFS and control data (no RomFS)', Path(args.base).name)
    out.mkdir(parents=True, exist_ok=True)
    argv = [binary, args.keys, args.base, args.update or '-', out]
    if not bundled:
        # External-resource App: never enumerate the multi-gigabyte data section.
        argv.append('--program-only')
    run(argv, 'nx_extract', env=tool_env())
    exefs = out / 'ExeFS'
    if not exefs.is_dir():
        raise Failure('nx_extract wrote no ExeFS to %s' % out)
    return exefs


def control_data(exefs, work, icon):
    """control.nacp names the App, versions the IPA, and lists game languages."""
    folder = exefs.parent if exefs else work / 'extract'
    nacp = folder / 'control.nacp'
    if not nacp.is_file():
        alt = work / 'extract/control.nacp'
        nacp = alt if alt.is_file() else None
    return nacp, (icon if icon and icon.is_file() else (PROJECT_ICON if PROJECT_ICON.is_file() else None))


# --------------------------------------------------------------------------
# modules, shaders, host
# --------------------------------------------------------------------------

def modules_ready(directory, names):
    return all((directory / (n + '.patched.bin')).is_file() and (directory / (n + '.fixups.tsv')).is_file()
               for n in names)


def module_build_id(patched, name):
    """The NSO build ID of one rewritten module, as patch_nso.py recorded it (# BUILD_ID in its fixups table).

    The rewriter reads it from the module's own header, so this is the module's identity and not its file name.
    """
    table = Path(patched) / (name + '.fixups.tsv')
    if not table.is_file():
        return None
    found = re.search(r'^# BUILD_ID\t([0-9a-fA-F]{32})$', table.read_text(errors='replace'), re.M)
    return found[1].lower() if found else None


def check_module_builds(patched, names, g):
    """Refuse a reused module directory that is not this game's, at a build this profile declares.

    Everything keyed on a build ID depends on it being right: the rewriter's fixed addresses and observation gates
    (the profile's patches.py, dm/tools/sdk_patches.py), nn::oe::GetDisplayVersion's build row, and the host's own
    module_t.build_id checks. A directory left over from another build would run those against code they were not
    found in, so the build stops here instead. The ID is read from the rewriter's table, never from a file name.
    """
    declared = {name: {b[name] for b in g.builds().values() if name in b} for name in names}
    for name in names:
        got = module_build_id(patched, name)
        if not got:
            raise Failure('%s/%s.fixups.tsv has no "# BUILD_ID" line: only a directory patch_nso.py wrote can be '
                          'reused, because its build ID is what this build is checked against' % (patched, name))
        known = declared[name]
        if not known:
            continue   # the profile declares no build row for this module: nothing to compare against
        if got not in known:
            raise Failure('--patched %s: %s is build %s, which %s does not declare (it has %s): rewrite the modules '
                          'from this game\'s own ExeFS, or pass the directory a working build of this version used'
                          % (patched, name, got, g.id, ', '.join(sorted(known))))
        say('%s build id' % name, got, '(declared)')
    return True


def rewrite(args, exefs, work, g):
    names = list(g.words('modules'))
    if args.patched:
        patched = Path(args.patched)
        if not modules_ready(patched, names):
            raise Failure('--patched %s has no rewritten %s' % (patched, ', '.join(names)))
        check_module_builds(patched, names, g)
        say('patched modules:', ', '.join(names), '(as given)')
        return patched
    if exefs is None:
        raise Failure('rewriting needs --exefs or --base (pass --patched to reuse modules)')
    out = work / 'patched'
    out.mkdir(parents=True, exist_ok=True)
    pack = args.font_python
    try:
        subprocess.run([pack, '-c', 'import capstone,lz4.block'], capture_output=True, check=True)
    except (subprocess.CalledProcessError, OSError):
        raise Failure('%s cannot import capstone and lz4.block (pip install capstone lz4), '
                      'or pass --patched' % pack)
    for name in names:
        src = exefs / name
        if not src.is_file():
            raise Failure('the ExeFS has no module %s' % src)
        say('rewriting', name, '(%.1f MB)' % (src.stat().st_size / 2 ** 20))
        run([pack, ROOT / 'dm/tools/patch_nso.py', src, out, name], 'patch_nso.py %s' % name)
    if not modules_ready(out, names):
        raise Failure('the rewriter did not write every module into %s' % out)
    return out


def library_under(path, chain):
    path = Path(path)
    if path.name == 'b-' + chain and path.is_dir():
        return path
    for candidate in (path / ('b-' + chain), path / 'cache' / ('b-' + chain), path / 'ios' / ('b-' + chain),
                      path / 'dmsh_b' / ('b-' + chain)):
        if candidate.is_dir():
            return candidate
    found = sorted(path.rglob('b-' + chain)) if path.is_dir() else []
    return found[0] if found else None


def stamp_rows(library):
    table = Path(library) / 'inputs.tsv'
    if not table.is_file():
        return {}
    rows = {}
    for line in table.read_text().splitlines():
        if line.strip() and not line.startswith('#'):
            key, _, value = line.partition('\t')
            rows[key] = value
    return rows


def verify_library(library, chain, env):
    rows = stamp_rows(library)
    if not rows:
        raise Failure('%s has no inputs.tsv: it is not a finished dmsh_build.py library' % library)
    expected = subprocess.run([sys.executable, ROOT / 'dm/gfx/tools/dmsh_chain.py', '--inputs'],
                              capture_output=True, text=True, env=env, cwd=str(ROOT)).stdout.strip()
    if rows.get('game') != GAME_ID or (expected and rows.get('inputs') != expected):
        raise Failure('%s is not a library of this profile (game %s, inputs %s; this profile has %s): '
                      'rebuild the Shaders, or pass the library your working build used'
                      % (library, rows.get('game'), rows.get('inputs'), expected))
    return library


def prepare_shader_package(args, work, environment):
    """Run build_fifa23.py --shaders-only: EASF archives -> work/pkg + work/profile."""
    if args.shader_pack:
        return Path(args.shader_pack)
    if not (args.base or args.archives):
        raise Failure('the Shader library must come from somewhere: pass --shader-pack (prepared package), '
                      '--shaders (a finished b-%s) or --nsp-dir / --base so the EASF archives can be read'
                      % chain_version())
    cmd = [sys.executable, ROOT / 'scripts/build_fifa23.py', '--out', work, '--shaders-only',
           '-j', str(args.jobs)]
    if args.archives:
        cmd += ['--archives', *map(str, args.archives)]
    else:
        cmd += ['--base', str(args.base), '--keys', str(args.keys)]
        if args.update:
            cmd += ['--update', str(args.update)]
    if args.exefs:
        cmd += ['--exefs', str(args.exefs)]
    if args.easf_key_file:
        cmd += ['--key-file', str(args.easf_key_file)]
    say('preparing the EASF Shader package')
    run(cmd, 'build_fifa23.py --shaders-only', env=environment)
    pkg = work / 'pkg'
    if not pkg.is_dir():
        raise Failure('build_fifa23.py wrote no pkg directory')
    return pkg


def build_libraries(pkg, work, chain, environment):
    need_tools(['dotnet', 'spirv-cross'], 'building the Shader library')
    out = work / 'shaders'
    out.mkdir(parents=True, exist_ok=True)
    env = dict(environment, IOSOUT=str(out / 'ios/dmsh_b'))
    say('translating and compiling the Shader package for macOS and iOS')
    run([sys.executable, ROOT / 'dm/gfx/tools/dmsh_build.py', pkg, out], 'dmsh_build.py', env=env)
    mac = out / ('b-' + chain)
    ios = out / 'ios/dmsh_b' / ('b-' + chain)
    for library in (mac, ios):
        if not library.is_dir() or not any(library.glob('*_b.metallib')):
            raise Failure('dmsh_build.py wrote no complete %s' % library)
    return mac, ios


def build_host(work, g, environment, jobs):
    need_tools(['make', 'clang', 'xcrun'], 'compiling the host')
    host = work / 'dmhost'
    gen = work / 'gen'
    say('compiling the host for macOS (this takes a few minutes)')
    env = dict(environment, DM_GAME=GAME_ID, DM_GAMES_DIR=str(work / 'profile'), DM_GAMES_FIRST='1')
    run(['make', '-C', ROOT / 'dm/host', 'GAME=' + GAME_ID, 'GEN=' + str(gen), 'HOST=' + str(host),
         'dmhost', '-j%d' % jobs], 'make -C dm/host', env=env)
    if not host.is_file():
        raise Failure('make wrote no host at %s' % host)
    return host


def runtime_tables(library, profile_dir, environment):
    """c1_full.tsv / cb_extent.tsv are per-checkout products the host reads."""
    for name, tool in (('c1_full.tsv', 'c1_guard.py'), ('cb_extent.tsv', 'cb_extent.py')):
        target = profile_dir / name
        head = target.read_text().splitlines()[0] if target.is_file() else ''
        if head.startswith('# chain b-') and library.name in head:
            continue
        say('generating', name, 'from', library.name)
        run([sys.executable, ROOT / 'dm/gfx/tools' / tool, library, target], '%s (%s)' % (tool, name),
            env=environment)


# --------------------------------------------------------------------------
# packaging
# --------------------------------------------------------------------------

def copy_profile_tables(work, g):
    """The profile copy the packagers read: the repository's tables plus c1/cb."""
    dest = work / 'profile' / GAME_ID
    dest.mkdir(parents=True, exist_ok=True)
    for src in PROFILE.glob('*.tsv'):
        if src.name not in ('c1_full.tsv', 'cb_extent.tsv'):
            shutil.copyfile(src, dest / src.name)
    return dest


def fonts(work, args):
    out = work / 'font'
    out.mkdir(parents=True, exist_ok=True)
    standard = out / 'standard.ttf'
    if not standard.is_file():
        source = Path(args.standard_font or '/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
        if not source.is_file():
            raise Failure('no standard font at %s (pass --standard-font with a Unicode TTF)' % source)
        shutil.copyfile(source, standard)
    ext = out / 'nintendo_ext.ttf'
    if not ext.is_file():
        run([args.font_python, ROOT / 'dm/tools/make_ext_font.py', ext], 'make_ext_font.py', quiet=True)
    return out


def launcher_settings(work, patched, nacp, args, environment):
    out = work / 'launcher.json'
    if nacp is None:
        say('no control.nacp: the launcher will not offer the game languages')
    env = dict(environment, DM_SHOW_FPS='YES' if args.show_fps == 1 else 'NO',
               DM_LANG=args.language or 'en-US',
               SETTINGS_PLATFORM=args.target)   # mac: the settings window gains Display mode; ios: Picture / Frame-rate counter
    text = run([sys.executable, ROOT / 'dm/games/settings.py', GAME_ID, patched,
                nacp or Path('/nonexistent/control.nacp'), out], 'dm/games/settings.py', env=env, quiet=True)
    say('launcher settings:', (text or '').strip())
    return out


def app_version(args, nacp):
    if args.version:
        return args.version
    if nacp:
        p = subprocess.run([sys.executable, ROOT / 'dm/tools/nacp.py', '--version', nacp],
                           capture_output=True, text=True)
        value = (p.stdout or '').strip()
        if p.returncode == 0 and value:
            return value
    say('no display version in the control data: using 1.0')
    return '1.0'


def build_mac(args, work, patched, library, nacp, icon, version, bundle, romfs=None):
    # codesign is only needed when the App is asked to be signed (--sign); every other step works without it.
    need_tools(['swiftc', 'sips'] + (['codesign'] if args.sign is not None else []), 'building the macOS App')
    out = Path(args.out) if args.out else ROOT / 'Release' / MAC_APP_NAME
    out = out.resolve()
    if out.exists():
        if out.suffix != '.app':
            raise Failure('%s exists and is not a .app' % out)
        say('replacing the previous', out.name)
        shutil.rmtree(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    backend = getattr(args, 'resource_backend', 'nsp')
    argv = [sys.executable, ROOT / 'scripts/build_mac_app.py',
            '--host', work / 'dmhost', '--patched', patched, '--shaders', library,
            '--profile', work / 'profile' / GAME_ID, '--font', fonts(work, args),
            '--settings', work / 'launcher.json', '--title-id', GAME_ID,
            '--name', args.app_name, '--version', version, '--bundle-id', bundle,
            '--resource-backend', backend, '--output', out]
    if backend == 'directory':
        if not romfs:
            raise Failure('directory mode needs the game RomFS: pass --romfs or let the extract stage write it')
        say('bundling the game RomFS into the App:', romfs)
        argv += ['--romfs', str(romfs)]
    if icon:
        argv += ['--icon', str(icon)]
    if args.sign is not None:
        argv += ['--sign', args.sign]
    say('packaging', out.name, '(ad-hoc signed)' if args.sign is not None else '(unsigned)')
    run(argv, 'build_mac_app.py')
    return out


def build_ios(args, work, patched, ios_library, nacp, icon, version, bundle):
    need_tools(['xcodebuild', 'xcodegen'], 'building the iOS IPA')
    out = Path(args.out) if args.out else ROOT / 'Release' / IOS_IPA_NAME
    out = out.resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    media = work / 'media'
    (media / 'RomFS').mkdir(parents=True, exist_ok=True)   # external mode: no RomFS is staged
    if nacp:
        shutil.copyfile(nacp, media / 'control.nacp')
    if icon:
        shutil.copyfile(icon, media / 'icon.jpg')
    else:
        say('no App icon: the home-screen icon stays blank')
    project = work / 'ios-project'
    if project.exists():
        say('discarding the previous generated Xcode project')
        shutil.rmtree(project)
    env = tool_env()
    env.update({
        'GAME': GAME_ID,
        'W': str(work),
        'PATCHED': str(patched),
        'ROMFS': str(media / 'RomFS'),
        'MSL_IOS': str(ios_library.parent),
        'AOC': '',
        'DM_RESOURCE_BACKEND': 'nsp',
        'DM_IOS_BUILD_DIR': str(project),
        'DM_XCODE_DERIVED_DATA': str(work / 'ios-dd'),
        'DM_BUNDLE_ID': bundle,
        'DM_DISPLAY_NAME': args.app_name,
        'DM_APP_VERSION': version,
        'DM_LANG': args.language or 'en-US',
        'DM_SHOW_FPS': '1' if args.show_fps == 1 else '0',
        'FONT_PY': args.font_python,
        'DM_GAMES_DIR': str(work / 'profile'),
        'DM_GAMES_FIRST': '1',
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
    })
    if icon:
        env['DM_ICON'] = str(icon)
    say('building the unsigned IPA (xcodegen + xcodebuild)')
    run(['bash', ROOT / 'dm/ios/tools/build_ipa.sh', out], 'dm/ios/tools/build_ipa.sh', env=env)
    return out


# --------------------------------------------------------------------------
# command line
# --------------------------------------------------------------------------

def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--target', choices=('mac', 'ios'), required=True)
    p.add_argument('--nsp-dir', type=Path, help='folder holding the base .nsp/.xci, an optional update .nsp and prod.keys')
    p.add_argument('--base', type=Path, help='the base game container (overrides --nsp-dir)')
    p.add_argument('--update', type=Path, help='the update container, if you have one')
    p.add_argument('--keys', type=Path, help='prod.keys')
    p.add_argument('--archives', nargs='+', type=Path, help='decoded/encrypted shader.big shaderboot.big files')
    p.add_argument('--easf-key-file', type=Path, help='private JSON EASF key file (only when no module is available)')
    p.add_argument('--exefs', type=Path, help='an already extracted ExeFS (skips nx_extract)')
    p.add_argument('--nx-extract', type=Path, help='the nx_extract binary (built into build/work/tools when absent)')
    p.add_argument('--patched', type=Path, help='already rewritten modules (skips the rewriter)')
    p.add_argument('--shader-pack', type=Path, help='a prepared EASF package (pkg/) to compile instead of reading the game')
    p.add_argument('--shaders', type=Path, help='a finished macOS b-<chain> library, or a folder holding one')
    p.add_argument('--ios-shaders', type=Path, help='a finished iOS b-<chain> library, or a folder holding one')
    p.add_argument('--work', type=Path, help='build work directory (default build/work)')
    p.add_argument('--out', type=Path, help='artifact path (default Release/Touchline23.app or .ipa)')
    p.add_argument('--app-name', default=DEFAULT_APP_NAME, help='App display name (default %(default)s)')
    p.add_argument('--version', help="App version (default: the game's display version)")
    p.add_argument('--language', help='default game language (default en-US)')
    p.add_argument('--show-fps', type=int, choices=(0, 1), help='start with the frame-rate counter on')
    p.add_argument('--resource-backend', choices=('nsp', 'directory'), default='nsp',
                   help='nsp: the App carries no game data and the launcher asks for the containers at run time; '
                        'directory: the game RomFS is bundled in the App (Contents/Resources/romfs) and the '
                        'launcher asks for nothing')
    p.add_argument('--romfs', type=Path,
                   help='directory mode: an already extracted RomFS to bundle (skips extracting it again)')
    p.add_argument('--sign', nargs='?', const='-', metavar='IDENTITY',
                   help='macOS: ad-hoc sign the finished App (codesign --sign -, or with IDENTITY); off unless given')
    p.add_argument('--icon', type=Path, help='App icon (default assets/app-icon/touchline23.png)')
    p.add_argument('--standard-font', type=Path, help='Unicode TTF stand-in for the system font')
    p.add_argument('--font-python', default=sys.executable,
                   help='a python with capstone, lz4 and fontTools')
    p.add_argument('-j', '--jobs', type=int, default=4)
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    g = profile()
    chain = chain_version()
    work = (args.work or ROOT / 'build/work').resolve()
    work.mkdir(parents=True, exist_ok=True)
    env = tool_env()
    env.update(DM_GAME=GAME_ID, DM_GAMES_DIR=str(work / 'profile'), DM_GAMES_FIRST='1', DM_ROOT=str(work))
    say('Touchline 23:', args.target, '| profile', g.get('name'), '| chain b-' + chain)
    say('work directory', work)
    args = resolve_inputs(args, work)
    icon = Path(args.icon) if args.icon else (PROJECT_MAC_ICON if args.target == 'mac' else PROJECT_ICON)

    # inputs and modules. The ExeFS supplies the modules and the control data
    # (App name, version, languages); a reuse of both may go without it.
    exefs = extract(args, work) if (args.exefs or args.base) else None
    patched = rewrite(args, exefs, work, g)

    # A bundled App reads the game from Contents/Resources/romfs: the launcher asks for nothing.
    romfs = None
    if args.target == 'mac' and args.resource_backend == 'directory':
        romfs = (args.romfs or (work / 'extract' / 'RomFS')).resolve()
        marker = g.get('romfs_marker')
        if not romfs.is_dir():
            raise Failure('directory mode needs the game RomFS, but %s does not exist: drop --exefs so the '
                          'extract stage writes it, or pass --romfs <extracted RomFS>' % romfs)
        if marker and not (romfs / marker).is_file():
            raise Failure('%s is not this game\'s RomFS (missing %s)' % (romfs, marker))
        say('resource backend: directory - the App carries the game data (%s)' % romfs)

    # Shader libraries
    profile_dir = copy_profile_tables(work, g)
    if args.shaders:
        mac_library = library_under(args.shaders, chain)
        if not mac_library:
            raise Failure('--shaders %s holds no b-%s' % (args.shaders, chain))
        say('macOS Shader library', mac_library)
        verify_library(mac_library, chain, env)
        runtime_tables(mac_library, profile_dir, env)
        ios_library = None
        if args.target == 'ios':
            source = args.ios_shaders or args.shaders
            ios_library = library_under(source, chain)
            if ios_library is None or ios_library == mac_library:
                raise Failure('no iOS Shader library: pass --ios-shaders <dir holding b-%s>' % chain)
            say('iOS Shader library', ios_library)
            verify_library(ios_library, chain, env)
    else:
        pkg = prepare_shader_package(args, work, env)
        mac_library, ios_library = build_libraries(pkg, work, chain, env)
        verify_library(mac_library, chain, env)
        verify_library(ios_library, chain, env)
        runtime_tables(mac_library, profile_dir, env)
    host = build_host(work, g, env, args.jobs)
    nacp, icon = control_data(exefs, work, icon)
    version = app_version(args, nacp)
    launcher_settings(work, patched, nacp, args, env)
    bundle = bundle_id(g)

    if args.target == 'mac':
        out = build_mac(args, work, patched, mac_library, nacp, icon, version, bundle, romfs)
    else:
        out = build_ios(args, work, patched, ios_library, nacp, icon, version, bundle)
    if not out.exists():
        raise Failure('the build reported success but %s does not exist' % out)
    size = out.stat().st_size if out.is_file() else sum(f.stat().st_size for f in out.rglob('*') if f.is_file())
    say('done:', out)
    say('size: %d bytes (%.1f MiB)' % (size, size / 2 ** 20))
    if out.is_file():
        say('sha256:', digest(out))
    say('This build proves compilation and packaging only; game runtime is separate.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Failure as exc:
        print(exc, file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
