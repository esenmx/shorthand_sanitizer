# shorthand_sanitizer example

Install the `shorthand` command, then run it from your project root:

```bash
dart install shorthand_sanitizer

shorthand                          # every existing root (lib, bin, test, ...)
shorthand lib test --dry-run       # report only
shorthand --skip=AsyncValue.error  # keep listed members prefixed
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

After `shorthand lib && dart format lib`:

```dart
await SystemChrome.setPreferredOrientations([.portraitUp, .portraitDown]);

return Text(label, textAlign: .center, overflow: .ellipsis);
```

`shorthand` rewrites the prefixes; `dart format` then reflows what fits in 80
columns, which is where the line reduction comes from.
