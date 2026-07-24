import 'dart:io';

import 'package:args/args.dart';
import 'package:shorthand_sanitizer/shorthand_sanitizer.dart';

const _version = '0.6.0';

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
      'version',
      abbr: 'v',
      negatable: false,
      help: 'Print version.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage.',
    );
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

  final paths = [...opts.rest];
  if (paths.isEmpty) {
    paths.addAll(_defaultRoots.where((d) => Directory(d).existsSync()));
    if (paths.isEmpty) {
      stderr.writeln('no conventional root directory found (see --help)');
      exit(64);
    }
  }

  final dryRun = opts.flag('dry-run');
  final result = await Sanitizer(
    skips: opts.multiOption('skip').toSet(),
    excludes: opts.multiOption('exclude'),
    dryRun: dryRun,
    skipGenerated: !opts.flag('include-generated'),
  ).run(paths);
  for (final file in result.files) {
    stdout.writeln(file.path);
    for (final line in file.converted) {
      stdout.writeln('  $line');
    }
  }
  for (final entry in result.skippedBelowFloor.entries) {
    stderr.writeln(
      'warning: skipped ${entry.value} file(s) at language version '
      '${entry.key} — dot shorthands need 3.10. Raise `environment: sdk:` in '
      "that package's pubspec.yaml; the installed SDK does not decide this.",
    );
  }
  final skipped = result.skippedByList;
  final removed = result.removedImportCount;
  final verb = dryRun ? 'would convert' : 'converted';
  final pruneVerb = dryRun ? 'would prune' : 'pruned';
  stdout.writeln(
    '$verb ${result.convertedCount} site(s) in ${result.files.length} file(s)'
    '${skipped > 0 ? ', $skipped skip-listed' : ''}'
    '${removed > 0 ? ', $pruneVerb $removed orphaned import(s)' : ''}',
  );
}
