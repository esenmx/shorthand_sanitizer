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

### 🚀 Recommended: AOT Native Binary (~10x Faster)

One-time compile directly over the global pub cache shim. Replaces the VM startup (~160 ms) with instantaneous native AOT execution (~20 ms) on your existing `PATH`:

```bash
# 1. Activate package
dart pub global activate shorthand_sanitizer

# 2. Compile to native binary (one-time)
dart compile exe \
  "$(ls -d ~/.pub-cache/hosted/pub.dev/shorthand_sanitizer-*/ | sort -V | tail -1)bin/dotsan.dart" \
  --packages ~/.pub-cache/global_packages/shorthand_sanitizer/.dart_tool/package_config.json \
  -o ~/.pub-cache/bin/dotsan
```

<details>
<summary>Standard VM Installation</summary>

If you prefer standard JIT/VM execution without compiling:

```bash
dart pub global activate shorthand_sanitizer
```
</details>

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
dotsan                              # Sanitize all roots (lib, test, bin, example, etc.)
dotsan lib test -n                  # --dry-run: Preview changes without modifying files
dotsan --skip=AsyncValue.error      # Keep specific members prefixed (e.g. to avoid collisions)
dotsan --exclude="**/legacy/**"     # Exclude matching file globs
dotsan --include-generated          # Also rewrite generated files (skipped by default)
dotsan -v                           # Show version (-h for full options)
```

- `--skip`: Accepts `Type.member` or bare `member` names (comma-separated).
- `--exclude`: Glob pattern matching CWD-relative paths or file basenames (comma-separated).
- **Generated Files**: Automatically detected and skipped by their header comment (e.g., `build_runner`, `firebase_options.dart`, pigeon, protoc, and slang outputs), while handwritten files like `page.preview.dart` are processed normally.

---

## What Converts vs. What Stays Prefixed

`dotsan` converts all witnessed static expressions while keeping your code 100% correct:

### Converts Cleanly

| Kind | Before | After |
| :--- | :--- | :--- |
| **Enum values** | `TextAlign.center` | `.center` |
| **Named constructors** | `EdgeInsets.all(16)` | `.all(16)` |
| **Factory constructors** | `BorderRadius.circular(8)` | `.circular(8)` |
| **Static getters & fields** | `Duration.zero` | `.zero` |
| **Const aliases** | `Alignment.topCenter` | `.topCenter` |

### Intentionally Stays Prefixed (Safety First)

`dotsan` refuses rewrites when the context type is ambiguous or would change program semantics:

```dart
final Object o = Fit.cover;    // Unwitnessed context (type is Object, not Fit) — kept
const Color c = Colors.red;    // Sibling namespace (member on Colors, context is Color) — kept
const Base x = Sub.a;          // Rebind risk (.a would silently bind Base.a) — kept
final l = Fit.values;          // Context is List<Fit>, not enum — kept
Text('Hello');                 // Unnamed constructors (.new('Hello')) are not rewritten
```

---

## Why Not Regex? (Zero-Risk Guarantee)

Dot shorthand migration is **not** a simple text replacement:
- Naive regex replacements can cause **silent rebinds** (e.g. `const Base x = Sub.a` turning into `.a` which silently resolves to `Base.a` instead).
- `dotsan` uses the **Dart Analyzer API**: every candidate is rewritten speculatively and re-analyzed in memory.
- A rewrite survives **only** if it resolves to the exact same element with **zero new diagnostics or errors**. If anything is ambiguous, it safely reverts.
- Any unused `import` statements left behind by removed prefixes are automatically pruned.

---

## Upgrading AOT Binary

When upgrading a compiled AOT binary:

```bash
rm ~/.pub-cache/bin/dotsan
dart pub global activate shorthand_sanitizer
# Then re-run the AOT compile step from above
```

---

## Requirements

- Target package language version ≥ **3.10** (packages below this are safely skipped as a clean no-op).
- Compatible with Dart & Flutter projects on macOS, Linux, and Windows.
