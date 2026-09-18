# shorthand_sanitizer

[![pub package](https://img.shields.io/pub/v/shorthand_sanitizer.svg)](https://pub.dev/packages/shorthand_sanitizer)
[![Dart SDK](https://img.shields.io/badge/Dart-3.10%2B-blue.svg)](https://dart.dev)

A safe, automated codemod for Dart 3.10+ [dot shorthands](https://dart.dev/language/dot-shorthands). Rewrites `Type.member` to `.member` across your entire Flutter or Dart project, then automatically cleans up any imports orphaned by dropping the prefixes.

```dart
// Before
return Padding(
  padding: EdgeInsets.all(16),
  child: Text(
    label,
    textAlign: TextAlign.center,
    overflow: TextOverflow.ellipsis,
  ),
);
```

```dart
// After `dotsan && dart format .`
return Padding(
  padding: .all(16),
  child: Text(label, textAlign: .center, overflow: .ellipsis),
);
```

`dotsan` safely removes redundant type prefixes, and `dart format` naturally reflows arguments that now fit within your line length limit.

---

## Installation

### AOT Native Binary (Default & Recommended)

Compiles `dotsan` into a standalone native executable inside your global pub cache bin. Replaces Dart VM startup (~160 ms) with instant native execution (~20 ms) on your existing `PATH`:

```bash
CACHE="${PUB_CACHE:-$HOME/.pub-cache}" && \
HOST="$CACHE/hosted/pub.dev" && \
GLOBAL="$CACHE/global_packages/shorthand_sanitizer" && \
rm -f "$CACHE/bin/dotsan" && \
dart pub global activate shorthand_sanitizer && \
ENTRY=$(ls -d \
  "$HOST"/shorthand_sanitizer-*/bin/dotsan.dart \
  2>/dev/null | sort -V | tail -1) && \
dart compile exe "$ENTRY" \
  --packages "$GLOBAL/.dart_tool/package_config.json" \
  -o "$CACHE/bin/dotsan"
```

Ensure your pub cache bin directory is in your `PATH` (`~/.pub-cache/bin` on macOS/Linux, `%LOCALAPPDATA%\Pub\Cache\bin` on Windows).

### Standard VM Installation

If you prefer standard global activation without native compilation:

```bash
dart pub global activate shorthand_sanitizer
```

---

## Quick Start (Plug & Play)

Run `dotsan` in any Dart or Flutter project root:

```bash
dotsan && dart format .
```

That's it! Your project is now upgraded to modern dot shorthands with zero orphaned imports.

---

## Usage & Options

```bash
# Sanitize all roots (lib, test, bin, etc.)
dotsan

# Preview changes (--dry-run)
dotsan lib test -n

# Keep specific members prefixed
dotsan --skip=AsyncValue.error

# Exclude matching file globs
dotsan --exclude="**/legacy/**"

# Also rewrite generated files
dotsan --include-generated

# Show version (-h for full options)
dotsan -v
```

- `--skip`: Accepts `Type.member` or bare `member` names (comma-separated).
- `--exclude`: Glob pattern matching CWD-relative paths or file basenames (comma-separated).
- **Generated Files**: Automatically detected and skipped by their header comment (e.g., `build_runner`, `firebase_options.dart`, pigeon, protoc, and slang outputs), while handwritten files like `page.preview.dart` are processed normally.

---

## How It Works & What Converts

`dotsan` uses the **Dart Analyzer API** directly:

1. Rewrites candidate expressions speculatively in memory.
2. Re-resolves the AST in memory.
3. Keeps a rewrite **only** if the shorthand resolves to the exact same element with **zero new diagnostics or errors**. If ambiguous or changed, it safely reverts.
4. Prunes any `import` directives left unused when prefixes are dropped.

### Converts Cleanly

| Kind | Before | After |
| :--- | :--- | :--- |
| **Enum values** | `TextAlign.center` | `.center` |
| **Named constructors** | `EdgeInsets.all(16)` | `.all(16)` |
| **Factory constructors** | `BorderRadius.circular(8)` | `.circular(8)` |
| **Static getters & fields** | `Duration.zero` | `.zero` |
| **Const aliases** | `Alignment.topCenter` | `.topCenter` |
| **Redirecting-factory forwarders** | `padding: EdgeInsets.only(left: 8)` | `.only(left: 8)` |

### Intentionally Stays Prefixed

`dotsan` leaves expressions prefixed when context type is ambiguous or would change program semantics:

```dart
// Unwitnessed context (type is Object, not Fit)
final Object o = Fit.cover;

// Sibling namespace (Colors.red, context is Color)
const Color c = Colors.red;

// Rebind risk (.a would silently bind Base.a)
const Base x = Sub.a;

// Context is List<Fit>, not enum
final l = Fit.values;

// Unnamed constructors (.new) are not rewritten
Text('Hello');
```

---

## OS Caching & Performance

Every candidate verification requires an analyzer resolution. To make runs fast, `dotsan` caches analyzer data on the OS:

- **Cache Locations**:
  - **macOS**: `~/Library/Caches/dotsan`
  - **Linux**: `$XDG_CACHE_HOME/dotsan` (or `~/.cache/dotsan`)
  - **Windows**: `%LOCALAPPDATA%\dotsan`
- **What is cached**: Linked element models for the Dart SDK, dependencies, and project libraries are persisted to an evicting file byte store (capped at 1 GiB, LRU) fronted by an in-memory cache.
- **Effects on OS & Performance**:
  - **First run vs subsequent runs**: The first run links element models. Subsequent runs (such as running without `-n` after a `--dry-run`, or processing another project on the same SDK) skip linking and run >2x faster.
  - **Content-addressed & safe**: Cache entries are keyed by content signatures; stale entries never corrupt results.
  - **Safe to clear**: You can wipe the cache folder at any time (`rm -rf ~/Library/Caches/dotsan`); `dotsan` rebuilds it automatically on the next run.

---

## Requirements

- Target package language version ≥ **3.10** (packages below this are safely skipped as a clean no-op).
- Compatible with Dart & Flutter projects on macOS, Linux, and Windows.
