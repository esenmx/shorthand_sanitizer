# shorthand_sanitizer

[![pub package](https://img.shields.io/pub/v/shorthand_sanitizer.svg)](https://pub.dev/packages/shorthand_sanitizer)
[![pub points](https://img.shields.io/pub/points/shorthand_sanitizer)](https://pub.dev/packages/shorthand_sanitizer/score)
[![CI](https://github.com/esenmx/shorthand_sanitizer/actions/workflows/ci.yaml/badge.svg)](https://github.com/esenmx/shorthand_sanitizer/actions/workflows/ci.yaml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`shorthand` rewrites `Type.member` to Dart's
[dot shorthand](https://dart.dev/language/dot-shorthands) `.member` across a
whole Dart or Flutter project, then removes the imports the dropped prefixes
left unused. It keeps a rewrite only when the analyzer proves it changes
nothing.

**Why.** By hand, you visit every `EdgeInsets.all(16)` and `TextAlign.center` in
the project. Find-and-replace is faster but unsafe: some rewrites still compile
yet point at a different member ([example](#what-stays-prefixed)). The IDE's
_Convert to dot shorthand_ assist is safe but fixes one site at a time.
`shorthand` does the whole project in one run, checks every rewrite with the
analyzer, and `--explain` tells you why it left a site alone.

**How.** Install it once, then run it from your project root. `shorthand` needs
Dart 3.13+ and rewrites packages at language version 3.10+.

```bash
dart install shorthand_sanitizer
shorthand && dart format .
```

<!-- no-compile -->

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

<!-- no-compile -->

```dart
// After `shorthand && dart format .`
return Padding(
  padding: .all(16),
  child: Text(label, textAlign: .center, overflow: .ellipsis),
);
```

`shorthand` drops the prefixes; `dart format` then reflows the arguments that
now fit within your line length.

---

## Install

```bash
dart install shorthand_sanitizer
```

Re-run it to upgrade; `dart uninstall shorthand_sanitizer` removes it. Ensure
its bin directory is in your `PATH`
(`~/Library/Application Support/Dart/install/bin` on macOS,
`~/.local/state/Dart/install/bin` on Linux — `$XDG_STATE_HOME/Dart/install/bin`
if set — `%LOCALAPPDATA%\Dart\install\bin` on Windows).

Alternative: `dart pub global activate shorthand_sanitizer`.

### Requirements

- `shorthand` itself needs Dart **3.13** or later.
- Target packages need language version ≥ **3.10**; packages below it, or with
  no package config (run `dart pub get`), are skipped with a warning naming the
  package, and the run exits 65.
- Runs on macOS, Linux and Windows: Linux and Windows in CI; macOS locally.

---

## Usage

Run `shorthand` from a package or pub workspace root. With no paths it processes
each of `lib`, `bin`, `test`, `example`, `tool`, `integration_test` and
`benchmark` that exists (at the root and in each `workspace:` member); pass
files or directories to narrow the run.

```bash
# Sanitize every default root that exists
shorthand

# Preview changes (--dry-run)
shorthand lib test -n

# Keep specific members prefixed
shorthand --skip=AsyncValue.error

# Exclude matching file globs
shorthand --exclude="**/legacy/**"

# Also rewrite files analysis_options.yaml excludes
shorthand --no-analyzer-excludes

# Also rewrite generated files
shorthand --include-generated

# Why did a site stay prefixed?
shorthand lib/page.dart -n --explain

# CI gate: exit 1 if any site would still convert, 65 if a file was skipped
shorthand -n --set-exit-if-changed

# Only process git-modified/untracked files, or files changed since a ref
shorthand --changed
shorthand --since=origin/main

# Machine-readable report
shorthand lib -n --format=json

# Also rewrite files whose library already has analysis errors
shorthand --allow-errors

# Show version (-h for full options)
shorthand -v
```

### Options

- `--dry-run` (`-n`): Reports what would change, including the imports it would
  prune, without writing any file.
- `--skip`: Accepts `Type.member`, `prefix.Type.member` or bare `member` names
  (comma-separated or repeated; padding around the commas is fine). `Type` is
  the declaring type or the spelling at the site (`m.Fit.cover`, a typedef). Any
  other shape (`.cover`, `Fit.`) is a usage error, and an entry that matched no
  site in the run gets a warning, so a typo does not silently convert what you
  meant to keep. The exception is `--changed` and `--since`: those runs see only
  part of the project, so they never warn about an unmatched `--skip` or
  `--exclude`, and a typo there converts with no warning.
- `--exclude`: Glob patterns (comma-separated or repeated). A glob with a `/`
  matches the path relative to the working directory, like the path arguments
  themselves (`lib/legacy/**`, `**/legacy/**`); one without matches the file
  name (`firebase_options.dart`, `*.g.dart`). Globs use `/` on every platform,
  Windows included: a `\` escapes the next character. A glob that matched no
  file gets a warning, and a file you named on the command line that an exclude
  skips gets one too.
- `--[no-]analyzer-excludes`: On by default — a file is left alone when it
  matches the `analyzer: exclude:` globs of its own package's
  `analysis_options.yaml`. Unlike `dart analyze`, a parent package's excludes
  never reach a nested package: a parent's `exclude: [example/**]` does not hide
  `example/` when it has its own `pubspec.yaml`. `--no-analyzer-excludes`
  processes those files.
- `--include-generated`: Also rewrites generated files, which are skipped by
  default (see [Which files it touches](#which-files-it-touches)).
- `--allow-errors`: A file whose library already has an analysis error is
  skipped by default and listed on stderr, since verification cannot tell a
  rewrite's damage apart inside code that does not compile. This flag processes
  it anyway, unless one of its files cannot be read or is not valid UTF-8. When
  a `part` has no file the analyzer can use (not generated yet, for example),
  its library still converts but keeps every import, since that part may need
  one.
- `--explain` (`-e`): After each file's conversions, lists every candidate site
  left prefixed with its reason, and on stderr names the Dart SDK used and lists
  each generated file skipped. Reasons include `no context type`,
  `context type Color declares no static red`, `rebinds to Base.a`, the
  analyzer's own error on the shorthand, and `skip-listed`. Sites `shorthand`
  never considers, such as `Enum.values`, `@Type.member` annotations, unnamed
  constructors (`Text(...)`), or a static field read as a receiver
  (`Fit.cover.name`), are not listed. Point it at one file — a Flutter app keeps
  thousands of `Theme.of(context)`-style sites prefixed.
- `--set-exit-if-changed`: Exits 1 if any site converted (or, with `--dry-run`,
  would convert). Without `--dry-run` the files are still written, as with
  `dart format`. A skipped file fails the run with 65 whether or not this flag
  is set, so a CI gate never passes on files it did not check.
- `--format=json`: Prints the report as one JSON document on stdout
  ([schema below](#json-report)), even on a terminal; warnings stay on stderr.
- `--changed`: Processes only `.dart` files with uncommitted changes in git
  (modified, staged, or untracked). Combining it with `--since` is a usage
  error.
- `--since=<ref>`: Processes only `.dart` files whose working-tree content
  differs from `<ref>` in git, plus untracked ones. Combining it with
  `--changed` is a usage error.

### Which files it touches

- **Generated files**: Detected by their header comment and skipped (e.g.,
  `build_runner`, `firebase_options.dart`, intl, mockito, pigeon, protoc, and
  slang outputs), while handwritten files like `page.preview.dart` are processed
  normally. The header is the run of `//` and `/* */` comments before the first
  code. A line counts when it opens with a banner (`// GENERATED CODE`,
  `// File generated by …`, `// This file is automatically generated`), past an
  optional `WARNING:`, `BEGIN` or `DO NOT EDIT.` lead-in; a `///` or `/** */`
  doc comment counts only when its first line with text does
  (`/// Generated file.`, as slang writes). A bullet, a line continuing the
  previous line's sentence, or `generated` further into a sentence is prose, and
  the file is processed. The words alone decide, so a handwritten
  `// Generated by hand` still reads as a banner: `--explain` counts and lists
  the generated files a run skipped on stderr, and a generated file named on the
  command line gets a warning.
- **Directories**: Walks skip hidden directories and each package's own `build/`
  output; a `build/` directory of sources deeper in a package is processed.
- **Pruning** never edits a file the run leaves alone (excluded, generated or
  not among the given paths): a conversion in a part file whose orphaned import
  lives in an off-limits file stays prefixed, while other conversions in that
  part file still proceed.
- **Writes**: Every file of a library goes to a hidden sibling temp file first,
  with a hidden backup of its original bytes, and the originals are replaced by
  rename only after all of them are written. A failed write (disk full,
  permissions) changes nothing in that library, and if a rename fails the files
  already replaced are restored. A file edited or deleted after the run analyzed
  it is left as it is: the library is dropped with exit 74, though an edit in
  the instant before the rename is still lost. A rewrite keeps the mode, setuid,
  setgid and sticky included, the group and the BOM, and writes through a
  symlink to its target, but it is a new file: hard links detach, and owner,
  ACLs and extended attributes are not carried over. A group you cannot set
  stops the write with exit 74 when the mode gives it access, and is given up
  when the mode gives it none. The directory must be writable, not just the
  file.
- **After a kill**: Each rename is atomic but the set is not, so a process
  killed between renames leaves the library partly replaced, and it may no
  longer analyze. `ulimit -f` counts as a kill, since exceeding it ends the
  process. A kill can leave two kinds of hidden file beside the sources, which
  no run reads. `.<file>.<pid>.<n>.shorthand-tmp` holds new text or an
  unfinished copy, never the only copy of anything, and you can delete it.
  `.<file>.<pid>.<n>.shorthand-backup` always holds a file's complete original
  bytes and mode and can be the only copy left, so keep it until you have
  checked. Run `dart analyze` first: if the library is clean, the run had
  finished, so keep the result and delete the backups. Otherwise undo the run by
  moving each backup over its file, unless you have edited that file since:

  ```sh
  mv lib/.main.dart.123.1.shorthand-backup lib/main.dart
  ```

---

## How it works

`shorthand` uses the **Dart Analyzer API** directly:

1. Rewrites candidate expressions speculatively in memory.
2. Re-resolves the AST in memory.
3. Keeps a rewrite **only** if the shorthand resolves to the same element with
   the same static type (or to a const alias / redirecting forwarder in a slot
   typed exactly as it), and the file's library gains **no analyzer diagnostic
   of any severity** (a multiset of severity, code and message; lint rules don't
   run).
4. Prunes any `import` directives left unused when prefixes are dropped
   (preserving top-of-file `///` doc comments and stripping trailing `//`
   comments on pruned import lines), and names each one in the report under its
   file (`1: import 'fit.dart' -> removed, with its trailing comment // …`). A
   `--dry-run` predicts these exactly.
5. Names each `<Type>` it inserted on an untyped list or set under its file
   (`2: inserted <Fit>`), so every edit beside a conversion is in the report.

### What converts

| Kind | Before | After |
| :--- | :--- | :--- |
| **Enum values** | `TextAlign.center` | `.center` |
| **Named constructors** | `EdgeInsets.all(16)` | `.all(16)` |
| **Factory constructors** | `Border.all(width: 2)` | `.all(width: 2)` |
| **Static getters & fields** | `Duration.zero` | `.zero` |
| **Const aliases** in a slot of exactly that type | `Alignment.topCenter` | `.topCenter` |
| **Redirecting-factory forwarders** in a slot of exactly that type | `padding: EdgeInsets.only(left: 8)` | `.only(left: 8)` |
| **Generic static methods** whose `<T>` is inferred | `Box.of<int>(1)` | `.of(1)` |
| **Untyped lists & sets** with 2+ convertible elements | `[Fit.cover, Fit.contain]` | `<Fit>[.cover, .contain]` |

### What stays prefixed

`shorthand` leaves expressions prefixed when context type is ambiguous or would
change program semantics:

<!-- no-compile -->

```dart
// Unwitnessed context (type is Object, not Fit)
final Object o = Fit.cover;

// Sibling namespace (Colors.red, context is Color)
const Color c = Colors.red;

// Rebind risk (.a would silently bind Base.a)
const Base x = Sub.a;

// Enum.values (context is List<Fit>, not Fit)
final List<Fit> l = Fit.values;

// Unnamed constructors (only explicit Type.member / Type.new sites convert)
Text('Hello');

// Generic static methods where dropping <T> changes inferred T
final Box b = Box.of<num>(1);

// Metadata annotations (@.instance is not valid Dart syntax)
@MyAnnot.instance

final G<num> g = IntG.of(1); // typedef IntG = G<int> fixes the type argument

final Geo a = Box.all(1)..log(); // the cascade observes the rebind's type

// Single-element untyped collections (<Fit>[.cover] saves no repeated prefix)
final single = [Fit.cover];

// Widened collection slots (narrowing List<Object?> to List<Fit> breaks .add)
final List<Object?> wide = [Fit.cover, Fit.contain];

// Untyped collections where <Box<num>> would re-infer Box(1) as Box<num>
final boxes = [Box(1), Box.zero, Box.one];
```

---

## Exit codes

| Code | Meaning |
| :--- | :--- |
| `0` | Success. |
| `1` | `--set-exit-if-changed` and at least one site converted or would convert. Files are still written, as with `dart format`. |
| `64` | Usage error: bad option, invalid glob, malformed `--skip` or `--since` value, `--changed` with `--since`, missing or non-`.dart` path, no default root. Also when git cannot answer `--changed` or `--since`: unknown revision, not a git repository, git missing or failing. |
| `65` | A file the run should have processed was skipped: its library has analysis errors (see `--allow-errors`), its package is below language 3.10 or has no package config entry (`dart pub get`), it is a part whose library does not exist, a file of its library could not be read or is not valid UTF-8 (`--allow-errors` does not change this), or a directory could not be read. Everything else still ran; the warnings on stderr name each one. Takes precedence over `1`. |
| `69` | Dart SDK not found, or `DART_SDK` is set to a directory that is not one. |
| `74` | A file could not be written (read-only file or directory, disk full), or was edited or deleted while the run analyzed it. The library's conversions were dropped and its files keep their current bytes ([how writes work](#which-files-it-touches)). If a file could not be restored after a failed rename, the error names it and its backup. Earlier libraries stay written, and the rest of the run still completed. Takes precedence over `65` and `1`. |

---

## JSON report

`--format=json` replaces the text report and summary with one document:

- Top level: `dryRun` (bool), `files` (array, in report order: every file
  written, or with `--dry-run` that would be, and with `--explain` every file
  with a kept site), `converted` (int), `kept` (int: explained kept sites, 0
  without `--explain`), `skipListed` (int), `removedImports` (int), `hoists`
  (int: `<Type>` insertions).
- What the run left undone, each an array (empty when nothing):
  `skippedWithErrors`, `skippedOrphanParts` and `skippedGenerated` (paths),
  `skippedBelowFloor` (`root`, `version`, `files`), `skippedUnconfigured`
  (`root`, `files`), `unreadableDirectories` and `unreadableFiles` (`path`,
  `error`), `writeFailures` (`file`, `path`, `error`), `unmatchedSkips` and
  `unmatchedExcludes` (strings; always empty with `--changed` or `--since`).
- Each file: `path` (relative to the working directory when inside it, else
  absolute), `removedImports` (int), `prunedImports` (array), `hoistedTypes`
  (array), `sites` (array).
- Each pruned import: `line` (1-based, of `import`, in the file as the run found
  it), `uri` (as written), `replacement` (`"library;"` when the directive was
  replaced to keep the file's header on the library, `"show ..."` or
  `"without show ..."` when `show` combinators were pruned, else null),
  `deletedComment` (the trailing `//` comment deleted with it, or null),
  `keptComment` (a trailing `// ignore_for_file:` comment left on the line, or
  null).
- Each hoisted type: `line` and `column` (1-based, of the literal's opening
  bracket, in the file as the run found it), `inserted` (`<Fit>`).
- Each site: `line` and `column` (1-based, of the `Type` prefix, in the file as
  the run found it), `before` (`Type.member` as written), `after` (`.member`, or
  null when kept), `keptReason` (string, or null when converted).
- Kept sites are listed only with `--explain`.

```json
{
  "dryRun": true,
  "converted": 1,
  "kept": 1,
  "skipListed": 0,
  "removedImports": 0,
  "hoists": 0,
  "files": [
    {
      "path": "lib/main.dart",
      "removedImports": 0,
      "prunedImports": [],
      "hoistedTypes": [],
      "sites": [
        {
          "line": 3,
          "column": 19,
          "before": "Fit.contain",
          "after": null,
          "keptReason": "no context type"
        },
        {
          "line": 4,
          "column": 11,
          "before": "Fit.cover",
          "after": ".cover",
          "keptReason": null
        }
      ]
    }
  ],
  "skippedWithErrors": [],
  "skippedBelowFloor": [],
  "skippedUnconfigured": [],
  "skippedOrphanParts": [],
  "unreadableDirectories": [],
  "unreadableFiles": [],
  "skippedGenerated": [],
  "writeFailures": [],
  "unmatchedSkips": [],
  "unmatchedExcludes": []
}
```

---

## Cache and performance

Every candidate verification requires an analyzer resolution. To make runs fast,
`shorthand` caches analyzer data on the OS:

- **Cache locations**:
  - **macOS**: `~/Library/Caches/shorthand_sanitizer`
  - **Linux**: `$XDG_CACHE_HOME/shorthand_sanitizer` (or
    `~/.cache/shorthand_sanitizer`)
  - **Windows**: `%LOCALAPPDATA%\shorthand_sanitizer`
- **What is cached**: Linked element models and unlinked unit summaries for the
  Dart SDK, dependencies, and project libraries are persisted to an evicting
  file byte store (capped at 64 MiB, LRU) fronted by an in-memory cache;
  speculative trial overlays stay in memory.
- **Effects on OS & Performance**:
  - **First run vs subsequent runs**: The first run links element models.
    Subsequent runs (such as running without `-n` after a `--dry-run`, or
    processing another project on the same SDK) skip linking and run >2x faster.
  - **Content-addressed & safe**: Cache entries are keyed by content signatures;
    stale entries never corrupt results.
  - **Safe to clear**: You can wipe the cache folder at any time
    (`rm -rf ~/Library/Caches/shorthand_sanitizer`); `shorthand` rebuilds it
    automatically on the next run.
  - **No usable cache directory**: `shorthand` then caches in memory only, for
    the length of the run.

---

## Agent skill

This package ships an agent skill in `skills/shorthand-sanitizer-usage/`.
Install it into your project's agent config with:

```sh
dart run skills@ get --package shorthand_sanitizer --agent claude --all
```

Name your agent with `--agent`. Without it, the command auto-detects the agent
from an existing agent directory; in a project that has none yet, it prints
"Could not auto-detect agent", exits 0 and installs nothing.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

MIT — see [LICENSE](LICENSE).
