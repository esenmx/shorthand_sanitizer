# shorthand_sanitizer

Batch codemod for Dart 3.10 [dot shorthands](https://dart.dev/language/dot-shorthands): rewrites `Type.member` to `.member` across a whole repo, then prunes the imports that dropping the prefix orphaned.

```dart
// before
await SystemChrome.setPreferredOrientations([
  DeviceOrientation.portraitUp,
  DeviceOrientation.portraitDown,
]);

return Text(
  label,
  textAlign: TextAlign.center,
  overflow: TextOverflow.ellipsis,
);
```

```dart
// after `dotsan && dart format .`
await SystemChrome.setPreferredOrientations([.portraitUp, .portraitDown]);

return Text(label, textAlign: .center, overflow: .ellipsis);
```

Nine lines down to two. `dotsan` only edits the prefixes; the collapse is `dart format` reflowing what now fits in 80 columns — and that is where most of the diff comes from on real code, since an argument list or a collection of enum values that had to wrap usually stops needing to.

Covers enum values, static getters/fields/methods, and named (incl. `factory`/`const`) constructors. Unnamed constructors stay: `.new(...)` saves nothing over `Type(...)`.

## Why not a regex

Because this is not a text transformation. `const Base x = Sub.a` rewritten to `.a` binds `Base.a` instead — a different element, no error, silently different program.

So every file is resolved with the analyzer, every candidate is rewritten speculatively, and the file is resolved again. A rewrite survives only if its shorthand resolved back to the **same element** with **no new diagnostics**. Everything else reverts.

|Alternative|Why not|
|--|--|
|regex converters|no type resolution — aggressive by design, silent rebinds possible|
|IDE assist (`ConvertToDotShorthand`)|per-site, interactive; driving it over a repo costs one server RPC per candidate|
|analyzer plugins (`prefer_shorthands`, or a custom `analysis_server_plugin` lint)|plugin fixes are single-site by design — the SDK forbids bulk applicability, so no `dart fix --apply` sweep|
|`dart fix`|no SDK lint backs the conversion, so it has nothing to apply|

Benchmark, 40 files / 640 sites (M-series, Dart 3.11): analysis-server-driven script 6.2 s → this tool (AOT) **0.8 s**, byte-identical output plus the `== .value` sites the assist skips.

## Install

```bash
dart pub global activate shorthand_sanitizer   # installs the `dotsan` command
```

## Use

```bash
dotsan                              # sanitize every existing root dir (lib, bin, test, ...)
dotsan lib test -n                  # --dry-run: report only
dotsan --skip=AsyncValue.error      # keep listed members prefixed
dotsan --exclude=**/legacy/**       # leave matching files alone
dotsan --include-generated          # also rewrite generated-marked files
dotsan -v                           # --version; -h/--help for full usage
```

`--skip` takes `Type.member` or bare `member` names; `--exclude` takes globs, matched against the CWD-relative path when the pattern contains `/`, else the basename (both comma-separated).

Generated files are detected by their **leading comment**, not filename shape: build_runner's `GENERATED CODE - DO NOT MODIFY BY HAND`, FlutterFire's `firebase_options.dart`, pigeon, protoc, and slang outputs are all skipped, while a handwritten `page.preview.dart` is sanitized like any other source.

## What stays prefixed

```dart
final Object o = Fit.cover;    // unwitnessed context — kept
const Color c = Colors.red;    // member lives on Colors, context is Color — kept
const Base x = Sub.a;          // .a would silently rebind to Base.a — kept
final l = Fit.values;          // context is List<Fit>, never the enum — kept
padding: EdgeInsets.all(8),    // .all binds EdgeInsetsGeometry.all, which
                               // allocates a fresh instance — kept
```

One rebind is licensed: a `static const` **alias** of the original — Flutter declares `AlignmentGeometry.topCenter = Alignment.topCenter` — is a different element but the identical canonicalized constant, so `alignment: Alignment.topCenter` does convert. Const-value identity is the oracle, and it is stricter than it sounds: `AlignmentDirectional.center` holds the same `(0.0, 0.0)` as `Alignment.center` but a different type, so it stays.

Kept prefixes are deliberate — don't finish the job by hand. Corollary: in geometry slots write `.all(8)` directly in new code, since the sanitizer won't migrate an old prefix into a forwarder.

## Optional: AOT binary

`pub global activate` installs a shim that loads a VM snapshot on every run (~160 ms of startup). For large repos, compile the same tool AOT (~20 ms) **over that shim** — the `dotsan` already on your `PATH` just gets fast, no new directory to wire up:

```bash
dart compile exe \
  "$(ls -d ~/.pub-cache/hosted/pub.dev/shorthand_sanitizer-*/ | sort -V | tail -1)bin/dotsan.dart" \
  --packages ~/.pub-cache/global_packages/shorthand_sanitizer/.dart_tool/package_config.json \
  -o ~/.pub-cache/bin/dotsan
```

The `ls … | sort -V | tail -1` picks the newest cached copy, so there's no version to type. `--packages` is required: `dart compile exe` needs resolved dependencies, and the hosted cache directory carries no package config of its own — `global_packages/shorthand_sanitizer/` holds the resolution `activate` just made. From a clone instead: `dart pub get && dart compile exe bin/dotsan.dart -o ~/.pub-cache/bin/dotsan`.

**Upgrading afterwards:** `pub global` refuses to touch the compiled binary occupying its shim path — `activate` and `deactivate` both fail with `Failed to decode data using encoding 'utf-8'`. Delete it first:

```bash
rm ~/.pub-cache/bin/dotsan
dart pub global activate shorthand_sanitizer
# ...then recompile with the command above
```

That refusal is the safety: the upgrade fails loudly instead of leaving the old version silently shadowing the new one — which is exactly what a binary parked in some other `PATH` directory would do on every upgrade you forget to recompile. If `dotsan --version` ever sticks to an old version that reinstalling doesn't fix, run `which -a dotsan`: it must list only `~/.pub-cache/bin/dotsan` — delete any other copy it finds.

## Notes

- Requires the target package's language version ≥ 3.10; below that the run is a clean no-op.
- AOT builds locate the SDK via `DART_SDK`, then the `dart` on `PATH` (Flutter shim included).
