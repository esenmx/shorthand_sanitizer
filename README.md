# shorthand_sanitizer

[![pub package](https://img.shields.io/pub/v/shorthand_sanitizer.svg)](https://pub.dev/packages/shorthand_sanitizer) [![pub points](https://img.shields.io/pub/points/shorthand_sanitizer)](https://pub.dev/packages/shorthand_sanitizer/score) [![CI](https://github.com/esenmx/shorthand_sanitizer/actions/workflows/ci.yaml/badge.svg)](https://github.com/esenmx/shorthand_sanitizer/actions/workflows/ci.yaml) [![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Rewrites `Type.member` to [dot shorthand](https://dart.dev/language/dot-shorthands) `.member` across a whole Dart or Flutter project, checking every site by re-resolving it, then prunes the imports the dropped prefixes orphaned. Dart's IDE assist *Convert to dot shorthand* does one site at a time; dotsan does the project in one verified run. Rewrites packages at language version 3.10+; dotsan itself needs Dart 3.13+.

```dart
// Before
return Padding(
  padding: EdgeInsets.all(16),
  child: Text(
    label,
    textAlign: TextAlign.center,
    overflow: TextOverflow.ellipsis,
  ),
);
```

```dart
// After `dotsan && dart format .`
return Padding(
  padding: .all(16),
  child: Text(label, textAlign: .center, overflow: .ellipsis),
);
```

`dotsan` safely removes redundant type prefixes, and `dart format` naturally reflows arguments that now fit within your line length limit.

---

## Install

```bash
dart install shorthand_sanitizer
```

Re-run it to upgrade; `dart uninstall shorthand_sanitizer` removes it. Ensure its bin directory is in your `PATH` (`~/Library/Application Support/Dart/install/bin` on macOS, `~/.local/state/Dart/install/bin` on Linux — `$XDG_STATE_HOME/Dart/install/bin` if set — `%LOCALAPPDATA%\Dart\install\bin` on Windows).

Alternative: `dart pub global activate shorthand_sanitizer`.

---

## Quick Start (Plug & Play)

Run `dotsan` in any Dart or Flutter project root:

```bash
dotsan && dart format .
```

That's it! Your project is now upgraded to modern dot shorthands with zero orphaned imports.

---

## Usage & Options

```bash
# Sanitize all roots (lib, test, bin, etc.)
dotsan

# Preview changes (--dry-run)
dotsan lib test -n

# Keep specific members prefixed
dotsan --skip=AsyncValue.error

# Exclude matching file globs
dotsan --exclude="**/legacy/**"

# Also rewrite files analysis_options.yaml excludes
dotsan --no-analyzer-excludes

# Also rewrite generated files
dotsan --include-generated

# Why did a site stay prefixed?
dotsan lib/page.dart -n --explain

# CI gate: exit 1 if any site would still convert, 65 if a file was skipped
dotsan -n --set-exit-if-changed

# Machine-readable report
dotsan lib -n --format=json

# Also rewrite files whose library already has analysis errors
dotsan --allow-errors

# Show version (-h for full options)
dotsan -v
```

- `--skip`: Accepts `Type.member`, `prefix.Type.member` or bare `member` names (comma-separated or repeated; padding around the commas is fine). `Type` is the declaring type or the spelling at the site (`m.Fit.cover`, a typedef). Any other shape (`.cover`, `Fit.`) is a usage error, and an entry that matched no site in the run gets a warning — a typo never silently converts what you meant to keep.
- `--exclude`: Glob patterns (comma-separated or repeated). A glob with a `/` matches the path relative to the working directory, like the path arguments themselves (`lib/legacy/**`, `**/legacy/**`); one without matches the file name (`firebase_options.dart`, `*.g.dart`). Globs use `/` on every platform, Windows included: a `\` escapes the next character. A glob that matched no file gets a warning, and a file you named on the command line that an exclude skips gets one too.
- `--[no-]analyzer-excludes`: On by default — a file is left alone when it matches the `analyzer: exclude:` globs of its own package's `analysis_options.yaml`. Unlike `dart analyze`, a parent package's excludes never reach a nested package: a parent's `exclude: [example/**]` does not hide `example/` when it has its own `pubspec.yaml`. `--no-analyzer-excludes` processes those files.
- Pruning never edits a file the run leaves alone (excluded, generated or not among the given paths): a conversion in a part file whose orphaned import lives in an off-limits file stays prefixed, while other conversions in that part file still proceed.
- `--explain` (`-e`): After each file's conversions, lists every site left prefixed with its reason, and on stderr names the Dart SDK used and lists each generated file skipped. Reasons include `no context type`, `context type Color declares no static red`, `rebinds to Base.a`, the analyzer's own error on the shorthand, and `skip-listed`. Point it at one file — a Flutter app keeps thousands of `Theme.of(context)`-style sites prefixed.
- `--set-exit-if-changed`: Exits 1 if any site converted (or, with `--dry-run`, would convert). Without `--dry-run` the files are still written, as with `dart format`. A skipped file fails the run with 65 whether or not this flag is set, so a CI gate never passes on files it did not check.
- `--format=json`: Prints the report as one JSON document on stdout (schema below), even on a terminal; warnings stay on stderr.
- `--allow-errors`: A file whose library already has an analysis error is skipped by default and listed on stderr, since verification cannot tell a rewrite's damage apart inside code that does not compile. This flag processes it anyway.
- **Generated Files**: Detected by their header comment and skipped (e.g., `build_runner`, `firebase_options.dart`, pigeon, protoc, and slang outputs), while handwritten files like `page.preview.dart` are processed normally. The header is the run of `//` and `/* */` comments before the first code; a `///` doc comment counts only when it opens with the marker (`/// Generated file.`, as slang writes), so a library doc that merely mentions generated code is processed. Every run counts the generated files it skipped on stderr (`--explain` lists them); a generated file named on the command line gets a warning.
- **Directories**: Walks skip hidden directories and each package's own `build/` output; a `build/` directory of sources deeper in a package is processed.

### Exit codes

| Code | Meaning |
| :--- | :--- |
| `0` | Success. |
| `1` | `--set-exit-if-changed` and at least one site converted or would convert. Files are still written, as with `dart format`. |
| `64` | Usage error: bad option, invalid glob, malformed `--skip` entry, missing or non-`.dart` path, no default root. |
| `65` | A file the run should have processed was skipped: its library has analysis errors (see `--allow-errors`), its package is below language 3.10 or has no package config entry (`dart pub get`), it is a part whose library does not exist, or a directory could not be read. Everything else still ran; the warnings on stderr name each one. Takes precedence over `1`. |
| `69` | Dart SDK not found, or `DART_SDK` is set to a directory that is not one. |
| `74` | A file could not be written (read-only, for example). The conversion that needed it was dropped: neither its file nor the imports it would prune elsewhere were written. Files converted earlier, even in the same library, stay written, and the rest of the run still completed. |

### JSON report

`--format=json` replaces the text report and summary with one document:

- Top level: `dryRun` (bool), `files` (array, in report order: every file written, or with `--dry-run` that would be, and with `--explain` every file with a kept site), `converted` (int), `kept` (int: explained kept sites, 0 without `--explain`), `skipListed` (int), `removedImports` (int).
- What the run left undone, each an array (empty when nothing): `skippedWithErrors`, `skippedOrphanParts` and `skippedGenerated` (paths), `skippedBelowFloor` (`root`, `version`, `files`), `skippedUnconfigured` (`root`, `files`), `unreadableDirectories` (`path`, `error`), `writeFailures` (`file`, `path`, `error`), `unmatchedSkips` and `unmatchedExcludes` (strings).
- Each file: `path` (relative to the working directory when inside it, else absolute), `removedImports` (int), `prunedImports` (array), `sites` (array).
- Each pruned import: `line` (1-based, of `import`, in the file as the run found it), `uri` (as written), `replacement` (`"library;"` when the directive was replaced to keep the file's header on the library, else null), `deletedComment` (the trailing `//` comment deleted with it, or null), `keptComment` (a trailing `// ignore_for_file:` comment left on the line, or null).
- Each site: `line` and `column` (1-based, of the `Type` prefix, in the file as the run found it), `before` (`Type.member` as written), `after` (`.member`, or null when kept), `keptReason` (string, or null when converted).
- Kept sites are listed only with `--explain`.

```json
{
  "dryRun": true,
  "converted": 1,
  "kept": 1,
  "skipListed": 0,
  "removedImports": 0,
  "files": [
    {
      "path": "lib/main.dart",
      "removedImports": 0,
      "prunedImports": [],
      "sites": [
        {"line": 3, "column": 19, "before": "Fit.contain", "after": null, "keptReason": "no context type"},
        {"line": 4, "column": 11, "before": "Fit.cover", "after": ".cover", "keptReason": null}
      ]
    }
  ],
  "skippedWithErrors": [],
  "skippedBelowFloor": [],
  "skippedUnconfigured": [],
  "skippedOrphanParts": [],
  "unreadableDirectories": [],
  "skippedGenerated": [],
  "writeFailures": [],
  "unmatchedSkips": [],
  "unmatchedExcludes": []
}
```

---

## How It Works & What Converts

`dotsan` uses the **Dart Analyzer API** directly:

1. Rewrites candidate expressions speculatively in memory.
2. Re-resolves the AST in memory.
3. Keeps a rewrite **only** if the shorthand resolves to the same element with the same static type (or to a const alias / redirecting forwarder in a slot typed exactly as it), and the file's library gains **no analyzer diagnostic of any severity** (a multiset of severity, code and message; lint rules don't run).
4. Prunes any `import` directives left unused when prefixes are dropped (preserving top-of-file `///` doc comments and stripping trailing `//` comments on pruned import lines), and names each one in the report under its file (`1: import 'fit.dart' -> removed, with its trailing comment // …`). A `--dry-run` predicts these exactly.

### Converts Cleanly

| Kind | Before | After |
| :--- | :--- | :--- |
| **Enum values** | `TextAlign.center` | `.center` |
| **Named constructors** | `EdgeInsets.all(16)` | `.all(16)` |
| **Factory constructors** | `BorderRadius.circular(8)` | `.circular(8)` |
| **Static getters & fields** | `Duration.zero` | `.zero` |
| **Const aliases** in a slot of exactly that type | `Alignment.topCenter` | `.topCenter` |
| **Redirecting-factory forwarders** in a slot of exactly that type | `padding: EdgeInsets.only(left: 8)` | `.only(left: 8)` |

### Intentionally Stays Prefixed

`dotsan` leaves expressions prefixed when context type is ambiguous or would change program semantics:

```dart
// Unwitnessed context (type is Object, not Fit)
final Object o = Fit.cover;

// Sibling namespace (Colors.red, context is Color)
const Color c = Colors.red;

// Rebind risk (.a would silently bind Base.a)
const Base x = Sub.a;

// Context is List<Fit>, not enum
final l = Fit.values;

// Unnamed constructors (.new) and explicit `new` invocations are not rewritten
Text('Hello');
new EdgeInsets.all(8);

// Metadata annotations (@.instance is not valid Dart syntax)
@MyAnnot.instance

final G<num> g = IntG.of(1); // typedef IntG = G<int> fixes the type argument

final Geo a = Box.all(1)..log(); // the cascade observes the rebind's type
```

---

## OS Caching & Performance

Every candidate verification requires an analyzer resolution. To make runs fast, `dotsan` caches analyzer data on the OS:

- **Cache Locations**:
  - **macOS**: `~/Library/Caches/dotsan`
  - **Linux**: `$XDG_CACHE_HOME/dotsan` (or `~/.cache/dotsan`)
  - **Windows**: `%LOCALAPPDATA%\dotsan`
- **What is cached**: Linked element models for the Dart SDK, dependencies, and project libraries are persisted to an evicting file byte store (capped at 1 GiB, LRU) fronted by an in-memory cache.
- **Effects on OS & Performance**:
  - **First run vs subsequent runs**: The first run links element models. Subsequent runs (such as running without `-n` after a `--dry-run`, or processing another project on the same SDK) skip linking and run >2x faster.
  - **Content-addressed & safe**: Cache entries are keyed by content signatures; stale entries never corrupt results.
  - **Safe to clear**: You can wipe the cache folder at any time (`rm -rf ~/Library/Caches/dotsan`); `dotsan` rebuilds it automatically on the next run.

---

## Requirements

- Target packages need language version ≥ **3.10**; packages below it, or with no package config (run `dart pub get`), are skipped with a warning naming the package, and the run exits 65.
- Runs on macOS, Linux and Windows: Linux and Windows in CI; macOS locally.

---

## Agent skill

This package ships an agent skill in `skills/shorthand-sanitizer-dotsan/`. Install it into your project's agent config with:

```sh
dart run skills@ get --package shorthand_sanitizer --agent claude --all
```

Name your agent with `--agent`. Without it, the command auto-detects the agent from an existing agent directory; in a project that has none yet, it prints "Could not auto-detect agent", exits 0 and installs nothing.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

MIT — see [LICENSE](LICENSE).
