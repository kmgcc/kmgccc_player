# Third-party Runtime Integration

This document records the external runtime components that are bundled with
`kmgccc_player`, how they are packaged, and how to audit them before a Release
build. It is intentionally focused on runtime integration and bundle size
control; feature-level behavior belongs in the feature-specific docs.

## 1. Overview

`kmgccc_player` embeds a small set of third-party tools and runtime bundles for
music metadata, cover artwork, lyric search, AMLL lyric rendering, and protected
art assets. These components are copied into `Contents/Resources` or
`Contents/Resources/Tools`, so they directly affect the final `.app` size.

The current Release packaging strategy is Apple Silicon only:

- Build and ship arm64 binaries by default.
- Do not actively maintain x86_64 or universal runtime artifacts.
- Do not merge x86_64 Python runtimes, dylibs, shared objects, or helper
  binaries into the app bundle.
- Treat any unexpected x86_64 slice in Release as a packaging regression.

## 2. Runtime Components

| Component | Bundle path | Source / build path | Runtime purpose | Must ship with app | arm64-only | Size risk | Verification |
| --- | --- | --- | --- | --- | --- | --- | --- |
| QQMusic helper | `Contents/Resources/Tools/qqmusic-helper/qqmusic-helper` and `_internal.bundle` | `myPlayer2/Resources/Tools/qqmusic-helper/`, build script `build-universal.sh` | Optional QQ Music metadata and artwork provider | Yes, for QQ candidates | Yes | High: Python runtime, PyInstaller dependencies, duplicate `_internal` bundles | stdio JSON smoke test and `file` / `lipo -info` |
| LDDC server | `Contents/Resources/lddc-server/lddc-server` and `_internal` | `Tools/lddc-server/` | Local lyric search and conversion server | Yes, for bundled LDDC search | Yes | Medium: Python runtime and native dylibs | `lddc-server --help`, app lyric search smoke test |
| SACAD helper | `Contents/Resources/Tools/sacad/sacad` | `myPlayer2/Resources/Tools/sacad/sacad` | Cover search / download fallback | Yes, for SACAD provider | Yes | Medium: standalone binary can be large | `sacad --help`, cover lookup smoke test |
| AMLL bundle | `Contents/Resources/AMLL/index.html`, `background.html`, JS/CSS assets | `myPlayer2/Resources/AMLL/`; generated JS comes from the AMLL fork sync flow | AppleMusic-Like Lyrics WebView renderer | Yes | Not a Mach-O component | Medium: duplicate JS bundles, source maps, backups, tests | Load lyric panel / fullscreen lyric surfaces |
| BKArt.bundle / EncryptedArtAssets | `Contents/Resources/BKArt.bundle/Contents/Resources/EncryptedArtAssets` | `EncryptedArtAssets/`, `scripts/encrypt_art_assets.swift`, `docs/encrypted-art-assets-maintenance.md` | Protected art background and skin assets | Yes, for BKArt and protected visuals | Not a Mach-O component | High: accidental plaintext originals plus encrypted copies | BKArt visual smoke test and plaintext image audit |
| Other `Resources/Tools` entries | Under `Contents/Resources/Tools/...` | Component-specific source or vendor download path | Optional import, metadata, or artwork helpers | Depends on feature | Prefer arm64-only | Varies: stale binaries, caches, duplicate bundles | `du`, `file`, `lipo`, feature smoke test |

## 3. QQMusic Helper

Swift must launch only the bundled helper at:

```text
Bundle.main.resourceURL/Tools/qqmusic-helper/qqmusic-helper
```

Do not restore Python, venv, Anaconda, system Python, repo-local, or
environment-variable fallback execution paths. The helper is a stdio JSON-lines
process: Swift writes one JSON request per line to stdin, and the helper writes
JSON responses to stdout. Diagnostics and third-party library logs must go to
stderr so stdout remains machine-readable.

Build script:

```sh
myPlayer2/Resources/Tools/qqmusic-helper/build-universal.sh
```

The script name is retained for compatibility, but Release output must be
arm64-only. It must not build or merge x86_64 artifacts.

Release packaging rules:

- Ship only `qqmusic-helper` and `_internal.bundle` under
  `Contents/Resources/Tools/qqmusic-helper/`.
- Do not include x86_64 slices in the executable, `.dylib`, `.so`, or Python
  extension modules.
- Do not include more than one Python minor runtime. For example, a bundle that
  contains both `python3.11` and `python3.12` is invalid.
- Do not package PyInstaller build directories, caches, spec files, or local
  generated files such as `build`, `dist`, `.build-arm64`, `.build-universal`,
  `__pycache__`, `*.pyc`, or `*.bak*`.
- Do not allow duplicate numbered runtime directories such as
  `_internal 2.bundle` or `_internal 3.bundle` to enter Release.

Smoke test:

```sh
APP="/path/to/kmgccc_player.app"
printf '%s\n' '{"id":"smoke","method":"search_track_artwork","params":{"title":"七里香","artist":"周杰伦","album":"七里香","duration":299,"limit":1}}' \
  | "$APP/Contents/Resources/Tools/qqmusic-helper/qqmusic-helper"
```

Expected result: one JSON response with `"ok":true`; diagnostic startup lines may
appear on stderr.

Common issues:

- `_internal.bundle` copied twice by file-system synchronized groups and a custom
  copy script.
- `_internal 2.bundle` or another numbered duplicate left by Finder, PyInstaller,
  or manual copying.
- PyInstaller output grows because old Python minor runtimes are not removed
  before rebuilding.
- A universal2 wheel is installed and its native extension is copied without
  thinning or validation.

## 4. LDDC Server

Bundle path:

```text
Contents/Resources/lddc-server/lddc-server
Contents/Resources/lddc-server/_internal
```

Runtime lookup is owned by `LDDCServerManager`. Release should use the bundled
onedir server first and should not depend on a developer checkout or system
Python.

Source / vendor output path:

```text
Tools/lddc-server/
```

The server can be shipped arm64-only. Required runtime files are the
`lddc-server` executable and its `_internal` directory, including the Python
runtime and native libraries that the executable imports.

Do not package build leftovers:

- PyInstaller `build` / `dist` / cache directories.
- `.spec` files.
- `__pycache__`, `*.pyc`, `*.bak*`, `.DS_Store`.
- Duplicate server directories created during local experiments.
- Unused source checkouts or test data.

Minimal verification:

```sh
APP="/path/to/kmgccc_player.app"
"$APP/Contents/Resources/lddc-server/lddc-server" --help
file "$APP/Contents/Resources/lddc-server/lddc-server"
lipo -info "$APP/Contents/Resources/lddc-server/lddc-server"
```

A fuller verification should trigger an in-app LDDC lyric search and apply or
preview a result.

## 5. SACAD Helper

Bundle path:

```text
Contents/Resources/Tools/sacad/sacad
```

SACAD is used by the cover search / download pipeline as a cover artwork
provider. Swift should keep using the bundled executable path and should not
write provider results directly to the library database outside the shared cover
pipeline.

Source / update path:

```text
myPlayer2/Resources/Tools/sacad/sacad
```

Update the binary from the project-approved SACAD build or vendor source, then
verify it is arm64-only before Release. Do not package cargo build directories,
temporary outputs, caches, tests, or duplicate binaries.

Minimal verification:

```sh
APP="/path/to/kmgccc_player.app"
"$APP/Contents/Resources/Tools/sacad/sacad" --help
file "$APP/Contents/Resources/Tools/sacad/sacad"
lipo -info "$APP/Contents/Resources/Tools/sacad/sacad"
```

A fuller verification should run a manual cover search and confirm that SACAD
can produce a candidate without breaking the shared cover pipeline.

## 6. AMLL Bundle

Runtime loading should happen from:

```text
Contents/Resources/AMLL/index.html
Contents/Resources/AMLL/background.html
```

Do not flatten AMLL child files into `Contents/Resources` root. The root should
not contain duplicate `amll-core.js`, `amll-lyric.js`, `bridge.js`, `style.css`,
or old AMLL bundles unless a specific runtime path requires them.

Generated AMLL bundles must not be hand-edited. In particular, do not directly
edit:

```text
myPlayer2/Resources/AMLL/amll-core.js
myPlayer2/Resources/AMLL/amll-lyric.js
```

Use the AMLL fork sync workflow and record any core behavior changes in the
patch registry. Before AMLL updates or packaging changes, read:

- `docs/amll-custom-behavior-and-patch-registry.md`
- `docs/amll-lyric-advance-algorithm.md`
- `docs/amll-upgrade-migration-audit.md`

Release should not include AMLL development leftovers:

- `*.bak*`
- `*.map`
- source test files
- temporary generated files
- old bundle copies that are not loaded at runtime

Minimal verification should cover the normal lyrics panel, fullscreen surface,
cover blur surface, seek behavior, pause/resume behavior, overlap line rendering,
and lead-in advance accuracy.

## 7. BKArt / Encrypted Art Assets

Release must ship encrypted assets, not plaintext originals.

Runtime bundle path:

```text
Contents/Resources/BKArt.bundle/Contents/Resources/EncryptedArtAssets
```

Runtime should load `.kmgasset` files through the encrypted asset loader. Do not
ship source `png`, `jpg`, `jpeg`, or `webp` originals in the app bundle when an
encrypted `.kmgasset` is the runtime source of truth.

Local source originals should stay in private local source directories and be
protected by `.gitignore`. See:

```text
docs/encrypted-art-assets-maintenance.md
```

Asset update flow:

1. Prepare or re-encode the source image.
2. Compress / resize as appropriate before encryption.
3. Run the encryption script.
4. Place the resulting `.kmgasset` and manifest updates in the bundle source.
5. Build Release.
6. Verify the runtime UI can load BKArt / skin assets.
7. Audit the app bundle to confirm plaintext originals were not packaged.

Do not package both an original image and its encrypted `.kmgasset` copy.

## 8. Xcode Packaging Rules

The project uses file-system synchronized groups. `.gitignore` is not a
packaging rule: ignored files can still be copied if they are visible to Xcode
through a synchronized group or an explicit build phase. Always check both:

- Build Phases / Copy Bundle Resources.
- File-system synchronized group membership and
  `EXCLUDED_SOURCE_FILE_NAMES`.
- Custom Run Script phases that copy directories into `Contents/Resources`.

`EXCLUDED_SOURCE_FILE_NAMES` should exclude at least:

```text
_internal 2.bundle
_internal 3.bundle
_internal*.bundle
__pycache__
*.pyc
*.bak*
.DS_Store
*.map
build
cache
temp
tmp
test
tests
node_modules
*.spec
```

When a component is copied by an explicit script, exclude the same source files
from file-system synchronized resource copying. This prevents the same helper
from appearing both in the intended subdirectory and at `Contents/Resources`
root.

## 9. Release Size Audit Checklist

Run these checks before publishing a Release:

```sh
APP="/path/to/kmgccc_player.app"

du -sh "$APP"
find "$APP" -type f -print0 | xargs -0 du -h | sort -hr | head -20
find "$APP" -type d -maxdepth 5 -print0 | xargs -0 du -sh | sort -hr | head -20
```

Mach-O architecture audit:

```sh
find "$APP" -type f -print0 | while IFS= read -r -d '' f; do
  if file "$f" | grep -q 'Mach-O'; then
    info="$(lipo -info "$f" 2>/dev/null || file "$f")"
    case "$info" in
      *x86_64*|*universal*|*Universal*) printf '%s | %s\n' "${f#$APP/}" "$info" ;;
    esac
  fi
done
```

The x86_64 / universal audit should print nothing for an arm64-only Release.

Also check:

- No unexpected plaintext `png`, `jpg`, or `jpeg` originals for protected art.
- No `__pycache__`, `*.pyc`, `.dSYM` inside the `.app`, `*.map`,
  `node_modules`, `*.bak*`, temp, cache, or test artifacts.
- No duplicate `_internal *.bundle` or numbered helper binaries.
- `codesign --verify --deep --strict --verbose=2 "$APP"` passes.
- QQMusic helper stdio JSON smoke test passes.
- LDDC server minimal smoke test passes.
- SACAD helper minimal smoke test passes.
- AMLL pages load in the lyrics panel and fullscreen lyric surfaces.
- BKArt encrypted assets load in the relevant now-playing surfaces.

## 10. Update Procedure

Use this process for any third-party runtime update:

1. Identify the upstream version, source commit, release artifact, or dependency
   lock state.
2. Update source or dependencies in the component-specific source directory.
3. Build locally as arm64-only.
4. Remove build leftovers, caches, pyc files, backup files, duplicate bundles,
   and old runtimes.
5. Place only the runtime-required artifacts in the expected bundle source path.
6. Verify `file` and `lipo -info` for every executable, `.dylib`, and `.so`.
7. Run a clean Release build.
8. Run the Release size audit checklist.
9. Run component smoke tests.
10. Record the upstream version, commit, source URL, build command, and any local
    patches in the relevant maintenance document or release notes.

If the update changes runtime paths, Swift launch paths, or bundle layout, update
this document in the same change.
