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

# Also rewrite generated files
dotsan --include-generated

# Why did a site stay prefixed?
dotsan lib/page.dart -n --explain

# CI gate: exit 1 if any site would still convert
dotsan -n --set-exit-if-changed

# Machine-readable report
dotsan lib -n --format=json

# Also rewrite files whose library already has analysis errors
dotsan --allow-errors

# Show version (-h for full options)
dotsan -v
```

- `--skip`: Accepts `Type.member` or bare `member` names (comma-separated). `Type` is the declaring type or the spelling at the site (`m.Fit.cover`, a typedef).
- `--exclude`: Glob pattern matching CWD-relative paths or file basenames (comma-separated). `analyzer: exclude:` in analysis_options.yaml is not honoured — repeat those globs here. Pruning never edits a file the run leaves alone (excluded, generated or not among the given paths): a part whose conversion would prune an import there stays prefixed.
- `--explain` (`-e`): After each file's conversions, lists every site left prefixed with its reason. Reasons include `no context type`, `context type Color declares no static red`, `rebinds to Base.a`, the analyzer's own error on the shorthand, and `skip-listed`. Point it at one file — a Flutter app keeps thousands of `Theme.of(context)`-style sites prefixed.
- `--set-exit-if-changed`: Exits 1 if any site converted (or, with `--dry-run`, would convert). Without `--dry-run` the files are still written, as with `dart format`.
- `--format=json`: Prints the report as one JSON document on stdout (schema below), even on a terminal; warnings stay on stderr.
- `--allow-errors`: A file whose library already has an analysis error is skipped by default and listed on stderr, since verification cannot tell a rewrite's damage apart inside code that does not compile. This flag processes it anyway.
- **Generated Files**: Automatically detected and skipped by their header comment (e.g., `build_runner`, `firebase_options.dart`, pigeon, protoc, and slang outputs), while handwritten files like `page.preview.dart` are processed normally.

### Exit codes

| Code | Meaning |
| :--- | :--- |
| `0` | Success. |
| `1` | `--set-exit-if-changed` and at least one site converted or would convert. Files are still written, as with `dart format`. |
| `64` | Usage error: bad option, invalid glob, missing or non-`.dart` path, no default root. |
| `69` | Dart SDK not found; set `DART_SDK` to its directory. |
| `74` | A file could not be written (read-only, for example). The conversion that needed it was dropped: neither its file nor the imports it would prune elsewhere were written. Files converted earlier, even in the same library, stay written, and the rest of the run still completed. |

### JSON report

`--format=json` replaces the text report and summary with one document:

- Top level: `dryRun` (bool), `files` (array, in report order: every file written, or with `--dry-run` that would be, and with `--explain` every file with a kept site), `converted` (int), `kept` (int: explained kept sites, 0 without `--explain`), `skipListed` (int), `removedImports` (int).
- Each file: `path` (relative to the working directory when inside it, else absolute), `removedImports` (int), `sites` (array).
- Each site: `line` and `column` (1-based, of the `Type` prefix), `before` (`Type.member` as written), `after` (`.member`, or null when kept), `keptReason` (string, or null when converted).
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
      "sites": [
        {"line": 3, "column": 19, "before": "Fit.contain", "after": null, "keptReason": "no context type"},
        {"line": 4, "column": 11, "before": "Fit.cover", "after": ".cover", "keptReason": null}
      ]
    }
  ]
}
```

---

## How It Works & What Converts

`dotsan` uses the **Dart Analyzer API** directly:

1. Rewrites candidate expressions speculatively in memory.
2. Re-resolves the AST in memory.
3. Keeps a rewrite **only** if the shorthand resolves to the same element with the same static type (or to a const alias / redirecting forwarder in a slot typed exactly as it), and the file's library gains **no analyzer diagnostic of any severity** (a multiset of severity, code and message; lint rules don't run).
4. Prunes any `import` directives left unused when prefixes are dropped.

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

// Unnamed constructors (.new) are not rewritten
Text('Hello');

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

- Target packages need language version ≥ **3.10**; packages below it, or with no package config (run `dart pub get`), are skipped with a warning naming the package.
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
