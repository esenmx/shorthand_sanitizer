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
