```bash
dart pub global activate shorthand_sanitizer

dotsan                          # sanitize lib/
dotsan lib test --dry-run       # report only
dotsan --skip=AsyncValue.error  # keep listed members prefixed
```

Before:

```dart
Column(
  mainAxisAlignment: MainAxisAlignment.start,
  children: [Text('hi', overflow: TextOverflow.ellipsis)],
)
```

After `dotsan lib`:

```dart
Column(
  mainAxisAlignment: .start,
  children: [Text('hi', overflow: .ellipsis)],
)
```
