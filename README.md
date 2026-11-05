# Touchline 23

[简体中文](README.zh-CN.md) · [Packaging guide](docs/packaging-gui.md) · [Compatibility](docs/fifa23/compatibility.md)

Touchline 23 runs the Nintendo Switch version of **FIFA 23 Legacy Edition**
natively on Apple silicon, with launchers for **macOS, iOS and iPadOS**. It is an
independently maintained, single-game project. The game's ARM64 code runs with
host implementations of the services, graphics, audio and input it needs.

You supply your own game files and console keys. This repository contains source,
compatibility metadata and build tools; it does not include the game, keys or
ready-to-distribute game resources.

## Get started

1. Prepare your own base XCI/NSP and `prod.keys`, plus the optional 1.0.3 NSP update.
2. Build `Touchline23.app` or an unsigned `Touchline23.ipa` using the commands
   below, or use **Touchline 23 Packaging** for a graphical workflow.
3. On macOS, choose the resource folder in the launcher. On iPhone/iPad, place the
   files in the App's Documents folder using Files; subfolders are scanned too.
4. Check the identified resources, select the interface/game language and console
   mode, then start the game. The settings also contain **About Touchline 23**.

IPAs require your own signing and sideloading setup. Source publication is not
permission to redistribute the game code or derived assets inside local builds.

## Platforms and current status

| Platform / feature | Evidence and scope |
| --- | --- |
| Apple silicon, macOS 26+ | Menus and formal matches tested on MacBook Air M1 |
| iPhone, iOS 26+ | User-reported gameplay on iPhone Air; the current App/IPA also passes build/static checks |
| iPad, iPadOS 26+ | Shared iOS UI and package target; no separate iPad gameplay record |
| Handheld / docked, audio and commentary, crowds, indicator, 2D/3D Radar, saves | Mac evidence and iPhone feedback in the validation records |
| Touch controls and gamepad | iPhone user testing; controller coverage remains limited |
| Dynamic player shadows | Formal-match projections and targeted GPU checks on Mac; detailed iPhone comparison remains incomplete |
| macOS MOD overlay | Optional resource-folder overlay with synthetic tests; compatibility of individual FIFA MODs is not certified |
| Bilingual launchers / About page | English and Simplified Chinese; macOS About interaction tested, iOS compiled but About not device-tested |

[Compatibility](docs/fifa23/compatibility.md) and [validation](docs/fifa23/validation.md)
separate gameplay, user feedback, build audits and automated tests. New builds are
not automatically new gameplay validations.

## Game versions and resource modes

| Item | Value |
| --- | --- |
| Game | FIFA 23 Legacy Edition (Nintendo Switch) |
| Title ID | `01001C8016B4E000` |
| Base | 1.0.0 (`v0`), also the Shader source version |
| Optional update | 1.0.3 (`v196608`), the version covered by gameplay records |
| App / bundle identity | Touchline 23 / `com.ohxiaoguang.touchline23` |

Keep code and resources from the same game version. A registered 1.0.0 build is
not a claim of the same gameplay coverage as 1.0.3.

**External XCI/NSP (default):** the launcher verifies matching files and reads the
containers in place. Game containers, keys and RomFS stay outside the artifact.
The App still contains rewritten program modules and derived Shader libraries.

**Directory:** the packaging GUI and lower-level build tools can prepare and
bundle RomFS. The resulting artifact is much larger and fixed to those resources.
See the [packaging guide](docs/packaging-gui.md). There is no DLC selector for this
FIFA profile.

On macOS, choose saves/log storage separately in launcher settings. On iOS,
saves and diagnostics remain in the App container; preserve them before reinstalling.

## Build from source

Use an Apple silicon Mac with Xcode and its Metal toolchain, .NET 10,
SPIRV-Cross, Python dependencies and XcodeGen for iOS. The validated tool versions,
locked fingerprints and dependency installation are in the [build guide](docs/fifa23/build.md).
The published checkout contains the project source needed for these builds. A Git
clone and a downloaded source archive build the same way: nothing in the chain
reads `.git`, and a full rebuild needs no earlier build output.

```sh
./scripts/build-mac.sh --nsp-dir "/path/to/your/fifa23-folder"
./scripts/build-ios.sh --nsp-dir "/path/to/your/fifa23-folder"
```

Outputs: `Release/Touchline23.app` and `Release/Touchline23.ipa`. These wrappers
build external-resource artifacts. Work defaults to ignored `build/work`; keep
private game inputs, keys and extraction/analysis work on the game drive.

The macOS App is not signed: ad-hoc signing is opt-in with `--sign` (or
`--sign "<identity>"` to sign with that identity), which seals `Info.plist` and
every resource. Unsigned builds run normally. Game Mode is asked for by the App's
`Info.plist` (`LSApplicationCategoryType` and `LSSupportsGameMode`), not by the
signature. A Directory App carries the whole RomFS (about 14.8 GB for this game),
so macOS verifies the bundle when it is first opened and that first launch takes
noticeably longer than the ones after it.

Reuse existing work when rebuilding the host or launcher:

| Prepared input | Option |
| --- | --- |
| ExeFS | `--exefs <folder>` |
| Rewritten main/sdk | `--patched <folder>` |
| macOS and iOS Shader libraries | `--shaders <folder>` / `--ios-shaders <folder>` |
| EASF source package | `--shader-pack <pkg>` |

The base's 386 programs produce **520 libraries per platform**; update 1.0.3 adds
no Shader. Libraries must match chain `a885c56c665a` and this profile's input stamp.
Reuse valid caches; do not regenerate them for unrelated UI/documentation changes.
`./scripts/build-mac.sh --help` lists work/output and other options.

## Touchline 23 Packaging

A dedicated bilingual SwiftUI tool for this game: choose macOS/iOS or both, select
External XCI/NSP or Directory, check resources, review the build, follow progress
and collect audited artifacts. Shader caches, error diagnostics and cancellation
remain available; there is no game browser or unnecessary DLC input.

Build the tool with `scripts/build_packaging_gui.py --output <new-directory>`.
The [English guide](docs/packaging-gui.md) explains bundled dependencies, disk use,
output safety and building the tool from source.

## Limits

- There is no stable-60-FPS guarantee. This profile exposes no 30/60-FPS toggle;
  the shared engine's diagnostic pacing variables are not a validated FPS patch.
- Startup reserves 5 GiB of guest address space. Historical matches used roughly
  2.8 GiB resident memory; these are observations, not universal device requirements
  or a guarantee against iOS jetsam. The recorded iPhone has 8 GB RAM.
- Venue, weather, special-scene and long-session coverage remains incomplete.
  Loading can underrun audio; some services still report `[RED]` diagnostics.
- Online play and Switch network services are outside the supported scope.
- No Intel Mac support or separately validated iPad/device matrix is claimed.

## Development and local checks

[Graphics](dm/gfx/README.md), [profile format](dm/games/README.md),
[extraction](docs/agents/01-extract.md) and [debugging](docs/agents/05-debugging.md)
describe the development workflow. Tests run locally; this project has no GitHub
Actions workflows.

```sh
python3 -m unittest discover -s scripts/tests
python3 scripts/check_markdown_links.py
python3 scripts/check_fifa23_public.py
swift test --package-path gui
```

The conservative publication scanner still requires manual disposition of known
third-party file types; see the [source audit](docs/fifa23/public-audit.md).
[Build and regression notes](docs/fifa23/build.md#regression-checks) list additional
resource/GPU tests and their fixture requirements.

## Credits and licenses

Touchline 23 is based on [nxnative](https://github.com/seedds/nxnative) and the work
of its authors and contributors. FIFA 23 compatibility, graphics/resource
adaptations and independent packaging were developed on that engine and are
maintained here. These additions are not attributed to the original upstream as
if it authored all of them. See [project origin](docs/UPSTREAM.md).

The original [MIT license](LICENSE) and author notices are retained. Dependencies
keep their own terms, including Apache-2.0 for MsgPack; [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md)
indexes the full materials. The project icon is original generated artwork.
Touchline 23 is not affiliated with or endorsed by EA SPORTS, Nintendo or Apple.

[Official repository](https://github.com/ohxiaoguang/touchline23) · [Report an issue](https://github.com/ohxiaoguang/touchline23/issues)
