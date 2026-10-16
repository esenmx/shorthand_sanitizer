# Contributing

1. `dart pub get`
2. Run what CI runs:

   ```bash
   git ls-files -z -- '*.dart' |
     xargs -0 dart format --output=none --set-exit-if-changed
   dart analyze --fatal-infos --fatal-warnings
   dart test
   dart run tool/check_snippets.dart \
     --import package:shorthand_sanitizer/shorthand_sanitizer.dart
   npx --yes markdownlint-cli2@0.23.3
   dart pub publish --dry-run
   ```

3. Add a line under `## Unreleased` in `CHANGELOG.md` for every user-visible
   change.

Releases are published manually by the maintainer.
