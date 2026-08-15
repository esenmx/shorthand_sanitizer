```bash
dart pub global activate shorthand_sanitizer

dotsan                          # sanitize every existing root dir (lib, bin, test, ...)
dotsan lib test --dry-run       # report only
dotsan --skip=AsyncValue.error  # keep listed members prefixed
```

Before:

```dart
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

After `dotsan lib && dart format lib`:

```dart
await SystemChrome.setPreferredOrientations([.portraitUp, .portraitDown]);

return Text(label, textAlign: .center, overflow: .ellipsis);
```

`dotsan` rewrites the prefixes; `dart format` then reflows what fits in 80 columns, which is where the line reduction comes from.
