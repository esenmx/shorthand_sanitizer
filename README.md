# shorthand_sanitizer

Batch codemod: rewrites `Type.member` to Dart 3.10 [dot-shorthand](https://dart.dev/language/dot-shorthands) `.member` — **only** where the rewrite provably resolves to the same element.

Covers enum values, static getters/fields/methods, and named (incl. `factory`/`const`) constructors. Unnamed constructors stay: `.new(...)` saves nothing over `Type(...)`.

## Install

```bash
dart pub global activate shorthand_sanitizer   # installs the `dotsan` command
```

That installs a shim at `~/.pub-cache/bin/dotsan` that loads a VM snapshot on every run (~160 ms of startup). For large repos, compile the same tool AOT (~20 ms) **over that shim** — the `dotsan` on your `PATH` just gets fast, no new directory to wire up:

```bash
dart compile exe \
  "$(ls -d ~/.pub-cache/hosted/pub.dev/shorthand_sanitizer-*/ | sort -V | tail -1)bin/dotsan.dart" \
  --packages ~/.pub-cache/global_packages/shorthand_sanitizer/.dart_tool/package_config.json \
  -o ~/.pub-cache/bin/dotsan
```

- The `$(ls … | sort -V | tail -1)` picks the newest cached copy of the package — no version to type.
- `--packages` is required: `dart compile exe` needs resolved dependencies, the hosted cache directory carries no package config of its own, and `global_packages/shorthand_sanitizer/` holds the resolution `activate` just made.
- From a clone instead: `dart pub get && dart compile exe bin/dotsan.dart -o ~/.pub-cache/bin/dotsan`.

**After every upgrade** (`dart pub global activate shorthand_sanitizer`), re-run the compile: activate rewrites `~/.pub-cache/bin/dotsan` back to the snapshot shim for the new version, so you drop to the slow path — never to stale code — until you do. That safety is why the AOT binary belongs at the shim path and not in some other `PATH` directory, where an old binary would keep shadowing every future upgrade. `dotsan --version` tells you what you're running.

## Use

```bash
dotsan                              # sanitize every existing root dir (lib, bin, test, ...)
dotsan lib test --dry-run           # report only
dotsan --skip=AsyncValue.error      # keep listed members prefixed
dotsan --exclude=**/legacy/**       # leave matching files alone
dotsan --include-generated          # also rewrite generated-marked files
```

`--skip` takes `Type.member` or bare `member` names; `--exclude` takes globs, matched against the CWD-relative path when the pattern contains `/`, else the basename (both comma-separated).

Generated files are detected by their **leading comment**, not filename shape: build_runner's `GENERATED CODE - DO NOT MODIFY BY HAND`, FlutterFire's `firebase_options.dart`, pigeon, protoc, and slang outputs are all skipped, while a handwritten `page.preview.dart` is sanitized like any other source.

## The guarantee

Each file is resolved with the analyzer, every syntactic candidate is rewritten speculatively, and the result is resolved again. A rewrite survives only if its shorthand node resolved back to the **same element** with **no new diagnostics**. Everything else reverts:

```dart
final Object o = Fit.cover;    // unwitnessed context — kept
const Color c = Colors.red;    // member lives on Colors, context is Color — kept
const Base x = Sub.a;          // .a would silently rebind to Base.a — kept
final l = Fit.values;          // context is List<Fit>, never the enum — kept
padding: EdgeInsets.all(8),    // .all binds EdgeInsetsGeometry.all, which
                               // allocates a fresh instance — kept
```

The rebind cases compile either way — text-based converters ship them as silent element changes. Element identity is the only check that catches them. (Corollary: in geometry slots, write `.all(8)` directly in new code; the sanitizer won't migrate old prefixes into forwarders.)

### The one licensed rebind

A base class often re-declares its subtype's constants as its own:

```dart
// flutter/painting: alignment.dart
abstract class AlignmentGeometry {
  static const AlignmentGeometry topCenter = Alignment.topCenter;
}
```

`Alignment.topCenter` in an `AlignmentGeometry` slot binds `.topCenter` to a *different* element — but to the identical canonicalized constant, so `identical()` still holds and the rewrite is observably a no-op. Those convert. Const-value identity is the oracle, and it is stricter than it sounds:

```dart
alignment: Alignment.topCenter,          // AlignmentGeometry.topCenter is the
                                         // same canonical constant — converts
padding: EdgeInsets.all(8),              // .all is a method: no constant to
                                         // compare — kept
alignment: AlignmentDirectional.center,  // same (0.0, 0.0) as Alignment.center,
                                         // different type — kept
```

An alias declared in the file being rewritten is also kept: its value would be read back out of the speculative text, letting the rewrite judge itself.

Operator expressions split correctly: `Pad.all(1) + Pad.only(2)` becomes `Pad.all(1) + .only(2)` — the left operand has no shorthand context, the right one is a typed argument. Reverting one candidate can make a neighbor valid, so failed sites near a co-failure are retried individually before the file is finalized.

## Why not …

|Alternative|Why not|
|--|--|
|regex converters|no type resolution — aggressive by design, silent rebinds possible|
|IDE assist (`ConvertToDotShorthand`)|per-site, interactive; driving it over a repo costs one server RPC per candidate|
|analyzer plugins (`prefer_shorthands`, or a custom `analysis_server_plugin` lint)|plugin fixes are single-site by design — the SDK forbids bulk applicability, so no `dart fix --apply` sweep|
|`dart fix`|no SDK lint backs the conversion, so it has nothing to apply|

Benchmark, 40 files / 640 sites (M-series, Dart 3.11): analysis-server-driven script 6.2 s → this tool (AOT) **0.8 s**, byte-identical output plus the `== .value` sites the assist skips.

## Notes

- Requires the target package's language version ≥ 3.10; below that the run is a clean no-op.
- AOT builds locate the SDK via `DART_SDK`, then the `dart` on `PATH` (Flutter shim included).
