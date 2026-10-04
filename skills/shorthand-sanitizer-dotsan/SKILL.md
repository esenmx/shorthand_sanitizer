---
name: shorthand-sanitizer-dotsan
description: Batch-convert Type.member to Dart dot-shorthand .member via the dotsan CLI. Use when review flags full-prefix shorthand nits, after generating Dart code with type-prefixed statics, or when asked to adopt dot shorthands.
license: MIT
---

# shorthand-sanitizer-dotsan

`dotsan` = type-resolved sweep; never hand-edit shorthand nits file by file, and never regex them (silent rebinds: `Base x = Sub.a` → `.a` binds `Base.a`).

```bash
dotsan lib test              # rewrite in place, per-site report
dotsan lib --dry-run         # preview
dotsan --skip=AsyncValue.error lib
dotsan --exclude=glob,glob   # leave matching files alone
dotsan --include-generated   # also rewrite generated-marked files
dotsan lib/page.dart -n --explain  # why each remaining site stays prefixed
dotsan lib -n --set-exit-if-changed   # CI gate
dotsan lib -n --format=json   # machine-readable
```

Missing binary → `dart install shorthand_sanitizer`.

## What it guarantees

A site converts only when the shorthand resolves to the **same element** with no new analyzer diagnostic of any severity — verified by re-resolving the rewritten file. Unwitnessed contexts (`Object o = Fit.cover`), sibling-namespace statics (`Colors.red` in a `Color` slot), `Enum.values`, and silent rebinds (`Base x = Sub.a`) all stay prefixed. Operator expressions split correctly: `Pad.all(1) + Pad.only(2)` → `Pad.all(1) + .only(2)`.

Two rebinds are licensed, only in a slot typed exactly as the rebind (argument, typed declaration, return, collection element): a `static const` alias (`Alignment.topCenter`) and a parameter-preserving redirecting factory (`EdgeInsets.all` in `padding:`). Typedefs with type arguments (`typedef IntG = G<int>`) and cascade targets stay prefixed.

## After a run

- Kept prefixes are deliberate — do not "finish the job" by hand. `--explain` names the reason per site.
- Named constructors and enum values in typed slots (like `padding: .all(8)`) convert automatically.
- Generated files are skipped by their leading comment marker (build_runner, FlutterFire's `firebase_options.dart`, pigeon, protoc, slang) — NOT by filename, so handwritten `*.preview.dart` previews are sanitized too.
