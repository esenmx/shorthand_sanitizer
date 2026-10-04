---
status: in-progress
created: 2026-10-03
updated: 2026-10-03
---

# Plan: shorthand_sanitizer 0.10.0 — sweep fixes

## Progress

- [x] Phase 1: Diagnostic oracle
- [x] Phase 2: Element and static-type identity
- [x] Phase 3: Language-version gate
- [x] Phase 4: Library-scoped pruning and write ordering
- [x] Phase 5: Engine and CLI hygiene
- [x] Phase 6: `--set-exit-if-changed` and `--format=json`
- [x] Phase 7: CI, dependency safety net, Windows SDK discovery
- [x] Phase 8: Docs, skill, repo meta, packaging
- [x] Review round 1 (coordinator, 4c99706..4db5a2e). Each fix is a new commit, commit only, with a test that goes red first:
  - [x] R-SS-1: same-element static type compared by a library-qualified structural key, not the display string (`display_collision`)
  - [x] R-SS-2: refuse a licensed rebind whose target gains an access annotation (`vft_warning`)
  - [x] R-SS-3: refuse a cut in an excluded, generated or out-of-scope unit; report every written file (`part_prune`)
  - [x] R-SS-4: check every target is writable before a multi-file write; no unhandled exception
  - [x] R-SS-5: match baseline unused imports to their directive (`dup_uri_prune`)
  - [x] R-SS-6: drop private doc comments that restate the code
- [x] Review round 2 (coordinator, 4db5a2e..4896513). New commits, commit only:
  - [x] R2-SS-1: pin the multiset diagnostic comparison with a test that goes red under the set-based mutant
  - [x] R2-SS-2: README CI platforms (Linux and Windows in CI; macOS locally)
  - [x] R2-SS-3: skill install hint with `--agent`
- [x] Re-run format, analyze, `dart test`, the downgrade leg and pana over both rounds
- [ ] Review round 3 (coordinator, 4896513..83a3670). New commits, commit only:
  - [x] R3-SS-1: refuse shorthands of `@useResult` members (e2e)
  - [ ] R3-SS-3: key a generic function type's own type parameters by position, with bounds; readable kept reasons
  - [ ] R3-SS-4: compare real (symlink-resolved) paths for scope, dedupe and excludes
  - [ ] R3-SS-5: allow same-package `@internal` and test-scope `@visibleForTesting` rebinds
  - [ ] R3-SS-2 + R3-SS-6: write-failure scope wording, `Sanitizer.run` API change, CHANGELOG history
  - [ ] Append the two deferred SWEEP.md rows
  - [ ] Re-run format, analyze, `dart test`, downgrade, pana; 5-package corpus comparison against `/tmp/dotsan_exe_review3`
- [ ] Phase 9: Release 0.10.0

## Problem

dotsan 0.9.0 promises to rewrite `Type.member` → `.member` "only where the analyzer proves it a no-op". Today that promise breaks in four ways:
- typedef type arguments and licensed rebinds change runtime behaviour;
- an error-only, set-based check lets new warnings and duplicate errors through;
- packages without a package config are rewritten below the 3.10 floor;
- rewriting a part orphans imports in its library.

The CLI also has no CI gate and no machine output, and it exits 0 on mistyped paths. After this plan lands, every accepted site is verified by element identity, static type and a library-wide diagnostic multiset, and the CLI can gate CI.

## Invariants

- **Core promise.** A site converts only if:
  - its shorthand resolves either to the original element with the identical static type, or to a licensed rebind (`_isConstAlias` const alias, `forwardsTo` redirecting factory) in a typed slot whose type equals the rebind's static type; and
  - the library's multiset of `(unit path, severity, code, message)` gains nothing.
  - Removable-import diagnostics are excused only because they get pruned and the pruned text is re-verified.
  - Every change here narrows what converts; none widens it.
- **Layering.** `bin/dotsan.dart` imports only `package:shorthand_sanitizer/shorthand_sanitizer.dart`. `lib/` never prints or exits; the CLI owns output and exit codes.
- **Private analyzer surface** stays at the three `package:analyzer/src/…` imports at `lib/src/sanitizer.dart:19-21`. Add none (SS-S2 risk).
- **Text report contract** (pinned by tests):
  - one path line per file;
  - one `  <line>: <Type.member> -> .<member>` line per converted site;
  - with `--explain`, one `  <line>: <Type.member> kept: <reason>` line per kept site;
  - one summary line last.
  - Piped stdout carries only the report. Warnings go to stderr, with ANSI only on a terminal (`bin/dotsan.dart:96-100,115-117`).
- **Version.** `pubspec.yaml` is the only hand-maintained version. `_version` (`bin/dotsan.dart:7`) is pinned by a test that reads `--version` output.
- **New code rules:**
  - no `!`, no `late final`, never `unawaited(...)`;
  - `final class` with primary constructors, as the file already does;
  - dartdoc only on public API and on traps;
  - catch with `on Exception`, never a bare catch.
- **Fixtures** are string constants written under `Directory.systemTemp`, never tracked `.dart` files in `test/`. Nested pubspecs and deliberate errors would break analyze, format, pana and the publish dry-run.
- `analysis_options.yaml` is guarded by a PreToolUse hook (`~/.claude/hooks/config-protection.sh`). The edit this plan makes to it is a user-approved, deliberate config change (fleet decision X-17). In that step only: `touch .dart_tool/.config-edit-ok`, write the file, then `rm .dart_tool/.config-edit-ok` right away. Never use the marker for any other edit, and never leave it behind.
- `git-committer` commits **and pushes** by default. Every dispatch of it in this plan must say **"commit only, do not push"**, except the one push the final phase names. A phase commit must never reach the remote before that.

## Decisions

- **SS-S1: in scope.** `Process.runSync('which', …)` (`sanitizer.dart:47`) throws on Windows, so every Windows `dart install` user crashes.
  - The oracle is a `windows-latest` CI leg; it cannot run locally.
  - A bounded fallback is fixed in Phase 9.
- **SS-S2: keep `analyzer: ^14.0.0`; add a weekly CI `schedule:`.**
  - `pubspec.lock` is gitignored, so every CI run resolves the newest 14.x; the downgrade job covers 14.0.0.
  - Declined: capping at `<14.5.0`. Analyzer shipped 5 minors in 12 weeks (14.0.0 on 2026-06-18, 14.4.0 on 2026-09-11), in step with SDK releases. A cap would hold `dart install` users on an analyzer older than their SDK and force a release for every minor.
  - A private-API break fails loudly (compile error at install), and the schedule bounds detection to one week.
- **SS-S5: deferred, together with SS-M5's dispose half.** 12 in-process `Sanitizer.run` calls held RSS flat at about 740 MB, so no test can fail first.
- **SS-S3:** a file whose library already has an error-severity diagnostic is skipped by default and listed on stderr. `--allow-errors` / `Sanitizer(allowErrors: true)` processes it anyway.
- **SS-B4:** a package with no package-config entry is skipped with the warning "run `dart pub get`". The version is never inferred from pubspec text.
- **SS-B1:** same-element sites must keep their static type, compared as display strings. Measured: `IntG.of(1)` → `G<int>`, `Raw.of(1)` → `G<dynamic>` and pass-through `MyG.of(1)` → `G<int>`, while `.of(1)` in a `G<num>` slot → `G<num>`.
- **SS-B2:** licensed rebinds convert only in typed slots (defined in Phase 2). Explicitly typed declarations do not promote (measured); assignments and cascade targets can.
- **Exit codes:**
  - 0: success.
  - 1: `--set-exit-if-changed` and at least one site converted or would convert. Files are still written, as with `dart format`.
  - 64: usage error (bad option, invalid glob, missing or non-`.dart` path, no default root).
  - 69: SDK not found.
  - New exit paths use `exitCode = n; return;` so stdout flushes.
- **Paths:**
  - `_canonical(x) = p.normalize(p.absolute(x))` replaces `p.canonicalize`. They are identical on POSIX, but `canonicalize` lowercases on Windows while package-config roots keep their case.
  - CLI output (`_display`) shows a path relative to CWD when inside it (`.` for CWD itself), else absolute, with native separators.
  - `FileResult.path` stays absolute.
- **Breaking changes in 0.10.0** (allowed in a 0.x minor):
  - `Candidate` is no longer exported.
  - The constructor becomes `FileResult(path, sites, reverted, {removedImports})`; `converted` and `kept` become getters.
  - `SanitizeResult.skippedBelowFloor` is keyed by `({String root, String version})`.
- **New runtime dependency:** `package_config: '>=2.2.0 <4.0.0'`. It is already in analyzer's dependency graph, and `loadPackageConfig` and `packageOf` exist in both 2.2.0 and 3.0.0.
- **Planner defaults:**
  - README `## Install` is `dart install shorthand_sanitizer`, not `dart pub add`, because this is a CLI.
  - SS-G1's "exit non-zero when every file is below the floor" is not added.
- **`.pubignore` is deleted.** `.gitignore` covers `.idea/ .vscode/ build/ coverage/`, and `.claude/` is a dot-directory pub never publishes (confirmed with a dry-run).
- **CHANGELOG:**
  - Each phase adds bullets under `## Unreleased` (`### Breaking/Added/Changed/Fixed/Removed`).
  - Phase 9 normalises the headings.
  - No "Requires Dart 3.13" line: 0.9.0 already shipped `^3.13.0`.

## Files

|Path|Action|Exact symbols|
|--|--|--|
|`lib/src/sanitizer.dart`|modify|`sdkPath`, `Candidate`, `FileResult`, `Site`(new), `SanitizeResult`, `Sanitizer` (`allowErrors`, `isGenerated`, `run`, `_sanitizeFile`, `_collectFiles`), `_PackageGate`(new), `_FileSanitizer`, `_Attempt`, `_ResolvedShorthand`, `_ShorthandIndex`, `_CandidateCollector`, `_Viability.typedSlotOf`(new), `_DiagKey`/`_census`/`_firstNew`/`_canonical`(new), `_orphanRanges`; delete `_errorKey`, `_errorKeys`, `_importIssueKeys`|
|`lib/shorthand_sanitizer.dart`|modify|`show FileResult, SanitizeResult, Sanitizer, Site, sdkPath`|
|`bin/dotsan.dart`|modify|`_buildParser` (+`allow-errors`, `set-exit-if-changed`, `format`), `main`, `_display`(new), `_json`(new)|
|`test/regression_test.dart`|create|ported repros keyed `SS-<ID>`, plus `SS-S3`, `SS-S4`|
|`test/e2e_test.dart`|create|`e2e()` harness + fixture cases|
|`test/dotsan_cli_test.dart`|modify|`SS-B10`, `SS-B11`, `SS-M4`, `SS-G1`, `SS-G3`, `SS-S1`, version pin; edits at :62, :81-86|
|`test/sanitizer_test.dart`|modify|edits at :829, :1031; delete :1073-1082|
|`pubspec.yaml`|modify|`package_config`, `frontend_server_client`; drop `homepage`, `documentation`; field order; `version: 0.10.0`|
|`analysis_options.yaml`|modify|fleet content|
|`.pubignore`|delete|—|
|`.github/workflows/ci.yaml`|modify|golden Dart variant + `schedule` + windows leg|
|`.github/dependabot.yml`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/{bug_report.yaml,feature_request.yaml,config.yml}`, `CONTRIBUTING.md`|create|fleet content|
|`.github/workflows/publish.yaml`|create (restore)|deleted tag-publish workflow, tag trigger commented out|
|`skills/dart-shorthand-sanitizer/SKILL.md` → `skills/shorthand-sanitizer-dotsan/SKILL.md`|move + modify|`name:`, H1, body|
|`README.md`, `CHANGELOG.md`, `example/example.md`|modify|per phase|
|`/Users/mehmetesen/pub-dev/SWEEP.md`|modify|append to `## Deferred`|
|`plans/sweep-fixes.md`|delete|last commit|

## Phases

How every phase runs:
- Write the phase's failing-first tests and run them; they must go red for the stated reason.
- Make the change and run the oracle.
- Add the CHANGELOG bullets.
- Commit through the `git-committer` agent with conventional commits.

Sources to port:
- Repro tests: `/Users/mehmetesen/pub-dev/sweep-2026-10-03/repros/shorthand_sanitizer/sweep_test.dart`.
- Fixture files: `…/repros/shorthand_sanitizer/fixtures/<case>/` (copy contents verbatim).
- Never run its `run_case.sh`, which hardcodes scratch paths; `test/e2e_test.dart` replaces it.

Out of scope (deferred): SS-S5, SS-G4, SS-G5, SS-G6, SS-G7. X-9 is handled by restoring `publish.yaml` with its tag trigger commented out (Phase 7); X-15 cleanup was done by the maintainer.

### Phase 1: Diagnostic oracle (SS-M1, SS-B3, SS-B6, SS-I2)

- **Files**: `lib/src/sanitizer.dart`, `test/regression_test.dart`, `test/e2e_test.dart`, `README.md`, `CHANGELOG.md`.
- **Failing-first**:
  - `test/regression_test.dart`: copy the repro harness (`makePackage`, `write`, `sanitize`, `analyze`, `geoLibrary`, shared `pkg` with `lib/geo.dart`) and the tests `SS-B3` and `SS-B6` verbatim.
  - `test/e2e_test.dart`: helper `void e2e(String name, Map<String, String> files, {int? converted})` registers `test('e2e $name', …, timeout: const Timeout(Duration(minutes: 3)))`. Each test:
    1. Writes the files into `Directory.systemTemp.createTempSync('dotsan_e2e_')`, deleted in `addTearDown`. A `.keep` file becomes an empty dir.
    2. Runs `dart pub get --offline`, falling back to `dart pub get`.
    3. Records the diagnostics: lines of `dart analyze --format=machine .` that contain `|`, keyed by fields 0, 2, 3 and 7.
    4. Records stdout, stderr and exit code of `dart run bin/main.dart` when it exists.
    5. Runs `r = await Sanitizer().run([existing of lib, bin])` and takes both probes again.
    6. Asserts:
       - the after-multiset minus the before-multiset is empty (print the surplus);
       - the run output is unchanged;
       - `r.convertedCount == converted` when given.
  - E2E cases are `const` maps of raw strings. Add now:
    - `battery` (`converted: 69`, measured on 0.9.0);
    - `masked_error`;
    - `deprecated_alias` (includes `geo_pkg/`);
    - `neg_zero_alias`, `doc_ref_import`, `unused_import_error`.
  - Must be red: SS-B3, SS-B6, e2e `masked_error`, e2e `deprecated_alias`.
- **Change** (`lib/src/sanitizer.dart`):
  - Diagnostic keys:
    - Add `typedef _DiagKey = ({String path, String severity, String code, String message});`, built from `d.severity.name` (analyzer `enum Severity {error, warning, info}`), `d.diagnosticCode.lowerCaseName` and `d.message`.
    - Add `Map<_DiagKey, int> _census(ResolvedLibraryResult lib)` over `lib.units`.
    - Delete `_errorKey`/`_errorKeys`/`_importIssueKeys` (888-910); keep `_isRemovableImport`.
  - `_sanitizeFile` (306-313):
    - Resolve with `getResolvedLibraryContaining(file)`.
    - Set `original = library.unitWithPath(file)`; if either is missing, return null.
    - The floor check reads `library.element.languageVersion`.
    - Pass `required final ResolvedLibraryResult library` to `_FileSanitizer`.
    - `final Map<_DiagKey, int> baseline = _census(library);` replaces 433-437.
  - `_attempt` (631) resolves the library too. `_Attempt` carries `library`, the edited `unit` and `String? stray` (renamed from `strayError`).
  - `Diagnostic? _firstNew(ResolvedLibraryResult lib, bool Function(String path, Diagnostic d) excused)`:
    - walk the edited unit first, then the other units in `lib.units` order, each by offset;
    - count non-excused diagnostics per key;
    - return the first whose running count exceeds `baseline[key] ?? 0`.
  - `_verdict` (688-694):
    - excuse a diagnostic when `path == file && _isRemovableImport(d)`;
    - `stray` = `'<an error|a warning|an info>: ${_sentence(d.message)}'`.
    - Reasons at 559-561 then read `introduces an error: …`, `introduces a warning: …` or `introduces an info: …`.
  - `_orphanRanges` (916-936): an import diagnostic counts as new when its running per-key count exceeds `baseline`.
  - README:108 →
    > `3. Keeps a rewrite **only** if the shorthand resolves to the same element with the same static type (or to a const alias / redirecting forwarder in a slot typed exactly as it), and the file's library gains **no analyzer diagnostic of any severity** (a multiset of severity, code and message; lint rules don't run).`
- **Traps**:
  - A part's own unit result never shows its library's `UNUSED_IMPORT`. The library-wide census now turns a SS-B5 orphan into a refusal; leave SS-B5 unported until Phase 4.
  - `Diagnostic.severity` is the code's default (`errors:` overrides are not applied); both sides use it.
  - Lints are off (251-255).
- **CHANGELOG**: insert `## Unreleased` above `# 0.9.0`. Under `### Fixed`: "Verification compares the whole library's diagnostics as a multiset across errors, warnings and infos. A duplicate of an existing error, or a new deprecation info, now keeps the site prefixed."
- **Oracle**: `dart analyze --fatal-infos --fatal-warnings && dart test`

### Phase 2: Element and static-type identity (SS-B1, SS-B2, SS-M2, SS-I5)

- **Files**: `lib/src/sanitizer.dart`, `test/regression_test.dart`, `test/e2e_test.dart`, `test/sanitizer_test.dart`, `CHANGELOG.md`.
- **Failing-first**: port `SS-B1` and both `SS-B2` tests. Add e2e `typedef_fixed_args` and `static_type_widen`; their runtime diff is the oracle.
- **Change**:
  - `Candidate` (57-92) gains `final String? staticType` and `final String? typedSlot`. `_CandidateCollector._add` (1040-1054) sets `node.staticType?.getDisplayString()` and `_viability.typedSlotOf(node)`.
  - `_ResolvedShorthand` gains named `final String? staticType`. `_ShorthandIndex._add` (954) takes `DartType? type`, and the visitors at 988-1010 pass `node.staticType`.
  - `_Viability.typedSlotOf(Expression site) → String?`:
    - Climb while `_isTransparent(parent, head)` holds.
    - Accept only if `head.parent` is `ArgumentList | VariableDeclaration | ReturnStatement | ExpressionFunctionBody | ListLiteral | SetOrMapLiteral | MapLiteralEntry | FormalParameterDefaultClause` and `_contextOf(head)` is an `InterfaceType`.
    - Return its `getDisplayString()` with one trailing `?` removed; otherwise null.
  - `static bool _isTransparent(AstNode parent, AstNode child)` returns true for:
    - `ParenthesizedExpression`, `NamedArgument` and `ForElement`;
    - the then or else branch of a `ConditionalExpression`;
    - the expression of a `SwitchExpressionCase`;
    - a `SwitchExpression`, unless the child is its scrutinee;
    - the then or else element of an `IfElement`.
  - `_verdict` (678-685) becomes:
```dart
      } else if (resolved.matches(candidate)) {
        if (resolved.staticType != candidate.staticType) {
          culprits.add(candidate);
          _why[candidate] = 'changes the static type from '
              '${candidate.staticType} to ${resolved.staticType}';
        }
      } else {
        final target = [?resolved.containerName, resolved.memberName].join('.');
        final licensed = resolved.forwardsTo(candidate) ||
            await _isConstAlias(candidate, resolved, selfUri);
        final inSlot = candidate.typedSlot != null &&
            candidate.typedSlot == resolved.staticType;
        if (!licensed || !inSlot) {
          culprits.add(candidate);
          _why[candidate] = licensed
              ? 'rebinds to $target outside a typed slot'
              : 'rebinds to $target';
        }
      }
```
  - SS-I5: replace the last two sentences of the 846-855 dartdoc with: "Its static type is the factory's class; `_verdict` accepts that only where `Candidate.typedSlot` is exactly that type, so no cascade, assignment or inference observes it."
  - `test/sanitizer_test.dart:1031` → `'34: Box.all kept: rebinds to Geo.all outside a typed slot',`
- **Traps**:
  - Compare display strings, never `DartType` objects from two different resolves.
  - An alias whose display differs gets refused; that is acceptable.
  - Leave `_passesContextTo` (1229-1250) alone: that pre-check is only a necessary condition.
  - A switch scrutinee is observed by its patterns, so it must not climb.
  - Nullable slots must keep converting. Measured: `.all(1)` in a `Geo?` slot types as `Geo`.
  - e2e `battery` stays at 69. It may drop only if the refused site is a typedef-with-type-arguments site or a licensed rebind outside a typed slot; then re-pin it and log in § Found. Any other drop is a bug to fix.
- **CHANGELOG** `### Fixed`: SS-B1 and SS-B2, noting that these sites now stay prefixed.
- **Oracle**: `dart analyze --fatal-infos --fatal-warnings && dart test`

### Phase 3: Language-version gate (SS-B4, SS-M8, SS-I4)

- **Files**: `lib/src/sanitizer.dart`, `bin/dotsan.dart`, `pubspec.yaml`, `test/regression_test.dart`, `test/sanitizer_test.dart`, `test/dotsan_cli_test.dart`, `README.md`, `CHANGELOG.md`.
- **Failing-first**:
  - Port `SS-B4`, replacing its last line with `expect(result.skippedUnconfigured, {p.normalize(p.absolute(old.path)): 1});`.
  - Add `SS-B4 a nested example without its own package config is skipped`:
    1. `makePackage('outer', 'name: outer\nenvironment:\n  sdk: ^3.10.0\n')`.
    2. Write `example/pubspec.yaml` (`name: ex`, `sdk: ^3.9.0`, path dependency on `..`) and `example/lib/main.dart` (the repro's `Fit`/`take` source).
    3. Run `dart pub get` in `outer`, then delete `example/.dart_tool` and `example/pubspec.lock`.
    4. `Sanitizer().run([outer.path])` must leave `example/lib/main.dart` unchanged and record the example dir in `skippedUnconfigured`.
- **Change**:
  - Add `package_config: '>=2.2.0 <4.0.0'` under `dependencies:`.
  - Add `String _canonical(String path) => p.normalize(p.absolute(path));`. It replaces `p.canonicalize` at 245, 264 and 367, and in `test/dotsan_cli_test.dart:62`.
  - `SanitizeResult` fields:
    - `final Map<({String root, String version}), int> skippedBelowFloor = {};`
    - `final Map<String, int> skippedUnconfigured = {};` with dartdoc: "no entry in the package config the analyzer used; run `dart pub get` in `root`".
  - New `final class _PackageGate()`, one per `run()`, with memoised lookups:
    - `String? rootOf(String file)`: the nearest ancestor directory that holds `pubspec.yaml`.
    - `Future<bool> isConfigured(AnalysisContext c, String file, String root)`: false when `c.contextRoot.packagesFile` is null or `loadPackageConfig` throws (`on Exception`). Otherwise: `final pkg = config.packageOf(Uri.file(file)); return pkg != null && _canonical(p.fromUri(pkg.root)) == root;`
  - `_sanitizeFile`, before resolving: if `root != null` and the package is not configured, bump `skippedUnconfigured[root]` and return null. The floor key becomes `(root: root ?? p.dirname(file), version: 'M.m')`.
  - CLI:
    - Add `String _display(String path)` (rule in § Decisions).
    - Warnings at 118-125, one per entry:
      - `warning: skipped N file(s) in <root> at language version X.Y — dot shorthands need 3.10. Raise \`environment: sdk:\` in <root>/pubspec.yaml (or drop a \`// @dart=\` override); the installed SDK does not decide this.`
      - `warning: skipped N file(s) in <root>: no package config entry — run \`dart pub get\` there first.`
  - Test edits:
    - `test/sanitizer_test.dart:829` expects `{(root: p.normalize(p.absolute(old.path)), version: '3.9'): 1}`.
    - `test/dotsan_cli_test.dart:81-86` expects the new text, with `<root>` = `p.normalize(p.absolute(pkg.path))`.
  - README:163 → "Target packages need language version ≥ **3.10**; packages below it, or with no package config (run `dart pub get`), are skipped with a warning naming the package."
- **Traps**:
  - `dart pub get` at the root also resolves `example/`; that is why the test deletes the example's `.dart_tool` and lock.
  - Without its own config, `example/` joins the root context, and the root config attributes it to the root package at 3.10 (measured). "A config exists" is therefore not enough: compare the package root with the nearest pubspec directory.
  - A file with no pubspec ancestor keeps today's behaviour.
- **CHANGELOG**: `### Fixed` SS-B4; `### Changed` warnings now name the package (SS-M8); `### Breaking` the `skippedBelowFloor` key.
- **Oracle**: `dart analyze --fatal-infos --fatal-warnings && dart test`

### Phase 4: Library-scoped pruning and write ordering (SS-B5, SS-M3, SS-S4, SS-M5)

SS-M5 here covers only its write-ordering half; the dispose half is deferred with SS-S5.

- **Files**: `lib/src/sanitizer.dart`, `test/regression_test.dart`, `test/e2e_test.dart`, `CHANGELOG.md`.
- **Failing-first**:
  - Port `SS-B5`.
  - Add `SS-S4 a library sees its part's earlier write`. In `pkg`, write:
    - `lib/s4_fit.dart`: `enum Fit { cover, contain }`
    - `lib/s4_sink.dart`: imports it; `void take(Fit f) {}`
    - `lib/a_s4_part.dart`: `part of 'z_s4_lib.dart';` then `void run() => take(Fit.cover);`
    - `lib/z_s4_lib.dart`: imports fit and sink; `part 'a_s4_part.dart';`; `void own() => take(Fit.contain);`
    - Run `Sanitizer().run([part, lib])`. Both files must convert, and `analyze(pkg, 'z_s4_lib.dart')` must not contain `UNUSED_IMPORT`.
  - Add e2e case `part_orphan` (root `lib`).
- **Change** (`_FileSanitizer`):
  - Add `final _overlaid = <String>{}` and `_overlay(path, text)`: `setOverlay` with `++_stamp`, add the path to `_overlaid`, then `context.changeFile(path)`. `_attempt` uses it.
  - `_orphanCuts` becomes a `Map<String, List<(int, int)>>` keyed by unit path. `_orphanRanges(ResolvedLibraryResult check, baseline)` scans every unit, using each unit's `check` content as coordinates. `_verdict` excuses `_isRemovableImport(d)` in any unit.
  - Add `Future<Map<String, String>?> _finalize()`:
    - `_clean == null` → null.
    - No cuts → `{file: clean.text}`.
    - Otherwise:
      1. Strip the cuts from `clean.text` and from each other cut unit's `library.unitWithPath(path)` content.
      2. Overlay all of them, `applyPendingFileChanges`, and resolve the library.
      3. If `_firstNew(check, (_, _) => false)` returns a diagnostic, set `_why[c] = 'pruning its orphaned imports leaves <stray>'` for each `_active` candidate, set `_active = []` and return null.
      4. Otherwise return the texts.
  - `run()` (454-475):
    - `try`: converge, recover, `texts = await _finalize()`, then `if (texts != null && !dryRun) texts.forEach(_write)`, where `_write(path, text) => File(path).writeAsStringSync(text)`.
    - `finally`: for each path in `_overlaid`, `removeOverlay` then `changeFile`; then `await context.applyPendingFileChanges()`.
    - Converted = `texts == null ? [] : _active`; `removedImports` = the total number of cuts.
- **Traps**:
  - Write before removing overlays (SS-S4). Today 461-463 run before 469-474, so the analyzer re-reads the pre-write disk and later files are judged on stale text.
  - Dry runs write nothing.
  - `_finalize` resolves an extra time only when there are cuts.
- **CHANGELOG** `### Fixed`: SS-B5, SS-S4.
- **Oracle**: `dart analyze --fatal-infos --fatal-warnings && dart test`

### Phase 5: Engine and CLI hygiene (SS-B7, SS-B8, SS-B9, SS-M4, SS-B10, SS-B11, SS-S3, SS-I1, SS-I7, SS-I8, SS-M9)

- **Files**: `lib/src/sanitizer.dart`, `lib/shorthand_sanitizer.dart`, `bin/dotsan.dart`, the three test files, `README.md`, `CHANGELOG.md`.
- **Failing-first** in `regression_test.dart`:
  - Port `SS-B7` and add a third case: 40 lines of `// Licensed under the Apache License, Version 2.0.\n` (over 1024 bytes), then `// GENERATED CODE - DO NOT MODIFY BY HAND\n`.
  - Port `SS-B8` with `\r\n` line endings, and also assert that `\r\n` survives.
  - Port `SS-B9` and `SS-I1`.
  - Add `SS-S3`. Source: `enum Fit { cover }\nvoid t(Fit f) {}\nvoid r() => t(Fit.cover);\nint bad = '';\n`.
    - By default the file stays unchanged and `skippedWithErrors == [path]`.
    - With `allowErrors: true` it converts.
  - Give `SS-B3` `allowErrors: true` through a new `sanitize(…, {bool allowErrors = false})` parameter. Otherwise it passes by being skipped and stops testing the multiset.
- **Failing-first** in `dotsan_cli_test.dart`:
  - Port `SS-B10` and `SS-B11`; both assert exit code 64.
  - Add `SS-M4`:
    - use a fixture like the `--explain` test's;
    - run `Process.runSync(Platform.resolvedExecutable, ['--packages=${p.absolute('.dart_tool/package_config.json')}', p.absolute('bin/dotsan.dart'), '-n', 'lib'], workingDirectory: fixture)`;
    - stdout must start with `'${p.join('lib', 'main.dart')}\n'`.
  - Replace `sanitizer_test.dart:1073-1082` with `--version prints the pubspec version`: stdout of `dart run bin/dotsan.dart --version` == `'dotsan <pubspec version>\n'`.
- **Change**:
  - SS-B7 `isGenerated` (213-230):
    - Read the whole file with `utf8.decode(…, allowMalformed: true)` and drop a leading `\uFEFF`.
    - Scan lines until the first one that is not blank, not `//`/`#`, and not inside or opening a `/* … */` block. Track `inBlock`; a `*/` closes it.
    - Match `_generatedMarker` on every comment line.
  - SS-B8 `_write`: if the file on disk starts with `EF BB BF`, write `'\uFEFF$text'`.
  - SS-B9 `_collectFiles` returns canonical, de-duplicated, then sorted paths. `includedPaths` (245) drops any root that `p.isWithin` another.
  - SS-S3:
    - `Sanitizer({…, final bool allowErrors = false})` and `SanitizeResult.skippedWithErrors` (`List<String>`).
    - In `_sanitizeFile`, after the floor check: if `!allowErrors` and any unit has a `Severity.error`, record the path and return null.
  - SS-I1 (329): also skip when `'${c.containerName}.${c.memberName}'` matches.
  - SS-I7: the `excludes` dartdoc (176-178) says each glob is matched against both the CWD-relative path (`/` separators) and the basename.
  - SS-I8: the README `--exclude` bullet adds "`analyzer: exclude:` in analysis_options.yaml is not honoured — repeat those globs here."
  - SS-M9: drop `Candidate` from the `show` list.
  - CLI:
    - `addFlag('allow-errors', negatable: false, help: 'Also rewrite files whose library already has analysis errors.')`
    - Check each `opts.rest` path with `FileSystemEntity.typeSync`:
      - not found → `no such file or directory: <p>`;
      - a file not ending in `.dart` → `not a .dart file: <p>`;
      - print every message, then `exitCode = 64; return;`.
    - Pre-parse each exclude with `Glob(e)`; `on FormatException catch (e)` → `invalid --exclude glob "<e>": ${e.message}`, exit 64.
    - File lines use `_display` (SS-M4).
    - SS-S3 warning: `warning: skipped N file(s) whose library already has analysis errors (fix them or pass --allow-errors):`, then one `  <path>` line per file.
- **Traps**:
  - De-duplicate before the context loop (264).
  - The analyzer's `content` has no BOM, so offsets stay valid.
  - Default roots are already filtered for existence (88).
- **CHANGELOG**:
  - Fixed: SS-B7–SS-B11.
  - Changed: SS-S3 (skipped by default), SS-I1, SS-M4.
  - Added: `--allow-errors`.
  - Breaking: SS-M9.
- **Oracle**: `dart analyze --fatal-infos --fatal-warnings && dart test`

### Phase 6: `--set-exit-if-changed` and `--format=json` (SS-G1, SS-G3)

- **Files**: `lib/src/sanitizer.dart`, `lib/shorthand_sanitizer.dart`, `bin/dotsan.dart`, `test/dotsan_cli_test.dart`, `CHANGELOG.md`.
- **Failing-first** (fresh `^3.10.0` fixture with the `--explain` test's source):
  - `SS-G1`:
    - `-n --set-exit-if-changed` exits 1 and leaves the file unchanged;
    - the same command on `pkg` (nothing converts) exits 0;
    - without `-n` it exits 1 and the file is rewritten.
  - `SS-G3`: `-n --explain --format=json` leaves stderr empty, and `jsonDecode(stdout)` equals:
```dart
{'dryRun': true, 'converted': 1, 'kept': 1, 'skipListed': 0, 'removedImports': 0,
 'files': [{'path': p.normalize(p.absolute(file.path)), 'removedImports': 0, 'sites': [
   {'line': 3, 'column': 19, 'before': 'Fit.contain', 'after': null, 'keptReason': 'no context type'},
   {'line': 4, 'column': 11, 'before': 'Fit.cover', 'after': '.cover', 'keptReason': null}]}]}
```
- **Change**:
  - New public `final class Site({required final int line, required final int column, required final String before, final String? after, final String? keptReason})`, exported.
    - Dartdoc: `line`/`column` are the 1-based position of the `Type` prefix; `after` is `.member` when converted; `keptReason` is set when kept.
  - `FileResult(path, List<Site> sites, reverted, {removedImports = 0})`:
    - sites are sorted by line, then column;
    - getters `converted` (`'$line: $before -> $after'`) and `kept` (`'$line: $before kept: $keptReason'`) reproduce the old strings exactly.
  - 479-499 and `_keptLines` (798-801) build `Site`s from `original.lineInfo.getLocation(offset)`.
  - CLI:
    - `addFlag('set-exit-if-changed', negatable: false, help: 'Exit 1 if any site was converted (or, with --dry-run, would be).')`
    - `addOption('format', allowed: ['text', 'json'], defaultsTo: 'text', help: 'Report format on stdout.')`
    - The spinner runs only when the format is text and stdout is a terminal.
    - JSON mode prints `const JsonEncoder.withIndent('  ').convert(_json(result, dryRun))` in place of the report and summary; stderr is unchanged.
    - At the end: if the flag is set and `result.convertedCount > 0`, `exitCode = 1`.
  - JSON schema (copy it into the README):
    - Top level:
      - `dryRun` (bool);
      - `files` (array, in report order);
      - `converted` (int);
      - `kept` (int: explained kept sites, 0 without `--explain`);
      - `skipListed` (int);
      - `removedImports` (int).
    - Each file: `path` (display rule), `removedImports`, `sites`.
    - Each site:
      - `line` and `column` (1-based);
      - `before` (`Type.member` as written);
      - `after` (`.member` or null);
      - `keptReason` (string or null).
    - Kept sites are listed only with `--explain`.
- **Traps**:
  - Stdout must be pure JSON, even on a TTY.
  - `exit()` can truncate a large document; set `exitCode` instead.
- **CHANGELOG**: Added SS-G1, SS-G3 and `Site`; Breaking `FileResult` constructor.
- **Oracle**: `dart analyze --fatal-infos --fatal-warnings && dart test`

### Phase 7: CI, dependency safety net, Windows SDK discovery (SS-S1, SS-S2, SS-M6, SS-M7, SS-I9, X-10, X-12)

- **Files**: `lib/src/sanitizer.dart`, `bin/dotsan.dart`, `test/dotsan_cli_test.dart`, `pubspec.yaml`, `.github/workflows/ci.yaml`, `.github/dependabot.yml`, `CHANGELOG.md`.
- **Failing-first**: add `SS-S1 an AOT build finds the SDK on PATH without DART_SDK` (timeout 5 min).
  1. Compile with `Platform.resolvedExecutable compile exe bin/dotsan.dart -o <tmp>/dotsan` (add `.exe` on Windows).
  2. Run the binary with `-n <fresh ^3.10.0 fixture>/lib`, `environment: {...Platform.environment}..remove('DART_SDK')` and `includeParentEnvironment: false`.
  3. Expect exit 0, stdout ending in `would convert 1 site(s) in 1 file(s)\n`, and no `Exception` in stderr.
  - It passes locally (the `which` path); only the Windows leg goes red before the fix, and Phase 9 checks it.
- **Change**:
  - `sdkPath` (47-48) → `String? _dartOnPath()`:
    - `Process.runSync(Platform.isWindows ? 'where' : 'which', ['dart'])` inside `try … on ProcessException { return null; }`;
    - use the first non-empty trimmed stdout line (`where` can list several, with CRLF endings).
  - CLI: before `Sanitizer(...)`, if `sdkPath() == null`, print `could not locate the Dart SDK: set DART_SDK to its directory` to stderr and `exitCode = 69; return;`.
  - Add `frontend_server_client: ^4.0.0` under `dev_dependencies:`. Without it, `dart pub downgrade` picks 3.2.0, whose snapshot SDK 3.13 lacks, and no test loads (SS-M7).
  - `.github/workflows/ci.yaml` (whole file; `schedule:` covers SS-S2, the floor and downgrade legs cover SS-M6/SS-I9, the windows leg covers SS-S1):
```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: '23 5 * * 1'
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  format:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - uses: dart-lang/setup-dart@v1
      - run: git ls-files -z -- '*.dart' | xargs -0 dart format --output=none --set-exit-if-changed
  analyze:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7
      - uses: dart-lang/setup-dart@v1
      - run: dart pub get
      - run: dart analyze --fatal-infos --fatal-warnings
  test:
    name: test (${{ matrix.name }})
    runs-on: ${{ matrix.os }}
    timeout-minutes: 20
    strategy:
      fail-fast: false
      matrix:
        include:
          - { name: floor, os: ubuntu-latest, sdk: '3.13.0' }
          - { name: stable, os: ubuntu-latest, sdk: stable }
          - { name: beta, os: ubuntu-latest, sdk: beta }
          - { name: windows, os: windows-latest, sdk: stable }
    steps:
      - uses: actions/checkout@v7
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: ${{ matrix.sdk }}
      - run: dart pub get
      - run: dart test
  downgrade:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v7
      - uses: dart-lang/setup-dart@v1
      - run: dart pub downgrade
      - run: dart analyze --fatal-warnings
      - run: dart test
  pana:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7
      - uses: dart-lang/setup-dart@v1
      - run: dart pub global activate pana
      - run: dart pub global run pana --no-warning --exit-code-threshold 0
  publish-dry-run:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - uses: dart-lang/setup-dart@v1
      - run: dart pub publish --dry-run
```
  - `.github/dependabot.yml` (no `/example` entry, because `example/` has no pubspec):
```yaml
version: 2
updates:
  - package-ecosystem: pub
    directory: /
    schedule:
      interval: weekly
    open-pull-requests-limit: 5
    labels: [dependencies]
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    labels: [dependencies, ci]
```
  - Restore `.github/workflows/publish.yaml` (deleted in commit `951159a`) with its tag trigger commented out — automated publishing stays configured on pub.dev for later; `workflow_dispatch` keeps it a valid workflow and a manual run cannot publish (pub.dev requires a tag push; `verify` also fails off a tag):
```yaml
name: Publish

on:
  # Automated publishing is paused; pub.dev Admin → Automated publishing stays enabled.
  # Re-enable by uncommenting the tag trigger below. pub.dev rejects publishes not started
  # by a tag push, so a manual workflow_dispatch run cannot publish.
  # push:
  #   tags:
  #     - 'v[0-9]+.[0-9]+.[0-9]+*'
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  verify:
    name: Verify tag matches pubspec
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check tag matches pubspec version
        run: |
          TAG="${GITHUB_REF#refs/tags/v}"
          PUBSPEC=$(grep '^version:' pubspec.yaml | awk '{print $2}')
          if [ "$TAG" != "$PUBSPEC" ]; then
            echo "::error::Tag v$TAG does not match pubspec.yaml version $PUBSPEC"
            exit 1
          fi

  publish:
    name: Publish to pub.dev
    needs: verify
    runs-on: ubuntu-latest
    environment: pub.dev
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - name: Check pub.dev for this version
        id: pub
        run: |
          V=$(grep '^version:' pubspec.yaml | awk '{print $2}')
          if curl -fsS "https://pub.dev/api/packages/shorthand_sanitizer/versions/$V" >/dev/null; then
            echo "::notice::$V already on pub.dev — nothing to publish"
            echo "exists=true" >> "$GITHUB_OUTPUT"
          else
            echo "exists=false" >> "$GITHUB_OUTPUT"
          fi
      - if: steps.pub.outputs.exists == 'false'
        run: dart pub get
      - if: steps.pub.outputs.exists == 'false'
        run: dart pub publish --force
```
- **Traps**:
  - `with: { sdk: ${{ matrix.sdk }} }` is invalid YAML (braces inside a flow mapping); keep the block form.
  - If pana fails *after* printing 160/160 with `PathNotFoundException`, add `continue-on-error: true` to that job only and log it in § Found.
  - No Codecov and no `--coverage`.
  - The downgrade resolves analyzer 14.0.0 and package_config 2.2.0; every API used here exists in both (checked).
- **CHANGELOG** `### Fixed`: SS-S1 (Windows SDK discovery; exit 69 when no SDK is found).
- **Oracle**: `yq -e '(.on | has("workflow_dispatch")) and (.on | has("push") | not)' .github/workflows/publish.yaml && dart analyze --fatal-infos --fatal-warnings && dart test && (dart pub downgrade && dart analyze --fatal-warnings && dart test); s=$?; dart pub upgrade >/dev/null; [ $s -eq 0 ]`

### Phase 8: Docs, skill, repo meta, packaging (SS-P1, SS-I3, SS-I6, SS-G2, X-1, X-2, X-5, X-11, X-16, X-17, X-18, X-19)

SS-G2 here covers only the README positioning; its plugin half is deferred.

- **Files**: `pubspec.yaml`, `analysis_options.yaml`, `.pubignore`, `skills/…`, `README.md`, `example/example.md`, `CONTRIBUTING.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/*`, `CHANGELOG.md`.
- **Change**:
  - `pubspec.yaml`:
    - Field order: `name, description, version, repository, issue_tracker, topics, executables, environment, dependencies, dev_dependencies`.
    - Delete `homepage:` (X-1) and `documentation:` (X-18).
    - Keep the description (168 chars).
  - `analysis_options.yaml` (X-17; very_good_analysis 11 already sets the dropped strict-* modes; `rg -n 'unawaited\('` must stay empty):
```yaml
include: package:very_good_analysis/analysis_options.yaml

analyzer:
  exclude:
    - build/**

linter:
  rules:
    # Maintainer convention: fire-and-forget is a bare drop; never unawaited().
    unawaited_futures: false
    discarded_futures: false
```
  - `git rm .pubignore` (SS-P1, X-16).
  - Skill (X-11, SS-I6):
    - `git mv skills/dart-shorthand-sanitizer skills/shorthand-sanitizer-dotsan`.
    - Frontmatter `name: shorthand-sanitizer-dotsan` and `license: MIT`; H1 `# shorthand-sanitizer-dotsan`.
    - Add the command lines `dotsan lib -n --set-exit-if-changed   # CI gate` and `dotsan lib -n --format=json   # machine-readable`.
    - Line 19 → `Missing binary → \`dart install shorthand_sanitizer\`.`
    - Line 23: "no new diagnostics" → "no new analyzer diagnostic of any severity".
    - Line 25 → "Two rebinds are licensed, only in a slot typed exactly as the rebind (argument, typed declaration, return, collection element): a `static const` alias (`Alignment.topCenter`) and a parameter-preserving redirecting factory (`EdgeInsets.all` in `padding:`). Typedefs with type arguments (`typedef IntG = G<int>`) and cascade targets stay prefixed."
    - `rg -n 'dart-shorthand-sanitizer'` must print nothing.
  - README:
    - Lines 3-4 become one badge row (X-5):
      `[![pub package](https://img.shields.io/pub/v/shorthand_sanitizer.svg)](https://pub.dev/packages/shorthand_sanitizer) [![pub points](https://img.shields.io/pub/points/shorthand_sanitizer)](https://pub.dev/packages/shorthand_sanitizer/score) [![CI](https://github.com/esenmx/shorthand_sanitizer/actions/workflows/ci.yaml/badge.svg)](https://github.com/esenmx/shorthand_sanitizer/actions/workflows/ci.yaml) [![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)`
    - Line 6 (SS-I3, SS-G2) → "Rewrites `Type.member` to [dot shorthand](https://dart.dev/language/dot-shorthands) `.member` across a whole Dart or Flutter project, checking every site by re-resolving it, then prunes the imports the dropped prefixes orphaned. Dart's IDE assist *Convert to dot shorthand* does one site at a time; dotsan does the project in one verified run. Rewrites packages at language version 3.10+; dotsan itself needs Dart 3.13+."
    - Lines 32-54 become `## Install`:
      - the `dart install shorthand_sanitizer` block;
      - the PATH sentence from line 42;
      - "Alternative: `dart pub global activate shorthand_sanitizer`."
      - Drop line 44; the 0.8.1 CHANGELOG entry keeps that note.
    - Usage (lines 72-98):
      - add examples and bullets for `--set-exit-if-changed`, `--format=json` and `--allow-errors`;
      - add the exit codes (§ Decisions) and the Phase 6 JSON schema;
      - the `--skip` bullet adds "`Type` is the declaring type or the spelling at the site (`m.Fit.cover`, a typedef)".
    - Table rows 119-120 add "… in a slot of exactly that type".
    - The block at 126-141 adds `final G<num> g = IntG.of(1); // typedef IntG = G<int> fixes the type argument` and `final Geo a = Box.all(1)..log(); // the cascade observes the rebind's type`.
    - Line 164 → "Runs on macOS, Linux and Windows (all three in CI)."
    - Append `## Agent skill` (block below), `## Contributing` (links `CONTRIBUTING.md`; no `SECURITY.md` — the maintainer accepts no private vulnerability reports) and `## License` ("MIT — see [LICENSE](LICENSE).") (X-19).
  - `example/example.md:2` → `dart install shorthand_sanitizer`.
  - New files, verbatim:
~~~markdown
<!-- README.md — appended section -->
## Agent skill

This package ships an agent skill in `skills/shorthand-sanitizer-dotsan/`. Install it into your project's agent config with:

```sh
dart run skills@ get --package shorthand_sanitizer --all
```

<!-- CONTRIBUTING.md -->
# Contributing

1. `dart pub get`
2. Run what CI runs:
   - `git ls-files -z -- '*.dart' | xargs -0 dart format --output=none --set-exit-if-changed`
   - `dart analyze --fatal-infos --fatal-warnings`
   - `dart test`
   - `dart pub publish --dry-run`
3. Add a line under `## Unreleased` in `CHANGELOG.md` for every user-visible change.

Releases are published manually by the maintainer.

<!-- .github/PULL_REQUEST_TEMPLATE.md -->
## Summary

## Checklist

- [ ] Tests added or updated
- [ ] `CHANGELOG.md` `## Unreleased` entry
- [ ] Docs / README / skill updated if public API changed
~~~
```yaml
# .github/ISSUE_TEMPLATE/bug_report.yaml
name: Bug report
description: Something is broken in shorthand_sanitizer
title: "[bug] "
labels: [bug]
body:
  - type: textarea
    id: what-happened
    attributes:
      label: What happened?
      description: A clear, concise description of the bug.
      placeholder: |
        I ran `dotsan lib` and a converted site no longer compiles.
    validations: { required: true }
  - type: textarea
    id: reproduction
    attributes:
      label: Minimal reproduction
      description: A minimal Dart snippet that reproduces the issue.
      render: dart
      placeholder: |
        // minimal reproduction
    validations: { required: true }
  - type: textarea
    id: expected
    attributes:
      label: Expected behavior
    validations: { required: true }
  - type: input
    id: package-version
    attributes:
      label: shorthand_sanitizer version
      placeholder: 0.10.0
    validations: { required: true }
  - type: textarea
    id: env
    attributes:
      label: Environment
      description: Output of `dart --version`.
      render: shell
    validations: { required: true }
# .github/ISSUE_TEMPLATE/feature_request.yaml
name: Feature request
description: Suggest a new capability or improvement
title: "[feature] "
labels: [enhancement]
body:
  - type: textarea
    id: problem
    attributes:
      label: Problem
      description: What problem are you trying to solve?
    validations: { required: true }
  - type: textarea
    id: proposed
    attributes:
      label: Proposed solution
      description: How would you like this to work?
    validations: { required: true }
  - type: textarea
    id: alternatives
    attributes:
      label: Alternatives considered
    validations: { required: false }
# .github/ISSUE_TEMPLATE/config.yml
blank_issues_enabled: true
```
- **README snippet check**:
  1. `flutter create --empty -t app "$(mktemp -d)/snip"`.
  2. Put each README ```dart block, wrapped in its own function, into `lib/snippets.dart`. Declare only what a block references (`Fit`, `Base`/`Sub`, `G`/`IntG`, `Geo`/`Box`, an extension with `log()`).
  3. `flutter analyze lib/snippets.dart` must report no errors.
- **Traps**:
  - `dart pub publish --dry-run` fails on a dirty tree, so it runs in § Verification after the commit.
  - The `<!-- path -->` and `# path` lines above only label the blocks; they are not file content.
- **CHANGELOG**: `### Changed` skill directory renamed to `shorthand-sanitizer-dotsan` (`dart run skills@ get --package shorthand_sanitizer --all`); `### Removed` `.pubignore`.
- **Oracle** (if `dart run skills@` cannot resolve, log it in § Found and use `ls skills | grep -qx shorthand-sanitizer-dotsan` instead):
```sh
tmp=$(mktemp -d) && cd $tmp && dart create -t console probe && cd probe \
  && dart pub add shorthand_sanitizer --path /Users/mehmetesen/pub-dev/shorthand_sanitizer \
  && dart run skills@ get --package shorthand_sanitizer --agent claude --all 2>&1 | tee $tmp/skills_get.txt \
  && ! grep -q 'Skipping skill' $tmp/skills_get.txt \
  && find . -path '*shorthand-sanitizer-dotsan/SKILL.md' | grep -q .
```

### Phase 9: Release 0.10.0 (X-8)

- **Files**: `pubspec.yaml`, `bin/dotsan.dart`, `CHANGELOG.md`, `/Users/mehmetesen/pub-dev/SWEEP.md`, `plans/sweep-fixes.md`, `README.md` (fallback only).
- **Change**:
  1. Set `version: 0.10.0` in `pubspec.yaml` and `_version = '0.10.0'` at `bin/dotsan.dart:7`; the `--version` test pins them together.
  2. CHANGELOG:
     - prepend `# Changelog`;
     - rename `## Unreleased` → `## 0.10.0 - <date +%F>`;
     - change the H1 headings at lines 1, 9, 13, 23, 31, 35, 39, 49, 54, 60 and 65 from `# x.y.z` to `## x.y.z`;
     - insert `## 0.4.0` + `- Not documented.` between 0.5.0 and 0.3.1.
     - pub.dev lists 0.1.0, 0.2.0, 0.3.0, 0.3.1, 0.4.0, 0.5.0, 0.5.1, 0.6.0, 0.7.0, 0.8.0, 0.8.1 and 0.9.0, so no heading needs "(not published)".
  3. Append the § Out of scope Deferred rows to `## Deferred` in `/Users/mehmetesen/pub-dev/SWEEP.md`.
  4. Run § Verification 1-8, commit through `git-committer`, push, then run the oracle.
  5. Only if `test (windows)` is red:
     - Do up to 2 rounds of `gh run view <id> --log-failed` → fix → commit → push → oracle.
     - If it is still red:
       - delete the windows `include` line;
       - set README Requirements to "macOS and Linux (CI-tested); Windows: SDK discovery fixed in 0.10.0, the suite is not CI-verified there";
       - append `- [SS] SS-S1/SS-I9 — windows-latest leg red: <first failing test> — no local Windows to debug` to Deferred;
       - commit, push, then run the oracle.
     - Any other red job blocks the release: fix it.
  6. Once CI is green: delete `plans/sweep-fixes.md`, commit, push, and run the oracle again.
- **Traps**:
  - An empty `id` means GitHub has not registered the run yet; re-run the oracle.
  - Never `dart pub publish`, never tag, never create a release.
- **Oracle**: `id=$(gh run list -L1 --commit "$(git rev-parse HEAD)" --json databaseId -q '.[0].databaseId'); gh run watch --exit-status "$id"`

## Verification

Preconditions: network access (pub, pana, skills) and an authenticated `gh` (step 9). A step that cannot run is a skip: log it in § Found and keep the plan `in-progress`.

1. `dart pub get`
2. `git ls-files -z -- '*.dart' | xargs -0 dart format --output=none --set-exit-if-changed`
3. `dart analyze --fatal-infos --fatal-warnings`
4. `dart test`
5. `(dart pub downgrade && dart analyze --fatal-warnings && dart test); s=$?; dart pub upgrade >/dev/null; [ $s -eq 0 ]`
6. `dart pub publish --dry-run` (clean tree only, after the commit; exits 65 on any warning)
7. `dart pub global activate pana && dart pub global run pana --no-warning --exit-code-threshold 0`
8. The Phase 8 oracle and the README snippet check.
9. CI green on the pushed HEAD, including the Windows leg (Phase 9 oracle).

## Edge cases

- **Part whose library is missing** (`getResolvedLibraryContaining` returns no library): the file is skipped silently, as today.
- **Pruning would leave a diagnostic**: nothing in that file converts, and every site's kept reason says so.
- **Package config unreadable**: treated as unconfigured (skip and warn).
- **File with no pubspec ancestor**: analyzed at the analyzer's default version (unchanged).
- **Duplicate or nested roots**: each file is processed once, and the analyzer's include list is de-nested.
- **Dry run over a library and its parts**: nothing is written, so later files see the pre-rewrite text.
- **BOM and CRLF**: both are preserved. The BOM is re-prepended on every written unit, the pruned library included.
- **`--format=json` with `--set-exit-if-changed`**: the full JSON goes to stdout, then the exit code is 1.
- **Exception mid-file**: the `finally` block removes overlays, and that file is not written.
- **Idle repo**: GitHub disables the scheduled workflow after 60 idle days; re-enabling it is a user step.

## Out of scope

Deferred rows, appended verbatim in Phase 9:
- `- [SS] SS-S5 — AnalysisContextCollection never disposed (+ SS-M5 dispose half) — RSS flat over 12 in-process runs (~740 MB); no failing-first oracle`
- `- [SS] SS-G2 (plugin half) — analysis_server_plugin lint + fix (prefer_dot_shorthand) reusing the verifier — new package; decide at 1.0 against the SDK assist`
- `- [SS] SS-G4 — // dotsan:ignore comments and a pubspec/dotsan.yaml config block — feature not in sweep scope`
- `- [SS] SS-G5 — --changed / --since=<ref> incremental mode — feature not in sweep scope`
- `- [SS] SS-G6 — honour analyzer: exclude by default — feature not in sweep scope; documented under SS-I8`
- `- [SS] SS-G7 — reverse mode (shorthand → prefixed) — feature not in sweep scope`

Also out of scope: class modifiers, public renames, SARIF output, and the 1.0 API freeze.

User-only steps (the executor never does these): publish the release to pub.dev (pub.dev Admin → Automated publishing stays enabled; the restored `publish.yaml` keeps its tag trigger commented out until you re-enable it). Optional: a DNS record for mehmetesen.com before re-adding `homepage:`.

The executor never runs `dart pub publish`, never creates tags or GitHub releases, and never changes repository settings.

## Found

Tracker: `/Users/mehmetesen/pub-dev/SWEEP.md` § Deferred, one row per item: `- [SS] <ID> — <one line> — <why deferred>`.

- Phase 1: the plan rewords only the bisection reason (559-561). The `_recover` reason keeps its template with the new `stray` text: `not verifiable alongside the other rewrites: an error: …` (likewise `a warning` / `an info`).
- Phase 1: e2e `battery` measured 69 on 0.9.0 code before the change and 69 after; oracle 53/53 tests green.
- Phase 2: SS-I5 "last two sentences" read as the static-type claim after the signature sentence ("The invocation's own static type widens … context type."); the signature sentence stays, since it still holds. e2e `battery` stays at 69; oracle 58/58 green.
- Phase 3: both SS-B4 tests went red first on behaviour (file rewritten below the floor), before `skippedUnconfigured` existed. The `<root>/pubspec.yaml` in the floor warning is `p.join(_display(root), 'pubspec.yaml')`, so native separators. Oracle 60/60 green.
- Phase 4: e2e `part_orphan` passed vacuously before the fix (the part was refused, so nothing changed), so it is pinned at `converted: 1` to go red first (0 vs 1). `_finalize` also refuses when the pruned library no longer resolves, with the reason `pruning its orphaned imports leaves an unresolvable library`. Oracle 63/63 green.
- Phase 5: SS-S3's default skip would have hollowed out e2e `masked_error` (its `lib/use.dart` carries a deliberate error), the same reason the plan gives for SS-B3. `e2e()` gained `{bool allowErrors = false}`, and `masked_error` passes `allowErrors: true`.
- Phase 5: `sanitizer_test.dart` "static method on prefixed-imported class converts" had an accidental error in its fixture (`const p.Scaler ts = p.Scaler.scale(5);`, a static call in a const initializer), so SS-S3 now skipped it. Its fixture and expectation now use `final`; the conversion it pins is unchanged.
- Phase 5: `Glob('[')` throws `SourceSpanFormatException`, a `FormatException`, so `on FormatException` catches it. The `--version prints the pubspec version` pin replaces the old source-regex test; it cannot go red while both read 0.9.0. SS-B7's third case (40 licence lines, then the marker) went red on the 1024-byte head read. e2e `battery` stays at 69. Oracle 71/71 green.
- Phase 6: the `--explain` CLI test now builds its fixture through the shared `explainFixture()` helper that SS-G1/SS-G3 use; its expected output is unchanged. `FileResult` sorts `sites` in a body field initialised from the primary-constructor parameter of the same name, which SDK 3.13.4 accepts. The README JSON schema and exit codes land in Phase 8 (the Phase 6 file list has no README). Oracle 75/75 green.
- Phase 7: SS-S1 passes locally (the `which` path), as the plan expects; its red run belongs to the Windows CI leg in Phase 9. The restored `publish.yaml` differs from `951159a^` only in the commented-out trigger plus `workflow_dispatch`. Oracle green: yq `true`, 76/76 tests on the upgrade resolve, and 76/76 on the downgrade resolve (analyzer 14.0.0, package_config 2.2.0).
- Phase 8: `rg -n 'dart-shorthand-sanitizer'` matches only this plan, which names the old path; outside `plans/` it prints nothing, and the plan goes in Phase 9. `rg -n 'unawaited\('` matches the plan-mandated `analysis_options.yaml` comment ("never unawaited().") and this plan; `rg -n 'unawaited\(' -t dart` prints nothing. very_good_analysis 11.0.0 sets all three strict modes (checked). The `analysis_options.yaml` edit used the session-root marker, removed right after.
- Phase 8: the README `## Install` holds exactly the listed content, so the old line 36 (the AOT startup-time sentence) went with lines 32-54. "in a slot of exactly that type" sits in the table's Kind column. The README snippet check passed: 3 dart blocks, `flutter analyze lib/snippets.dart` reported 0 errors (6 `unused_local_variable` warnings). The skills@ oracle printed `Installed shorthand-sanitizer-dotsan` with no `Skipping skill`.
- Local § Verification on `9b02e36` (no release commit, no push): steps 1-8 passed. Format reported 0 changed; analyze reported no issues; 76/76 tests passed on the upgrade resolve and 76/76 on the downgrade resolve (analyzer 14.0.0, package_config 2.2.0). `dart pub publish --dry-run` reported 0 warnings; the archive still carries `plans/sweep-fixes.md` until Phase 9 deletes it. pana 0.23.19 scored 160/160 with no `PathNotFoundException`. The Phase 8 oracle and the snippet check (0 errors) passed again after the commit. Step 9 (CI, Windows leg included) runs in Phase 9.
- After Phase 8, SS-S3 hardening for the tests. A one-off probe (a print on the skip path, then reverted) over the full suite found only two in-process skips: SS-S3's own fixture (deliberate) and a leftover `page.preview.dart` from the `isGenerated` test, which the traversal test walks past without asserting on it. That proved no fixture was skipped, not that every check was exercised: R2-SS-1 below shows the multiset check had no test. Both `sanitize()` helpers and the e2e harness now `expect(result.skippedWithErrors, isEmpty)`. It goes red on the old `const p.Scaler` fixture (checked) and is green on the suite. Steps 2-4 re-ran green (76/76).
- R-SS-1 overrides Decision SS-B1 ("compared as display strings"); the core-promise Invariant wins. `getDisplayString` drops the library, so two same-named classes compared equal. `_typeKey` names every interface by library URI and name, recursively over type arguments, function and record types, with nullability. It now decides the same-element static type, the typed slot (top-level `?` stripped) and the redirecting-factory signatures. When the two displays match, the kept reason shows the keys. Red first: e2e `display_collision` printed `stored b.X` where it should print `TypeError: G<a.X> rejects b.X`; `SS-R1` converted 1 site where it should convert 0. Suite 78/78 green.
- R-SS-2: analyzer 14.4 skips its `@visibleForTesting` check on a dot-shorthand constructor invocation, so the diagnostic oracle cannot see that rebind. The licensed branch now refuses a target whose use-restricting annotations (`_restrictionsOf`; a field's sit on the field, not on its getter) are not all on the original. Red first: e2e `vft_warning` gained `WARNING|INVALID_USE_OF_VISIBLE_FOR_TESTING_MEMBER` under the SDK's `dart analyze`; `SS-R2` showed only `Box.zero` kept, with `introduces a warning: …`, while `Box.all` converted. Suite 80/80 green.
- R-SS-3 is a contract regression from Phase 4, outside the plan's text. Library-wide pruning wrote the part's library even when that file was excluded, generated or not given, and the report named only the part. Now `_finalize` refuses the file's conversion when a cut lands in a unit outside the run's collected file set, giving the reason (`excluded`, `generated`, `not among the given paths`). `_FileSanitizer.run` returns a `FileResult` per written file with that file's own `removedImports`, and `Sanitizer.run` merges results by path (a library pruned for a part may convert its own sites too). `FileResult.removedImports` now counts per file instead of per library. Red first: in all three `SS-R3` "never edits" cases the library lost its two imports; "reports every file it writes" was missing the library's key. Suite 84/84 green.
- R-SS-4: before writing any file of a library, `_FileSanitizer` opens every target in append mode. On failure it writes nothing, records `SanitizeResult.writeFailures`, gives the kept reason `cannot write <file>: <OS error>`, and the CLI prints `error: could not write … so … was not converted.` and exits **74**. The plan defines no code for a write failure; 74 (EX_IOERR) follows its sysexits use (64, 69). A failure after that check (a full disk) is caught and reported the same way, though files written before it stay written. Red first: `SS-R4` threw `PathAccessException … Permission denied`; the CLI exited 255 where it should exit 74. Both tests skip on Windows. Suite 86/86 green.
- R-SS-5: orphan selection keys a removable-import diagnostic by `(unit path, directive index, code)` (`_ImportIssue`), recorded once from the original library. A rewrite deletes no directive, so the index survives it. The old per-message count went by position and swapped two imports of one URI. The e2e harness cannot see this case (both outcomes leave one identical `unused_import`), so `SS-R5` asserts the text. Red first: it kept `import 'r5_fit.dart' show Mode;` and dropped `as keep_me`. Suite 87/87 green.
- R-SS-6 deleted the restating private docs on `rootOf`, `offLimits`, `_overlaid`, `_refuseAll`, `_unwritable`, `_keptSites`, `_describe`, `_census`, `_importAt`, `_globError` and `_display`. `_dartOnPath` keeps only its CRLF trap, and `_ResolvedShorthand.staticType` went in R-SS-1. Trap and contract notes stay (`_DiagKey`, `_isTransparent`, `_canonical`, `_typeKey`, `_restrictionsOf`, `_ImportIssue`, `_writeAll`, `_write`). No test can go red for a comment-only change. Suite 87/87 green.
- R2-SS-1: the multiset count had no test. SS-B3 and e2e `masked_error` are cascades, which the typed-slot rule refuses before the diagnostic check runs. The reviewer's mutant (`if (!baseline.containsKey(key))`, the old set check) left the suite green. The reviewer's fixture (`@Deprecated static const Geo zero`, cross-package) no longer isolates it: since R-SS-2, `_restrictionsOf` refuses that rebind first (`rebinds to Geo2.zero, which is @Deprecated`, checked under the mutant). The new e2e `duplicate_info` uses a forwarder with no restricting annotation of its own whose optional named parameter is `@Deprecated` (a deprecated *required* parameter gets no diagnostic). `take(Box.all(v: 2))` passes every node-level check and adds a second copy of the info that `final pre = Geo.all(v: 1);` already has. Proof, built from `git archive HEAD` into a scratch copy, never in the repo: under the mutant, `duplicate_info` fails with a surplus `INFO|DEPRECATED_MEMBER_USE|…/use.dart|'v' is deprecated…`, and it is the suite's only failure (87 pass, 1 fails). At HEAD it is green. The SS-B3 and `masked_error` comments now say the typed-slot rule refuses them.
- R2-SS-2 resolves a conflict between two plan texts. Phase 8 dictated "Runs on macOS, Linux and Windows (all three in CI)", while the Phase 7 `ci.yaml` runs only ubuntu and windows. The README now reads "Linux and Windows in CI; macOS locally"; `ci.yaml` is unchanged.
- R2-SS-3: the plan's install line `dart run skills@ get --package shorthand_sanitizer --all` auto-detects the agent, so in a project with no agent directory yet it prints "Could not auto-detect agent", exits 0 and installs nothing. README and CHANGELOG now show `--agent claude` with a note. This matches the Phase 8 oracle, which already passed `--agent claude`.
- Both review rounds re-verified on `1cb272d`: format reported 0 changed; analyze reported no issues; 88/88 tests passed on the upgrade resolve and 88/88 on the downgrade resolve (analyzer 14.0.0, package_config 2.2.0). pana scored 160/160, and `dart pub publish --dry-run` reported 0 warnings.
- For Phase 9: the CHANGELOG line numbers in step 2 ("lines 1, 9, 13, …, 65") are stale, because `## Unreleased` has grown. Match `^# x.y.z` by pattern instead. The two judgment calls from round 1 that are open to veto are exit code 74 for a write failure, and `@Deprecated`/`@experimental` among the `_restrictionsOf` annotations.
- R3-SS-1 (a pre-existing hole): `dart analyze` from SDK 3.13.4 reports `unused_result` on every shorthand of a `@useResult` member, even where its value is used. The bundled analyzer 14.4 does not, so the diagnostic check cannot see it. `_verdict` now refuses any shorthand whose resolved element (or a getter's field) has `hasUseResult`, same element or licensed, with the reason `resolves to a @useResult member, whose shorthand dart analyze reports as unused`. Red first: e2e `use_result` (the reviewer's `useresult` fixture plus `mustbeconst`'s `Box.res` forwarder) gained 7 `WARNING|UNUSED_RESULT` lines (5× `make`, `origin`, `res`). Suite 89/89 green.

## Execution prompt

Paste as turn 1 of a fresh session:

```text
Execute plans/sweep-fixes.md. It is self-contained and every decision in it is final: do not re-explore, re-decide, or propose architectural changes. Set its frontmatter status to in-progress, then start at the first unticked phase in § Progress, run its oracle, tick it, report the output, and continue phase by phase without waiting for me. Append anything the plan did not name to § Found; anything left open also gets a row in the tracker § Found names. The file is the state of record: after compaction, re-read it and resume from § Progress. Only when every § Verification step ran and passed, delete the plan file in your last commit — plans are ephemeral, git is the archive. A decision the plan does not cover: stop and ask me as a structured question.
```
