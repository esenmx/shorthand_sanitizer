# 0.1.0

- Initial release: type-resolved `Type.member` → `.member` batch codemod, shipped as the `dotsan` executable.
- Element-identity verification — unwitnessed contexts, sibling-namespace members (`Colors.red` in a `Color` slot), `Enum.values`, forwarder rebinds (`EdgeInsets.all` in geometry slots), and silent same-name rebinds all revert.
- Enum values, static getters/fields/methods, named/factory/const constructors; operator expressions split per-operand (`Pad.all(1) + .only(2)`).
- `--dry-run`, `--skip=Type.member|member`, `--exclude=globs`, `--include-generated`, `--version`.
- Generated files detected by leading-comment marker (build_runner, FlutterFire, pigeon, protoc, slang) — handwritten double-extension files like `*.preview.dart` are sanitized normally.
- AOT-friendly SDK discovery (`DART_SDK` → executable → `dart` on PATH / Flutter shim).
