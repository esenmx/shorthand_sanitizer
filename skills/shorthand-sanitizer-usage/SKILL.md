---
name: shorthand-sanitizer-usage
description: Batch-convert Type.member to Dart dot-shorthand .member via the `shorthand` CLI. Use when review flags full-prefix shorthand nits, after generating Dart code with type-prefixed statics, or when asked to adopt dot shorthands.
license: MIT
---

# shorthand-sanitizer-usage

`shorthand` = type-resolved sweep; never hand-edit shorthand nits file by file,
and never regex them (silent rebinds: `Base x = Sub.a` → `.a` binds `Base.a`).

```bash
shorthand lib test              # rewrite in place, per-site report
shorthand lib --dry-run         # preview
shorthand --changed             # only git-modified/untracked files
shorthand --since=origin/main   # only files changed since a git ref
shorthand --skip=AsyncValue.error lib
shorthand --exclude=glob,glob   # skip matching files (/ globs: CWD-relative)
# also rewrite what the package's own analysis_options.yaml excludes
shorthand --no-analyzer-excludes
shorthand --include-generated   # also rewrite generated-marked files
shorthand --allow-errors        # also rewrite files whose library has errors
shorthand lib/page.dart -n --explain  # why each remaining site stays prefixed
# CI gate: 1 = would convert, 65 = a file was skipped
shorthand lib -n --set-exit-if-changed
shorthand lib -n --format=json   # machine-readable
```

Missing binary → `dart install shorthand_sanitizer`.

## What it guarantees

A site converts only when the shorthand resolves to the **same element** with no
new analyzer diagnostic of any severity — verified by re-resolving the rewritten
library. Unwitnessed contexts (`Object o = Fit.cover`), sibling-namespace
statics (`Colors.red` in a `Color` slot), `Enum.values`, metadata annotations
(`@MyAnnot.instance`), unnamed constructors (`Text('Hi')`), and silent rebinds
(`Base x = Sub.a`) all stay prefixed. Operator expressions split correctly:
`Pad.all(1) + Pad.only(2)` → `Pad.all(1) + .only(2)`. Untyped `List` and `Set`
literals with no outer element context hoist `<Type>` when 2+ elements convert
and element types stay unchanged (`[Fit.cover, Fit.contain]` →
`<Fit>[.cover, .contain]`, `{Fit.cover, Fit.contain}` →
`<Fit>{.cover, .contain}`); 1-element `[Fit.cover]` and widened `List<Object?>`
slots stay prefixed.

Two rebinds are licensed, only in a slot typed exactly as the rebind (argument,
typed declaration, constructor field initializer, return or `yield`, collection
element, index or binary operator operand, compound assignment RHS, or parameter
default, including across `??` RHS, `?element`, and `FutureOr<T>`): a
`static const` alias (`Alignment.topCenter`) and a parameter-preserving
redirecting factory (`EdgeInsets.all` in `padding:`). Typedefs with type
arguments (`typedef IntG = G<int>`) and cascade targets stay prefixed.

## After a run

- Kept prefixes are deliberate — do not "finish the job" by hand. `--explain`
  names the reason per site.
- Named constructors and enum values in typed slots (like `padding: .all(8)`)
  convert automatically.
- Generated files are skipped by their leading comment marker (build_runner,
  FlutterFire's `firebase_options.dart`, pigeon, protoc, slang) — NOT by
  filename, so handwritten `*.preview.dart` previews are sanitized too.
  `--explain` counts and lists them on stderr.
- Exit 65 means a file was skipped (analysis errors, language < 3.10, no
  `dart pub get`, orphan part, unreadable directory): read the stderr warnings
  and fix the cause — never treat the run as clean.
- Warnings for a `--skip` entry that matched no site or an `--exclude` glob that
  matched no file mean a typo: the file you meant to protect was converted.
- Every pruned import is named under its file, with any trailing comment deleted
  alongside it.
