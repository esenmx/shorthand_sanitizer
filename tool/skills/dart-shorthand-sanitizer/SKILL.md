---
name: dart-shorthand-sanitizer
description: Batch-convert Type.member to Dart dot-shorthand .member via the dotsan CLI. Use when review flags full-prefix shorthand nits, after generating Dart code with type-prefixed statics, or when asked to adopt dot shorthands.
---

# dart-shorthand-sanitizer

`dotsan` = type-resolved sweep; never hand-edit shorthand nits file by file, and never regex them (silent rebinds: `Base x = Sub.a` → `.a` binds `Base.a`).

```bash
dotsan lib test              # rewrite in place, per-site report
dotsan lib --dry-run         # preview
dotsan --skip=AsyncValue.error lib
dotsan --exclude=glob,glob   # leave matching files alone
dotsan --include-generated   # also rewrite generated-marked files
```

Missing binary → `dart pub global activate shorthand_sanitizer`.

## What it guarantees

A site converts only when the shorthand resolves to the **same element** with no new diagnostics — verified by re-resolving the rewritten file. Unwitnessed contexts (`Object o = Fit.cover`), sibling-namespace statics (`Colors.red` in a `Color` slot), `Enum.values`, and forwarder rebinds (`EdgeInsets.all` in a `padding:` slot → would bind `EdgeInsetsGeometry.all`) all stay prefixed. Operator expressions split correctly: `Pad.all(1) + Pad.only(2)` → `Pad.all(1) + .only(2)`.

## After a run

- Kept prefixes are deliberate — do not "finish the job" by hand.
- Geometry slots (`padding:`, `alignment:`): write `.all(8)` / `.center` directly in new code; the sanitizer will not migrate old prefixes into forwarders.
- Generated files are skipped by their leading comment marker (build_runner, FlutterFire's `firebase_options.dart`, pigeon, protoc, slang) — NOT by filename, so handwritten `*.preview.dart` previews are sanitized too.
