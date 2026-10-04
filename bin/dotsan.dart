import 'dart:io';

import 'package:args/args.dart';
import 'package:cli_util/cli_logging.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:shorthand_sanitizer/shorthand_sanitizer.dart';

const _version = '0.9.0';

const _defaultRoots = [
  'lib',
  'bin',
  'test',
  'example',
  'tool',
  'integration_test',
  'benchmark',
];

ArgParser _buildParser() {
  return ArgParser(usageLineLength: 80)
    ..addFlag(
      'dry-run',
      abbr: 'n',
      negatable: false,
      help: 'Report what would change without writing.',
    )
    ..addMultiOption(
      'skip',
      valueHelp: 'Type.member,member',
      help: 'Keep the listed members prefixed.',
    )
    ..addMultiOption(
      'exclude',
      valueHelp: 'glob,glob',
      help:
          'Leave matching files alone '
          '(firebase_options.dart, **/legacy/**).',
    )
    ..addFlag(
      'include-generated',
      negatable: false,
      help: 'Also rewrite generated-marked files.',
    )
    ..addFlag(
      'allow-errors',
      negatable: false,
      help: 'Also rewrite files whose library already has analysis errors.',
    )
    ..addFlag(
      'explain',
      abbr: 'e',
      negatable: false,
      help: 'Also list every site left prefixed, with the reason.',
    )
    ..addFlag('version', abbr: 'v', negatable: false, help: 'Print version.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Print this usage.');
}

String _usage(ArgParser parser) {
  return '''
Usage: dotsan [paths...] [options]
${parser.usage}
Rewrites Type.member to dot-shorthand .member wherever the rewrite provably
resolves to the same element, then prunes any import the dropped Type prefix
orphaned. Files whose leading comment declares them generated are skipped.
Default paths: every conventional root directory that exists
(${_defaultRoots.join(', ')}).''';
}

Future<void> main(List<String> args) async {
  final parser = _buildParser();
  final ArgResults opts;
  try {
    opts = parser.parse(args);
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln()
      ..writeln(_usage(parser));
    exit(64);
  }
  if (opts.flag('help')) {
    stdout.writeln(_usage(parser));
    return;
  }
  if (opts.flag('version')) {
    stdout.writeln('dotsan $_version');
    return;
  }

  final usageErrors = [
    for (final path in opts.rest)
      switch (FileSystemEntity.typeSync(path)) {
        .notFound => 'no such file or directory: $path',
        .file when !path.endsWith('.dart') => 'not a .dart file: $path',
        _ => null,
      },
    for (final pattern in opts.multiOption('exclude')) _globError(pattern),
  ].nonNulls.toList();
  if (usageErrors.isNotEmpty) {
    usageErrors.forEach(stderr.writeln);
    exitCode = 64;
    return;
  }

  final paths = [...opts.rest];
  if (paths.isEmpty) {
    paths.addAll(_defaultRoots.where((d) => Directory(d).existsSync()));
    if (paths.isEmpty) {
      stderr.writeln('no conventional root directory found (see --help)');
      exit(64);
    }
  }

  final dryRun = opts.flag('dry-run');
  // Piped stdout is the parseable report; the non-ANSI Progress fallback
  // prints its message there, so the spinner is TTY-only.
  final progress = stdout.hasTerminal
      ? Logger.standard().progress('analyzing')
      : null;
  final result = await Sanitizer(
    skips: opts.multiOption('skip').toSet(),
    excludes: opts.multiOption('exclude'),
    dryRun: dryRun,
    skipGenerated: !opts.flag('include-generated'),
    explain: opts.flag('explain'),
    allowErrors: opts.flag('allow-errors'),
  ).run(paths);
  progress?.finish(showTiming: true);
  for (final file in result.files) {
    stdout.writeln(_display(file.path));
    for (final line in [...file.converted, ...file.kept]) {
      stdout.writeln('  $line');
    }
  }
  final ansi = Ansi(
    stderr.supportsAnsiEscapes && stdioType(stderr) == .terminal,
  );
  for (final MapEntry(key: (:root, :version), value: n)
      in result.skippedBelowFloor.entries) {
    stderr.writeln(
      '${ansi.yellow}warning:${ansi.none} skipped $n file(s) in '
      '${_display(root)} at language version $version — dot shorthands need '
      '3.10. Raise `environment: sdk:` in '
      '${p.join(_display(root), 'pubspec.yaml')} (or drop a `// @dart=` '
      'override); the installed SDK does not decide this.',
    );
  }
  for (final MapEntry(key: root, value: n)
      in result.skippedUnconfigured.entries) {
    stderr.writeln(
      '${ansi.yellow}warning:${ansi.none} skipped $n file(s) in '
      '${_display(root)}: no package config entry — run `dart pub get` there '
      'first.',
    );
  }
  if (result.skippedWithErrors.isNotEmpty) {
    stderr.writeln(
      '${ansi.yellow}warning:${ansi.none} skipped '
      '${result.skippedWithErrors.length} file(s) whose library already has '
      'analysis errors (fix them or pass --allow-errors):',
    );
    for (final path in result.skippedWithErrors) {
      stderr.writeln('  ${_display(path)}');
    }
  }
  final changed = result.files.where((f) => f.converted.isNotEmpty).length;
  final kept = result.keptCount;
  final skipped = result.skippedByList;
  final removed = result.removedImportCount;
  final verb = dryRun ? 'would convert' : 'converted';
  final pruneVerb = dryRun ? 'would prune' : 'pruned';
  stdout.writeln(
    '$verb ${result.convertedCount} site(s) in $changed file(s)'
    '${kept > 0 ? ', $kept kept' : ''}'
    '${skipped > 0 ? ', $skipped skip-listed' : ''}'
    '${removed > 0 ? ', $pruneVerb $removed orphaned import(s)' : ''}',
  );
}

/// Why [pattern] is not a valid `--exclude` glob, or null when it is.
String? _globError(String pattern) {
  try {
    Glob(pattern);
    return null;
  } on FormatException catch (e) {
    return 'invalid --exclude glob "$pattern": ${e.message}';
  }
}

/// [path] relative to the working directory when inside it (`.` for the
/// directory itself), else absolute; native separators either way.
String _display(String path) {
  final absolute = p.normalize(p.absolute(path));
  if (p.equals(absolute, p.current)) return '.';
  return p.isWithin(p.current, absolute) ? p.relative(absolute) : absolute;
}
