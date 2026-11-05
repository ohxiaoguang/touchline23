# Build and run

Keep game inputs, keys, saves, generated shaders and logs in a dedicated external
workspace. Paths below are shell variables chosen by the user, not repository
paths. Do not put generated MSL or metallibs into Git.

## The two commands

`scripts/build-mac.sh` and `scripts/build-ios.sh` run the whole chain for you:

```sh
./scripts/build-mac.sh --nsp-dir "/path/to/FIFA23"
./scripts/build-ios.sh --nsp-dir "/path/to/FIFA23"
```

They identify the base container and the update, extract the ExeFS and the
control data, rewrite `main` and `sdk`, prepare the EASF package, build the macOS
and iOS Shader libraries, write the runtime tables, compile the host and package
`Release/Touchline23.app` or `Release/Touchline23.ipa`. Each stage can be skipped
by pointing at what an earlier run produced (`--exefs`, `--patched`,
`--shaders`, `--ios-shaders`, `--shader-pack`), and `--work` names the work
directory (default `build/work`, which Git ignores). The script refuses a Shader
library whose `inputs.tsv` names other inputs, so a stale or foreign library is
an error rather than a silent link. It refuses a reused `--patched` directory in
the same way: the build ID `patch_nso.py` recorded in each module's fixups table
has to be one the profile's `build` rows declare, because the rewriter's fixed
addresses, the observation gates and `nn::oe::GetDisplayVersion` all key on it.

The macOS App is unsigned. `--sign` ad-hoc signs it (`--sign "<identity>"` signs
with that identity), sealing `Info.plist` and every resource; nothing about the
App's behaviour depends on it, and Game Mode is asked for by the two `Info.plist`
keys `LSApplicationCategoryType` and `LSSupportsGameMode`.

A Git checkout and a downloaded source archive build the same way: nothing in the
build reads `.git`, so a release ZIP is enough beside the game inputs.

The rest of this page explains what those stages do and how to run them by hand,
which is what to do when a stage fails or when a change needs a controlled
comparison.

## Manual workspace

Choose absolute paths on the drive holding your game inputs; the ones below are
placeholders. Keep extraction, virtual environments and large outputs on that
drive, outside the repository and home folder. A manual `BUILD` path must not
contain spaces. `EXEFS` must contain the original (updated) `main` and `sdk`;
`ROMFS` must be the matching merged base/update filesystem, including `data3.big`.

```sh
export GAME_INPUTS="/path/to/FIFA23"
export BUILD="$GAME_INPUTS/01001C8016B4E000_build"
export EXEFS="$GAME_INPUTS/extracted/ExeFS"
export ROMFS="$GAME_INPUTS/extracted/RomFS"
export SHADER_BIG="$GAME_INPUTS/archives/shader.big"
export SHADERBOOT_BIG="$GAME_INPUTS/archives/shaderboot.big"
export DM_GAME=01001C8016B4E000
```

## Toolchain

The validated environment uses Apple silicon, Python 3.13.12 (Python 3.9 also ran the
shader/host stages), .NET runtime 10.0.13, and Apple Metal compiler 32023.921.
Full source builds require Xcode with its Metal toolchain, XcodeGen, .NET and
SPIRV-Cross matching the lock. IPA font generation also needs `fonttools`.
The NSO rewriter needs `capstone` and `lz4`.
Encrypted EASF preparation additionally needs `pycryptodome`; decoded BIG4 inputs
do not. The tested package versions are pinned in
`scripts/requirements-fifa23.txt` (capstone 5.0.7, lz4 4.4.5, pycryptodome 4.1.0).
Install dependencies in an external virtual environment:

```sh
python3 -m venv "$GAME_INPUTS/fifa23-venv"
source "$GAME_INPUTS/fifa23-venv/bin/activate"
python3 -m pip install -r scripts/requirements-fifa23.txt
python3 -m pip install fonttools
```

Use the pinned toolchain below; a generic package-manager install may differ.

The existing in-repository translator is authoritative and matches the lock:

| Component | SHA256 prefix / version |
| --- | --- |
| dmsh_xlate.dll | `80132fec3fc716df` |
| Ryujinx.Graphics.Shader.dll | `48fafbf9b0d912bd` |
| Ryujinx.Common.dll | `2a02559c07d4935a` |
| Embedded translator source | `16bbef6c762573ee` |
| SPIRV-Cross executable | `8caa75a31452ae23` |
| macOS and iOS Metal | `Apple metal version 32023.921 (metalfe-32023.921.6)` |

The old SPIRV-Cross lock was `d9dc197f061b42a5`. It contained a binary hash,
not enough provenance to reconstruct its exact build. This branch deliberately
adopts the installed Homebrew 1.4.363.0 arm64 Sequoia bottle and validates full
translation with it. Metal and SPIRV-Cross retain those recorded values; the translator DLLs were
subsequently rebuilt from repository source and remeasured (commit `674c2e1`).
The table above matches the current lock, not the earlier migration snapshot.
This is a reviewed toolchain update, not a bypass or a claim that different
SPIRV-Cross releases produce identical MSL.

The bottle SHA256 recorded by the local Homebrew SBOM is
`3bd332f91d03227a11522d36e33c58736ddae7fff83db42d838ad3181a447eda`.
Use the matching bottle, retain its package receipt, put its `bin` on `PATH`,
and verify the executable hash against the lock. `brew install spirv-cross` alone
can install a newer version and is not an exact-version recipe. The upstream
source tag is [vulkan-sdk-1.4.363.0](https://github.com/KhronosGroup/SPIRV-Cross/tree/vulkan-sdk-1.4.363.0).
A source build is possible using CMake, but its binary hash may differ; do not
silently substitute it for this bottle or edit the lock to skip validation.

For a deliberate source-toolchain upgrade, pin the source revision and compiler,
build outside the repository, inspect its changes, run the existing
`dmsh_chain.py --update-lock`, then rebuild/validate the affected shaders and host
and commit the lock. A fresh `dotnet publish` is also a toolchain upgrade, not a
way to reproduce the checked-in DLL fingerprints.

Homebrew .NET apphosts may require `DOTNET_ROOT` pointing at the installation's
`libexec` directory. `build_fifa23.py` detects that layout; direct tool invocations
must set it themselves if necessary. First run:

```sh
python3 dm/gfx/tools/dmsh_chain.py --check-tools
```

## Inputs and source build

Use the existing [extraction workflow](../agents/01-extract.md) to obtain your own
updated ExeFS and RomFS. Obtain `shader.big` and `shaderboot.big` from the local
EA game archives. The preparation tool accepts decoded BIG4 files, chunkzip, or
the original EASF payloads.

An EASF payload is decrypted with a key the build finds in your own copy of the
game. The container header names its key ID, and the engine keeps a key registry
in `main` as one record per ID (`{char id[8]; uint8 key[16]}`), so the build reads
the 16 bytes after the ID and accepts them only after they decrypt the first two
blocks to the SHA-256 the header carries. No offset, build ID, external key table
or network is involved, so a base game, an update or another copy of the same
release all resolve the same way. `dm/gfx/tools/easf/keyfind.py` holds it, and
`test_easf_keyfind.py` covers the working and failing cases.

`--key-file "$PRIVATE_KEY_FILE"` remains the explicit private source: a JSON
object mapping the eight-character container key ID to an AES key in hexadecimal.
It is consulted first, and it is the fallback when no module is available, so a
build without `main` behaves exactly as before. Do not print, commit or pass key
values on the command line. Neither the log nor the manifest contains a key: the
manifest records where it came from and the first 16 hex digits of its SHA-256.
The repository supplies no decryption keys.

```sh
python3 scripts/build_fifa23.py \
  --archives "$SHADER_BIG" "$SHADERBOOT_BIG" \
  --out "$BUILD" --exefs "$EXEFS" -j 4
```

`--exefs` supplies `main` for discovery here; `--key-module MODULE` adds any
other NSO0 to search. `--no-key-discovery` keeps `--key-file` as the only source.
`--key-scan` additionally allows a bounded scan of the module's read-only segment
when the key ID is not present verbatim (off by default: it costs about a minute
on a large module and the direct search finds the record in one step).

Or read both archives straight out of the original gamecard, with nothing
extracted: FIFA 23 keeps them as BIG4 members of the RomFS file `datax.big`. The
mount decrypts and IVFC-checks every read, and only the two member ranges are
copied to memory (the per-call limit is 1 MiB, so they arrive in pieces).

```sh
python3 scripts/build_fifa23.py \
  --base "$GAMECARD_XCI" --keys "$PROD_KEYS" \
  --out "$BUILD" --exefs "$EXEFS" -j 4
```

Without `--exefs`, this mode still finds the key: the code section is written out
by the repository's own `nx_extract` (`--manifest`, so the RomFS stays on the
image — 5 files, 50 MB, under a second on the 15 GB gamecard) and `main` comes
from there. No `--key-file` is needed then; the first run builds `nx_extract`
once into `$BUILD/tools`, later runs reuse it and the extracted code section.

Add `--update "$UPDATE_NSP"` to build against the patched 1.0.3 view; the shader
archives are byte-identical in both versions, so the package is the same.
`--shaders-only` stops after the package so an existing Metal build can be
reused. In this mode the manifest records the container and member hashes
together with the version the mounted modules' build IDs identify.

A manual output directory must be external (or under `build/`) and cannot
contain spaces, because the host Makefile cannot represent those paths. The script also has a settings
block for Spyder F5. It uses normal project tools in this order:

1. Check locked tools; export packages and profile query/pair tables from archives.
2. Generate the external profile's chain header.
3. Run `dmsh_build.py` through the locked translator, SPIRV-Cross and Metal. Both
   ptrfix and Direct-handle lowering run normally, including sideline materials.
4. Check that every map entry has a library and matching-chain reflection.
5. Regenerate `c1_full.tsv` and `cb_extent.tsv`.
6. Build the host with `make -C dm/host`, using `GEN` and `HOST` to keep all
   products external. Libvpx is compiled from the repository's own source.
7. With `--exefs`, rewrite `main` and `sdk` from original NSOs with current
   `patch_nso.py`. Without it, module regeneration is explicitly absent.

Outputs include `pkg/`, `profile/`, `shaders/`, `gen/`, `dmhost`, `patched/` and a
private `build-manifest.json`. The manifest names the source revision and whether
the tree was dirty when this is a Git checkout; a downloaded source archive has
no `.git`, records `null` there and builds the same way. Existing
content-addressed caches can accelerate repeats. For a clean proof use a new
output directory and leave `DMSH_CAS`, `DMSH_PREFILL` and `IOSOUT` unset; do not
point them at old overlays. The manifest records input and library hashes but
does not certify runtime visuals or sound. No IPA packaging, signing,
installation or publishing is performed by this helper.

## iOS shader build and unsigned IPA

`scripts/build-ios.sh` does this for you. The generic
`scripts/build_ipa_from_nsp.py` pipeline has prepared-input consumers, but its
Shader scanner does not supply FIFA's EASF adapter; FIFA goes through
`scripts/build_fifa23.py` (or the [packaging GUI](../packaging-gui.md), which runs
the same engine). Both `nsp` (external XCI/NSP) and `directory` FIFA builds have
Mac/iOS build and audit records. `build_fifa23.py` reads the Shader archives
directly through `easf/` without full RomFS extraction. The commands below
describe a manual Directory packing run. Reuse existing verified iOS libraries
when available; do not invoke full Shader compilation merely to package another
artifact.

Select the external profile generated above for all subsequent commands. A
Homebrew .NET installation may also need `DOTNET_ROOT` set as described above.

```sh
export DM_GAMES_DIR="$BUILD/profile"
export DM_GAMES_FIRST=1
export IOSOUT="$BUILD/ios/dmsh_b"
python3 dm/gfx/tools/dmsh_chain.py --check-tools
python3 dm/gfx/tools/dmsh_build.py "$BUILD/pkg" "$BUILD/shaders"
```

This compiles iOS libraries as well as the Mac outputs. Mac metallibs cannot be
used on iOS. The profile header, reflection and libraries must share the current
chain (`a885c56c665a` in the current source; verify `dm/gfx/nvn/dmsh_chain.h`). If source or profile shader inputs
change, repeat the source-build helper to regenerate the header and c1/extent
proofs and rebuild the host; do not mix libraries from another chain.

With `main` and `sdk` rewritten by the helper's `--exefs` option:

```sh
export GAME="$DM_GAME"
export W="$GAME_INPUTS/$GAME-work"
export PATCHED="$BUILD/patched"
export MSL_IOS="$IOSOUT"
export DM_RESOURCE_BACKEND=directory
export DM_IOS_BUILD_DIR="$BUILD/ios-project-new"  # must not already exist
export DM_XCODE_DERIVED_DATA="$BUILD/ios-derived-new"
dm/ios/tools/build_ipa.sh "$BUILD/Touchline23.ipa"
```

`ROMFS` remains exported from workspace setup. Preserve extracted `control.nacp`
and `icon.jpg` beside it; the packer also looks for base control data under
`$W/data/v0`. The script embeds modules, iOS shaders, fonts and the complete
RomFS using the existing `pack_ipa.py`. It creates an unsigned IPA; the user
signs and sideloads it. The signer must preserve game-required entitlements;
this build step does not perform signing or installation.
The current 5 GiB reservation fits the tested iPhone address space without
Extended Virtual Addressing; physical memory/jetsam limits remain separate.

For a user-managed Xcode project, the same environment supports:

```sh
dm/ios/tools/build_ipa.sh --prepare-xcode
```

Build/static and device results are recorded separately in
[validation](validation.md). Existing iPhone play confirms the corrected layout
and crowd path in tested scenes, without guaranteeing every device or scene.

## Isolated runtime check

Set `ORIGINAL_SAVE` to the existing save directory and `NEW_RUN` to a new external
run directory before launching. `--build` takes any directory a build left behind:
the wrappers' `build/work`, or an output directory of `scripts/build_fifa23.py`.
Resources come from the containers (the mode both wrappers default to) or from an
extracted RomFS tree:

```sh
python3 scripts/run_fifa23.py --build "$BUILD" \
  --base "$GAMECARD_XCI" --update "$UPDATE_NSP" --prod-keys "$PROD_KEYS" \
  --save-source "$ORIGINAL_SAVE" --run-dir "$NEW_RUN" --seconds 900

python3 scripts/run_fifa23.py --build "$BUILD" --romfs "$ROMFS" \
  --save-source "$ORIGINAL_SAVE" --run-dir "$NEW_RUN" --seconds 900
```

No build manifest is required: the launcher checks what the host itself reads
(`dmhost`, `patched/<module>.patched.bin` with its `.fixups.tsv`, `shaders`)
and names the Shader chain from a manifest when the build wrote one, otherwise
from the single `shaders/b-<chain>`. It copies the save into a new external run
directory and does not mutate the original save. Logs and a control file stay in
that run directory. The existing `DM_CTL` interface supports commands appended to
`control.txt`, for example `A`, `Plus`, `LDown~0.2`, or `shot <external-path.png>`.
See the [debugging guide](../agents/05-debugging.md). Use it to enter a real
match, switch Radar 2D/3D in the game menus, test player selection and inspect
shadows across multiple moments. Listen for commentary. A time-limit exit is not
a crash or a successful visual test by itself.

## Regression checks

These commands are for future implementation changes, not required for a
documentation-only edit. Use the matching external profile and libraries.

Regression commands:

```sh
python3 -m unittest discover -s dm/gfx/tests -p test_compat_rules.py
python3 -m unittest discover -s dm/gfx/tests -p test_shader_slots.py
DMSH_LIB=<shader library root>/b-<chain> python3 dm/gfx/tools/dmsh_slots.py "$DMSH_LIB"
make -C dm/host game_profile GAME=01001C8016B4E000
make -C dm/host/tests GAME=01001C8016B4E000 build/t_audio_compat build/t_audio_spsc build/t_oe
dm/host/tests/build/t_audio_compat
dm/host/tests/build/t_audio_spsc
dm/host/tests/build/t_oe
```

These small tests use the existing test output conventions inside ignored build
directories. They contain synthetic PCM/rule fixtures, not extracted shaders.

Reflection regression coverage:

```sh
make -C dm/gfx/tests GAME=01001C8016B4E000 t_refl_pool
dm/gfx/tests/t_refl_pool "$BUILD/shaders/b-$(DM_GAME=01001C8016B4E000 python3 dm/gfx/tools/dmsh_chain.py)"
```

The legacy `t_refl` also needs two samples from a different original game; those
are not FIFA fixtures and are not included here. Missing samples are a test
environment limitation, not a passing result.

`t_texture_views` also checks the Direct-array type prefilter and uses synthetic
Metal data to verify that a non-array read of a 2D array samples layer 0. It needs
GPU access; a sandbox without a Metal device returns a nonzero status.

To run the synthetic GPU indirect-read contract (no game data), set
`EXTERNAL_FIXTURE` to a generated MSL filename in the external workspace:

```sh
python3 dm/gfx/tests/ptrfix_fixture.py "$EXTERNAL_FIXTURE"
make -C dm/gfx/tests GAME=01001C8016B4E000 t_ptrfix t_ptrfix_pending
dm/gfx/tests/t_ptrfix "$EXTERNAL_FIXTURE"
dm/gfx/tests/t_ptrfix_pending
```

`EXTERNAL_FIXTURE` is an external generated MSL filename; the input is authored
synthetic test code using the production helper, not a converted game shader.
A Metal device is required. See [shadow investigation](shadow-investigation.md)
for the control method and remaining scene coverage.
