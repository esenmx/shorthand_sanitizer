# 0.5.1

- README: correct the AOT upgrade recipe — `pub global activate`/`deactivate` refuse a foreign binary at the shim path (`Failed to decode data using encoding 'utf-8'`), so upgrading requires `rm ~/.pub-cache/bin/dotsan` first; 0.5.0 wrongly claimed activate rewrites the shim in place.

# 0.5.0

- `dotsan` with no path arguments now scans every conventional root directory that exists — `lib`, `bin`, `test`, `example`, `tool`, `integration_test`, `benchmark` — instead of only `lib`, and exits 64 when none exist.
- Warn when files are skipped because their package's language version predates 3.10 (dot shorthands' floor), counted per version. Previously such a run reported an ordinary "converted 0 site(s)", indistinguishable from having nothing to convert.
- Generated-file detection now requires the marker inside the **leading comment block** (word-boundary match on `generated code/file/by`, `auto-generated`), instead of `generat` anywhere in the first 300 bytes — a file whose opening doc comment merely mentions generation is no longer skipped.
- Recovery pass groups co-failed candidates by enclosing statement: type inference cannot cross a statement boundary, so one re-resolve now retries one candidate per group instead of one per round — fewer analyzer passes on files with many collisions.
- README: the AOT install recipe now compiles over the `~/.pub-cache/bin/dotsan` shim (no `<version>` placeholder, no extra `PATH` directory), so a later `dart pub global activate` can never leave a stale binary shadowing the upgrade.

- Convert a rebind onto a `static const` **alias** of the original — `Alignment.topCenter` in an `AlignmentGeometry` slot now becomes `.topCenter`. The shorthand binds a different element (`AlignmentGeometry.topCenter`), but const canonicalization makes it the identical object, so the rewrite is observably a no-op. Const-value identity is the oracle; it still refuses non-const forwarders (`EdgeInsetsGeometry.all` allocates), same-valued constants of a different type (`AlignmentDirectional.center` vs `Alignment.center`), and aliases declared in the file being rewritten.

# 0.3.1

- Fix `dotsan --version` reporting a stale version — the hardcoded CLI constant had drifted from `pubspec.yaml`. A test now pins the two together so it cannot drift again.
- Harden `PropertyAccess` collection with the receiver-position guard `PrefixedIdentifier` already had: `Type.staticGetter.member` keeps its prefix instead of being collected and reverted downstream.

# 0.3.0

- Convert statics reached through an import prefix (`p.Type.member`) and through a type alias (`typedef Alias = Type; Alias.member`) — the target's element is resolved past the prefix/alias to the underlying `InterfaceElement` before collecting.
- Convert static getters and fields accessed as a `PropertyAccess` (`prefix.Type.staticGetter`), not just `PrefixedIdentifier` and method-invocation forms.
- Static-method collection accepts any resolvable target expression, not only a bare `SimpleIdentifier`, so prefixed and aliased receivers (`p.Type.staticMethod(...)`) convert.

# 0.2.0

- Prune imports the rewrite orphans: dropping a `Type` prefix can leave the import that supplied `Type` with no remaining referent. The final verified resolve is the oracle — any `unused_import`/`unnecessary_import` it reports that the original file did not is a self-inflicted orphan whose directive is removed. Imports the file already left unused are untouched.
- `dotsan` reports pruned imports in its summary; `SanitizeResult.removedImportCount` / `FileResult.removedImports` expose the count.

# 0.1.0

- Initial release: type-resolved `Type.member` → `.member` batch codemod, shipped as the `dotsan` executable.
- Element-identity verification — unwitnessed contexts, sibling-namespace members (`Colors.red` in a `Color` slot), `Enum.values`, forwarder rebinds (`EdgeInsets.all` in geometry slots), and silent same-name rebinds all revert.
- Enum values, static getters/fields/methods, named/factory/const constructors; operator expressions split per-operand (`Pad.all(1) + .only(2)`).
- `--dry-run`, `--skip=Type.member|member`, `--exclude=globs`, `--include-generated`, `--version`.
- Generated files detected by leading-comment marker (build_runner, FlutterFire, pigeon, protoc, slang) — handwritten double-extension files like `*.preview.dart` are sanitized normally.
- AOT-friendly SDK discovery (`DART_SDK` → executable → `dart` on PATH / Flutter shim).
