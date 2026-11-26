# CLI reference

## Install

```bash
dart install shorthand_sanitizer
```

Re-run it to upgrade; `dart uninstall shorthand_sanitizer` removes it. Ensure
its bin directory is in your `PATH`:

- **macOS:** `~/Library/Application Support/Dart/install/bin`
- **Linux:** `~/.local/state/Dart/install/bin` (or
  `$XDG_STATE_HOME/Dart/install/bin` if set)
- **Windows:** `%LOCALAPPDATA%\Dart\install\bin`

Alternative: `dart pub global activate shorthand_sanitizer`.

### Requirements

- `shorthand` itself needs Dart **3.13** or later.
- Target packages need language version ≥ **3.10**; packages below it, or with
  no package config (run `dart pub get`), are skipped with a warning naming the
  package, and the run exits 65.
- Runs on macOS, Linux, and Windows.

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

## Options

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
  default (see [How it works](how-it-works.md#which-files-it-touches)).
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

## Exit codes

| Code | Meaning |
| :--- | :--- |
| `0` | Success. |
| `1` | `--set-exit-if-changed` and at least one site converted or would convert. Files are still written, as with `dart format`. |
| `64` | Usage error: bad option, invalid glob, malformed `--skip` or `--since` value, `--changed` with `--since`, missing or non-`.dart` path, no default root. Also when git cannot answer `--changed` or `--since`: unknown revision, not a git repository, git missing or failing. |
| `65` | A file the run should have processed was skipped: its library has analysis errors (see `--allow-errors`), its package is below language 3.10 or has no package config entry (`dart pub get`), it is a part whose library does not exist, a file of its library could not be read or is not valid UTF-8 (`--allow-errors` does not change this), or a directory could not be read. Everything else still ran; the warnings on stderr name each one. Takes precedence over `1`. |
| `69` | Dart SDK not found, or `DART_SDK` is set to a directory that is not one. |
| `74` | A file could not be written (read-only file or directory, disk full), or was edited or deleted while the run analyzed it. The library's conversions were dropped and its files keep their current bytes ([how writes work](how-it-works.md#which-files-it-touches)). If a file could not be restored after a failed rename, the error names it and its backup. Earlier libraries stay written, and the rest of the run still completed. Takes precedence over `65` and `1`. |

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
