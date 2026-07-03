import 'dart:io';

import 'package:shorthand_sanitizer/shorthand_sanitizer.dart';

const _version = '0.2.0';

const _usage =
    'Usage: dotsan [paths...] [options]\n'
    '  --dry-run | -n              report without writing\n'
    '  --skip=Type.member,member   keep listed members prefixed\n'
    '  --exclude=glob,glob         leave matching files alone\n'
    '                              (firebase_options.dart, **/legacy/**)\n'
    '  --include-generated         also rewrite generated-marked files\n'
    '  --version                   print version\n'
    'Rewrites Type.member to dot-shorthand .member wherever the rewrite\n'
    'provably resolves to the same element, then prunes any import the\n'
    'dropped Type prefix orphaned. Files whose leading comment declares\n'
    'them generated are skipped. Default path: lib';

Future<void> main(List<String> args) async {
  final paths = <String>[];
  var dryRun = false;
  var skipGenerated = true;
  final skips = <String>{};
  final excludes = <String>[];
  for (final a in args) {
    if (a == '--dry-run' || a == '-n') {
      dryRun = true;
    } else if (a.startsWith('--skip=')) {
      skips.addAll(a.substring(7).split(',').where((s) => s.isNotEmpty));
    } else if (a.startsWith('--exclude=')) {
      excludes.addAll(a.substring(10).split(',').where((s) => s.isNotEmpty));
    } else if (a == '--include-generated') {
      skipGenerated = false;
    } else if (a == '--version') {
      stdout.writeln('dotsan $_version');
      return;
    } else if (a == '--help' || a == '-h') {
      stdout.writeln(_usage);
      return;
    } else if (a.startsWith('-')) {
      stderr.writeln('unknown option: $a (see --help)');
      exit(64);
    } else {
      paths.add(a);
    }
  }
  if (paths.isEmpty) paths.add('lib');

  final result = await Sanitizer(
    skips: skips,
    excludes: excludes,
    dryRun: dryRun,
    skipGenerated: skipGenerated,
  ).run(paths);
  for (final file in result.files) {
    stdout.writeln(file.path);
    for (final line in file.converted) {
      stdout.writeln('  $line');
    }
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
