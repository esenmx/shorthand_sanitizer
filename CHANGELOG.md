# Changelog

## 0.10.0 - 2026-10-04

### Breaking

- `SanitizeResult.skippedBelowFloor` is keyed by `({String root, String version})`: the package root (the file's directory when no `pubspec.yaml` encloses it) and the `major.minor` language version.
- `Candidate` is no longer exported; it was an internal detail of the AST pass.
- `FileResult(path, sites, reverted, {removedImports})` takes a list of `Site`s; `converted` and `kept` are now getters derived from them and return the same strings as before.
- `Sanitizer.run` no longer throws when a file cannot be written. The conversion that needed it is dropped and recorded in `SanitizeResult.writeFailures`, which library callers must now check; the CLI exits 74.

### Added

- `--allow-errors` (`Sanitizer(allowErrors: true)`) also rewrites files whose library already has analysis errors.
- `--set-exit-if-changed` exits 1 when at least one site converted, or with `--dry-run` would convert, so `dotsan -n --set-exit-if-changed` can gate CI. Without `--dry-run` the files are still written, as with `dart format`.
- `--format=json` prints the report as one JSON document on stdout: `dryRun`, `files` (each with `path`, `removedImports` and `sites`), `converted`, `kept`, `skipListed` and `removedImports`. Each site has a 1-based `line` and `column`, `before`, `after` (or null) and `keptReason` (or null); kept sites appear only with `--explain`. Warnings stay on stderr.
- `Site` (exported): one reported site, with its 1-based position, `before`, `after` and `keptReason`; `FileResult.sites` lists them by line, then column.

### Changed

- The below-floor warning names the package root and its `pubspec.yaml`, one line per package and version, and mentions a `// @dart=` override as the other cause.
- A file whose library already has an error-severity diagnostic is skipped by default and listed on stderr (`SanitizeResult.skippedWithErrors`): verification cannot tell a rewrite's damage apart inside code that does not compile. Pass `--allow-errors` to process it anyway.
- `--skip=Type.member` also matches the declaring type, so `--skip=Fit.cover` keeps `m.Fit.cover` (an import prefix) and `Mode.cover` (a typedef of `Fit`) prefixed too.
- Report file lines show the path relative to the working directory when the file is inside it, else absolute (`FileResult.path` stays absolute).
- The report lists every file a run writes. A library pruned for one of its parts gets its own entry, in text and JSON, with its own `removedImports`, and with `sites: []` when it has no conversion of its own. `SanitizeResult.files` therefore no longer lists only files with a conversion, as 0.9.0's did.
- The agent skill directory is renamed to `skills/shorthand-sanitizer-dotsan/` (skill name `shorthand-sanitizer-dotsan`). Install it with `dart run skills@ get --package shorthand_sanitizer --agent claude --all` (name your agent with `--agent`; without it, a project with no agent directory yet gets nothing installed).

### Fixed

- Verification compares the whole library's diagnostics as a multiset across errors, warnings and infos. A duplicate of an existing error, or a new deprecation info, now keeps the site prefixed.
- A typedef that fixes type arguments (`typedef IntG = G<int>`) no longer converts: `IntG.of(1)` builds a `G<int>`, while `.of(1)` in a `G<num>` slot builds a `G<num>`. A same-element shorthand must now keep the site's static type, so these sites stay prefixed.
- Static types are compared by a library-qualified key, not by their displayed name. Two classes named `X` in different libraries both display as `X`, so `final G<b.X> g = AG.of(const a.X());` (with `typedef AG = G<a.X>`) became `.of(const a.X())` and built a `G<b.X>` instead of a `G<a.X>`. 0.9.0 had the same hole. The same key now decides typed slots and redirecting-factory signatures.
- A licensed rebind (a const alias or a redirecting-factory forwarder) converts only in a slot typed exactly as the rebind: an argument, a typed declaration, a return, a collection element or a parameter default. A cascade target (`Box.all(1)..log()`) or an assignment (`g = Box.all(2)`) observed the forwarder's wider static type and could dispatch another extension or lose a promotion; these sites now stay prefixed with `rebinds to Geo.all outside a typed slot`.
- A shorthand that resolves to a `@useResult` member (static method, getter or constructor, same element or licensed rebind) stays prefixed. `dart analyze` reports `unused_result` on every such shorthand, even where its value is used, but the bundled analyzer does not, so `Geo.make(x)` used to become `.make(x)` and gain a warning. 0.9.0 had the same hole.
- A licensed rebind is also refused when its target carries a use-restricting annotation the original lacks (`@visibleForTesting`, `@internal`, `@protected`, `@visibleForOverriding`, `@visibleOutsideTemplate`, `@doNotSubmit`, `@experimental`, `@Deprecated`), with the reason `rebinds to Geo.all, which is @visibleForTesting`. As in the SDK analyzer, `@internal` is allowed within its own package, and `@visibleForTesting` in its declaring library or under the package's `test/`. Before, `use(Box.all(1))` became `use(.all(1))` onto a `@visibleForTesting` forwarder. That adds an `invalid_use_of_visible_for_testing_member` warning, which `dart analyze` reports but the bundled analyzer missed.
- A package with no entry in the package config the analyzer used is skipped with a warning naming its root and asking to run `dart pub get` there (`SanitizeResult.skippedUnconfigured`). Before, a package without `dart pub get`, or an `example/` resolved only through its parent, was analyzed at the analyzer's default or the parent's language version and could be rewritten below the 3.10 floor. The version is never inferred from pubspec text.
- Rewriting a part now prunes the import it orphans in its library (or another part), and the pruned library is re-verified; if pruning would leave any diagnostic, nothing in that file converts and each site says `pruning its orphaned imports leaves …`. Before, the orphaned import stayed behind as a new `unused_import` warning.
- Generated-file detection skips a leading UTF-8 BOM, reads `/* … */` block-comment banners, and reads a banner of any length; before, it only looked at the first 1024 bytes of `//` lines.
- A rewrite keeps the file's UTF-8 BOM, in every unit it writes.
- Overlapping path arguments (`lib lib lib/.`, a file inside a directory also given, or one file reached through a symlink and directly) process each file once.
- A relative `--exclude` glob now matches a file reached through a symlinked path argument (macOS `/tmp` and `/var` are symlinks). The path is resolved before matching.
- A path argument that does not exist, or a file that is not a `.dart` file, is a usage error (exit 64) instead of a silent no-op.
- An invalid `--exclude` glob is a usage error (exit 64) instead of an unhandled exception.
- Windows: an installed `dotsan` (AOT, no `DART_SDK`) crashed looking up `dart` with `which`; it now uses `where` there and takes the first match. When no SDK is found at all, `dotsan` says so and exits 69.
- Pruning a part's orphaned import never edits a library file the run leaves alone: one that is `--exclude`d, has a generated header, or is not among the given paths. The part's sites stay prefixed instead, with the reason `pruning its orphaned imports would edit lib.dart, which is excluded`.
- A file `dotsan` cannot write (read-only, for example) is an error on stderr with exit code 74 instead of an unhandled `PathAccessException` that aborted the run. Each file's conversion, together with the imports it prunes elsewhere in its library, is written all or nothing: every target is checked as writable before the first write. Files converted earlier in the run, even in the same library, stay written. Library: `SanitizeResult.writeFailures`.
- With two imports of the same URI, pruning removes the one the rewrite orphaned and keeps the one you had already left unused.
- A library processed after one of its parts now sees the part's rewritten text. Each file is written while its overlay still holds the same text, so the analyzer no longer re-reads the pre-write disk and leaves an orphaned import behind in the library.

### Removed

- `.pubignore`: `.gitignore` already keeps editor and build directories out of the package, and pub never publishes dot-directories.

## 0.9.0

- `--explain` (`-e`) lists every site left prefixed after each file's conversions, each with its reason. Sites the static pre-check rules out before any resolve show `no context type`, `context type Color declares no static red` or `neither Foo nor a supertype declares static bar`. Sites the verify loop refuses show `rebinds to Base.a`, the analyzer's own error on the shorthand, or `introduces an error: …`; `skip-listed` sites say so. Files with nothing converted are listed too, and the summary gains `, N kept`. Library: `Sanitizer(explain: true)`, `FileResult.kept`, `SanitizeResult.keptCount`; without the flag, `files` still lists only files with a conversion. Point it at one file: a Flutter app keeps thousands of `Theme.of(context)`-style sites prefixed (8,067 on a 589-file app).

- `--exclude` globs: a leading `**/` now also matches zero directories, so `**/legacy/**` excludes a `legacy/` directory directly under the working directory, which it previously missed (`glob` ^2.2.0). Also requires `cli_util` ^0.6.0.

- Evaluated and declined: parallel analysis across isolates (`--jobs`). Every isolate loads its own SDK, Flutter and app element model. On a 589-file app, 4 workers cut a warm run at best from 7.5 s to 5.2 s at twice the memory (2.1 GB), and made a cold run slower (20.3 s → 24.6 s, 5.7 GB).

## 0.8.1

- README: the native install is now `dart install shorthand_sanitizer` (Dart 3.10+), which compiles `dotsan` into its own bin directory. The hand-rolled recipe in the 0.5.0–0.6.0 READMEs compiled into `~/.pub-cache/bin`, and pub reads every file there as a text stub: a native binary in that directory fails **every** `dart pub global activate`/`deactivate`, for any package, with `Failed to decode data using encoding 'utf-8'` (0.5.1 scoped this to dotsan's own upgrade). If you used that recipe, run `rm ~/.pub-cache/bin/dotsan` before any other `dart pub global` command.

## 0.8.0

- Fix `EdgeInsets.all(16)`, `.symmetric(...)`, `.only(...)`, `.fromLTRB(...)` (and `BorderRadius.circular(8)`, `BorderRadius.all(...)`) never converting in a `padding:`/`margin:`/`borderRadius:` slot on Flutter ≥ 3.32 — the README's own headline example. The shorthand binds the slot type's forwarder (`const factory EdgeInsetsGeometry.all(double value) = EdgeInsets.all;`), a different element, so the verdict refused it. A redirecting factory passes its arguments through untouched, so the rebind is now accepted when the chain ends at the original constructor with the same formal parameters (named ones compared by name, not order). Forwarders with a body, with differing parameter types, or landing on another constructor still stay prefixed; `const EdgeInsets.symmetric(...)` becomes `const .symmetric(...)`.

- Performance: on a 514-file Flutter app a dry run drops from 35 s to 16 s, and to under 5 s with a warm cache, at a third of the peak memory. Sites that can never verify are ruled out before any resolve — `Theme.of(context).x` (the shorthand resolves `of` against the chain's context type), `Colors.red` in a `Color` slot (no supertype of the value declares `red`), `final size = MediaQuery.sizeOf(context)` (no context type), `throw`, `as`/`is`, interpolations, binary left operands. On Flutter code these were the bulk of the candidates, each costing a speculative resolve per recovery wave; every rule is a necessary condition only, what passes is still verified. Reverted counts include them. Also: doc-comment references are not sites, lint rules no longer run on speculative resolves, analysis contexts are located per root rather than per file.

- Linked element models (SDK, packages, the project's libraries) persist across runs under the user cache home (`~/Library/Caches/dotsan`, `$XDG_CACHE_HOME/dotsan`, `%LOCALAPPDATA%\dotsan`; 1 GiB, LRU). Linking dominates a first run; `--dry-run` then the real run, or the next project on the same SDK, finds them ready. Content-keyed, safe to delete.

- Sites starved by a doomed neighbour in an earlier statement now convert: `final theme = Theme.of(context)` never converts, but applying it speculatively made `theme` an invalid type and took every later `theme.copyWith(side: BorderSide.none)` down across the statement boundary the recovery pass relies on. Never applying it keeps the rest resolving.

## 0.7.0

- Fix nested arguments never converting in files where **every** outer call is context-less — e.g. a design-token file of inferred `static const brXs = BorderRadius.all(Radius.circular(xs));` fields reported 0 sites. Round one drops all candidates (the context-less outer starves its own argument of a context type), and the recovery pass refused to run without at least one verified conversion as a base. It now recovers from an empty base — the original file trivially resolves — so the inner `Radius.circular` sites convert while the outers correctly stay prefixed.

- Adopt `package:cli_util` (`cli_logging`): a TTY-only `analyzing` spinner with elapsed time while the analyzer resolves — piped stdout stays byte-identical, since the non-ANSI `Progress` fallback would print into the parseable report — and the language-version warning now renders its `warning:` token yellow when stderr is an ANSI terminal. Evaluated and declined the rest of the package: `sdkPath` is the resolvedExecutable step alone (would regress AOT and Flutter-shim runs the hand-rolled locator handles), `BaseDirectories` has no config to home, `cli_components` is interactive-only.

- Performance: directory traversal prunes hidden and `build/` trees instead of listing then filtering; recovery skips redundant analyzer resolves when a wave yields no winners; constant lookups are memoized and the resolved SDK path cached; synthetic `Enum.values` accesses are pre-filtered instead of collected and reverted.

## 0.6.0

- CLI ported to `package:args`: short flags `-v` (`--version`), `-h` (`--help`), `-n` (`--dry-run`); generated, aligned usage; unknown options fail with exit 64 and the usage instead of a bare error. `--skip`/`--exclude` now also accept repeated occurrences in addition to comma lists.

## 0.5.1

- README: correct the AOT upgrade recipe — `pub global activate`/`deactivate` refuse a foreign binary at the shim path (`Failed to decode data using encoding 'utf-8'`), so upgrading requires `rm ~/.pub-cache/bin/dotsan` first; 0.5.0 wrongly claimed activate rewrites the shim in place.

## 0.5.0

- `dotsan` with no path arguments now scans every conventional root directory that exists — `lib`, `bin`, `test`, `example`, `tool`, `integration_test`, `benchmark` — instead of only `lib`, and exits 64 when none exist.
- Warn when files are skipped because their package's language version predates 3.10 (dot shorthands' floor), counted per version. Previously such a run reported an ordinary "converted 0 site(s)", indistinguishable from having nothing to convert.
- Generated-file detection now requires the marker inside the **leading comment block** (word-boundary match on `generated code/file/by`, `auto-generated`), instead of `generat` anywhere in the first 300 bytes — a file whose opening doc comment merely mentions generation is no longer skipped.
- Recovery pass groups co-failed candidates by enclosing statement: type inference cannot cross a statement boundary, so one re-resolve now retries one candidate per group instead of one per round — fewer analyzer passes on files with many collisions.
- README: the AOT install recipe now compiles over the `~/.pub-cache/bin/dotsan` shim (no `<version>` placeholder, no extra `PATH` directory), so a later `dart pub global activate` can never leave a stale binary shadowing the upgrade.

- Convert a rebind onto a `static const` **alias** of the original — `Alignment.topCenter` in an `AlignmentGeometry` slot now becomes `.topCenter`. The shorthand binds a different element (`AlignmentGeometry.topCenter`), but const canonicalization makes it the identical object, so the rewrite is observably a no-op. Const-value identity is the oracle; it still refuses non-const forwarders (`EdgeInsetsGeometry.all` allocates), same-valued constants of a different type (`AlignmentDirectional.center` vs `Alignment.center`), and aliases declared in the file being rewritten.

## 0.4.0

- Not documented.

## 0.3.1

- Fix `dotsan --version` reporting a stale version — the hardcoded CLI constant had drifted from `pubspec.yaml`. A test now pins the two together so it cannot drift again.
- Harden `PropertyAccess` collection with the receiver-position guard `PrefixedIdentifier` already had: `Type.staticGetter.member` keeps its prefix instead of being collected and reverted downstream.

## 0.3.0

- Convert statics reached through an import prefix (`p.Type.member`) and through a type alias (`typedef Alias = Type; Alias.member`) — the target's element is resolved past the prefix/alias to the underlying `InterfaceElement` before collecting.
- Convert static getters and fields accessed as a `PropertyAccess` (`prefix.Type.staticGetter`), not just `PrefixedIdentifier` and method-invocation forms.
- Static-method collection accepts any resolvable target expression, not only a bare `SimpleIdentifier`, so prefixed and aliased receivers (`p.Type.staticMethod(...)`) convert.

## 0.2.0

- Prune imports the rewrite orphans: dropping a `Type` prefix can leave the import that supplied `Type` with no remaining referent. The final verified resolve is the oracle — any `unused_import`/`unnecessary_import` it reports that the original file did not is a self-inflicted orphan whose directive is removed. Imports the file already left unused are untouched.
- `dotsan` reports pruned imports in its summary; `SanitizeResult.removedImportCount` / `FileResult.removedImports` expose the count.

## 0.1.0

- Initial release: type-resolved `Type.member` → `.member` batch codemod, shipped as the `dotsan` executable.
- Element-identity verification — unwitnessed contexts, sibling-namespace members (`Colors.red` in a `Color` slot), `Enum.values`, forwarder rebinds (`EdgeInsets.all` in geometry slots), and silent same-name rebinds all revert.
- Enum values, static getters/fields/methods, named/factory/const constructors; operator expressions split per-operand (`Pad.all(1) + .only(2)`).
- `--dry-run`, `--skip=Type.member|member`, `--exclude=globs`, `--include-generated`, `--version`.
- Generated files detected by leading-comment marker (build_runner, FlutterFire, pigeon, protoc, slang) — handwritten double-extension files like `*.preview.dart` are sanitized normally.
- AOT-friendly SDK discovery (`DART_SDK` → executable → `dart` on PATH / Flutter shim).
