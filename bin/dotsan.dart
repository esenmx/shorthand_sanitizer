import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:cli_util/cli_logging.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:shorthand_sanitizer/shorthand_sanitizer.dart';

const _version = '0.11.1';

const _defaultRoots = [
  'lib',
  'bin',
  'test',
  'example',
  'tool',
  'integration_test',
  'benchmark',
];

/// Exit code when a file the run should have processed was skipped.
const _skippedExit = 65;

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
      help:
          'Keep the listed members prefixed (Type.member, prefix.Type.member '
          'or member).',
    )
    ..addMultiOption(
      'exclude',
      valueHelp: 'glob,glob',
      help:
          'Leave matching files alone. A glob with a / matches the path '
          'relative to the working directory (lib/legacy/**), one without '
          'the file name (firebase_options.dart).',
    )
    ..addFlag(
      'analyzer-excludes',
      defaultsTo: true,
      help:
          'Leave alone files matching the `analyzer: exclude:` globs of '
          "their own package's analysis_options.yaml (a parent package's "
          'excludes never reach a nested package).',
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
      help:
          'Also list every site left prefixed, with the reason, each '
          'generated file skipped, and the Dart SDK used.',
    )
    ..addFlag(
      'set-exit-if-changed',
      negatable: false,
      help: 'Exit 1 if any site was converted (or, with --dry-run, would be).',
    )
    ..addOption(
      'format',
      allowed: ['text', 'json'],
      defaultsTo: 'text',
      help: 'Report format on stdout.',
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
orphaned. Files whose leading comment declares them generated are skipped and
counted; directory walks skip hidden directories and each package's build/.
Default paths: every conventional root directory that exists
(${_defaultRoots.join(', ')}).

Exit codes: 0 done; 1 --set-exit-if-changed and a site converted; 64 usage
error; 65 a file was skipped (analysis errors, language version below 3.10,
no package config, orphan part, unreadable directory); 69 no Dart SDK; 74 a
file could not be written.''';
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

  // Padding around the commas of a list is formatting, not part of a name.
  final skips = [for (final entry in opts.multiOption('skip')) entry.trim()];
  final usageErrors = [
    for (final path in opts.rest)
      switch (FileSystemEntity.typeSync(path)) {
        .notFound => 'no such file or directory: $path',
        .file when !path.endsWith('.dart') => 'not a .dart file: $path',
        _ => null,
      },
    for (final pattern in opts.multiOption('exclude')) _globError(pattern),
    for (final entry in skips) _skipError(entry),
  ].nonNulls.toList();
  if (usageErrors.isNotEmpty) {
    usageErrors.forEach(stderr.writeln);
    exitCode = 64;
    return;
  }

  final paths = [...opts.rest];
  if (paths.isEmpty) {
    paths.addAll(_discoverDefaultRoots());
    if (paths.isEmpty) {
      stderr.writeln('no conventional root directory found (see --help)');
      exit(64);
    }
  }

  final sdk = sdkPath();
  if (sdk == null) {
    stderr.writeln(switch (Platform.environment['DART_SDK']) {
      final env? =>
        'DART_SDK is set to $env, which is not a Dart SDK directory (no '
            '`version` file or `lib/_internal`): fix or unset it',
      null => 'could not locate the Dart SDK: set DART_SDK to its directory',
    });
    exitCode = 69;
    return;
  }

  final explain = opts.flag('explain');
  if (explain) {
    final version = File(p.join(sdk, 'version')).readAsStringSync().trim();
    stderr.writeln('note: using Dart SDK $sdk ($version)');
  }

  final dryRun = opts.flag('dry-run');
  final json = opts.option('format') == 'json';
  // Piped stdout is the parseable report; the non-ANSI Progress fallback
  // prints its message there, so the spinner is TTY-only — and never over
  // JSON, which stays pure even on a terminal.
  final progress = !json && stdout.hasTerminal
      ? Logger.standard().progress('analyzing')
      : null;
  final result = await Sanitizer(
    skips: skips.toSet(),
    excludes: opts.multiOption('exclude'),
    dryRun: dryRun,
    skipGenerated: !opts.flag('include-generated'),
    explain: explain,
    allowErrors: opts.flag('allow-errors'),
    analyzerExcludes: opts.flag('analyzer-excludes'),
  ).run(paths);
  progress?.finish(showTiming: true);
  if (!json) {
    for (final file in result.files) {
      stdout.writeln(_display(file.path));
      for (final line in [
        ...file.converted,
        ...file.kept,
        for (final pruned in file.prunedImports) pruned.description,
      ]) {
        stdout.writeln('  $line');
      }
    }
  }
  _warn(result, named: _namedFiles(opts.rest), explain: explain);
  if (json) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(_json(result, dryRun)),
    );
  } else {
    final changed = result.files
        .where((f) => f.converted.isNotEmpty || f.removedImports > 0)
        .length;
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
  // Not exit(): it can cut off a large report still being flushed.
  exitCode = switch (result) {
    _ when result.writeFailures.isNotEmpty => 74,
    _ when result.hasSkips => _skippedExit,
    _ when opts.flag('set-exit-if-changed') && result.convertedCount > 0 => 1,
    _ => 0,
  };
}

/// Canonical paths of the files named on the command line.
Set<String> _namedFiles(List<String> rest) => {
  for (final path in rest)
    if (FileSystemEntity.isFileSync(path)) p.normalize(p.absolute(path)),
};

/// Existing conventional roots in the current directory and under any Pub
/// workspace members declared in `pubspec.yaml`.
List<String> _discoverDefaultRoots() {
  final roots = [
    for (final d in _defaultRoots)
      if (Directory(d).existsSync()) d,
  ];
  for (final member in _workspaceMembers()) {
    for (final d in _defaultRoots) {
      final candidate = p.normalize(p.join(member, d));
      if (Directory(candidate).existsSync() &&
          !roots.any(
            (r) => p.equals(r, candidate) || p.isWithin(r, candidate),
          )) {
        roots.add(candidate);
      }
    }
  }
  return roots;
}

Iterable<String> _workspaceMembers() sync* {
  final pubspec = File('pubspec.yaml');
  if (!pubspec.existsSync()) return;
  final String text;
  try {
    text = pubspec.readAsStringSync();
  } on FileSystemException {
    return;
  }
  var inWorkspace = false;
  for (final raw in LineSplitter.split(text)) {
    final line = raw.replaceFirst(RegExp('#.*'), '').trimRight();
    if (line.trim().isEmpty) continue;
    if (!inWorkspace) {
      if (RegExp(r'^workspace:\s*$').hasMatch(line)) inWorkspace = true;
      continue;
    }
    if (RegExp(r'^\s+-\s+(.+)$').firstMatch(line) case final m?) {
      var entry = m.group(1)?.trim() ?? '';
      if ((entry.startsWith('"') && entry.endsWith('"')) ||
          (entry.startsWith("'") && entry.endsWith("'"))) {
        entry = entry.substring(1, entry.length - 1);
      }
      if (entry.isNotEmpty) yield entry;
    } else if (!line.startsWith(' ') && !line.startsWith('\t')) {
      inWorkspace = false;
    }
  }
}

/// Everything the run left undone or unmatched, on stderr. A file [named] on
/// the command line and left alone is a request not met, so it is named too.
void _warn(
  SanitizeResult result, {
  required Set<String> named,
  required bool explain,
}) {
  final ansi = Ansi(
    stderr.supportsAnsiEscapes && stdioType(stderr) == .terminal,
  );
  void warn(String message) =>
      stderr.writeln('${ansi.yellow}warning:${ansi.none} $message');
  void list(Iterable<String> paths) {
    for (final path in paths) {
      stderr.writeln('  ${_display(path)}');
    }
  }

  for (final path in result.skippedGenerated.where(named.contains)) {
    warn(
      'skipped ${_display(path)}: generated (its header says so); '
      '--include-generated processes it',
    );
  }
  for (final (:path, :reason) in result.excluded) {
    if (!named.contains(path)) continue;
    final hint = reason.startsWith('excluded by')
        ? '; --no-analyzer-excludes processes it'
        : '';
    warn('skipped ${_display(path)}: $reason$hint');
  }
  if (result.skippedGenerated.isNotEmpty) {
    stderr.writeln(
      'note: skipped ${result.skippedGenerated.length} generated file(s) '
      '(--include-generated processes them)${explain ? ':' : ''}',
    );
    if (explain) list(result.skippedGenerated);
  }
  for (final MapEntry(key: (:root, :version), value: n)
      in result.skippedBelowFloor.entries) {
    warn(
      'skipped $n file(s) in ${_display(root)} at language version $version '
      '— dot shorthands need 3.10. Raise `environment: sdk:` in '
      '${p.join(_display(root), 'pubspec.yaml')} (or drop a `// @dart=` '
      'override); the installed SDK does not decide this.',
    );
  }
  for (final MapEntry(key: root, value: n)
      in result.skippedUnconfigured.entries) {
    warn(
      'skipped $n file(s) in ${_display(root)}: no package config entry — '
      'run `dart pub get` there first.',
    );
  }
  if (result.skippedWithErrors.isNotEmpty) {
    warn(
      'skipped ${result.skippedWithErrors.length} file(s) whose library '
      'already has analysis errors (fix them or pass --allow-errors):',
    );
    list(result.skippedWithErrors);
  }
  if (result.skippedOrphanParts.isNotEmpty) {
    warn(
      'skipped ${result.skippedOrphanParts.length} part file(s) whose '
      '`part of` library does not exist:',
    );
    list(result.skippedOrphanParts);
  }
  for (final (:path, :error) in result.unreadableDirectories) {
    warn(
      'could not read ${_display(path)} ($error); none of its files were '
      'processed.',
    );
  }
  for (final entry in result.unmatchedSkips) {
    warn('--skip entry "$entry" matched no site');
  }
  for (final pattern in result.unmatchedExcludes) {
    final anchor = pattern.contains('/')
        ? ' (a glob with a / is relative to the working directory, '
              '${p.current})'
        : '';
    warn('--exclude "$pattern" matched no file$anchor');
  }
  for (final (:file, :path, :error) in result.writeFailures) {
    stderr.writeln(
      '${ansi.red}error:${ansi.none} could not write ${_display(path)} '
      '($error), so ${_display(file)} was not converted.',
    );
  }
}

/// The `--format=json` document; its schema is in the README.
Map<String, Object?> _json(SanitizeResult result, bool dryRun) => {
  'dryRun': dryRun,
  'converted': result.convertedCount,
  'kept': result.keptCount,
  'skipListed': result.skippedByList,
  'removedImports': result.removedImportCount,
  'files': [
    for (final file in result.files)
      {
        'path': _display(file.path),
        'removedImports': file.removedImports,
        'prunedImports': [
          for (final pruned in file.prunedImports)
            {
              'line': pruned.line,
              'uri': pruned.uri,
              'replacement': pruned.replacement,
              'deletedComment': pruned.deletedComment,
              'keptComment': pruned.keptComment,
            },
        ],
        'sites': [
          for (final site in file.sites)
            {
              'line': site.line,
              'column': site.column,
              'before': site.before,
              'after': site.after,
              'keptReason': site.keptReason,
            },
        ],
      },
  ],
  'skippedWithErrors': [
    for (final path in result.skippedWithErrors) _display(path),
  ],
  'skippedBelowFloor': [
    for (final MapEntry(key: (:root, :version), value: n)
        in result.skippedBelowFloor.entries)
      {'root': _display(root), 'version': version, 'files': n},
  ],
  'skippedUnconfigured': [
    for (final MapEntry(key: root, value: n)
        in result.skippedUnconfigured.entries)
      {'root': _display(root), 'files': n},
  ],
  'skippedOrphanParts': [
    for (final path in result.skippedOrphanParts) _display(path),
  ],
  'unreadableDirectories': [
    for (final (:path, :error) in result.unreadableDirectories)
      {'path': _display(path), 'error': error},
  ],
  'skippedGenerated': [
    for (final path in result.skippedGenerated) _display(path),
  ],
  'writeFailures': [
    for (final (:file, :path, :error) in result.writeFailures)
      {'file': _display(file), 'path': _display(path), 'error': error},
  ],
  'unmatchedSkips': [...result.unmatchedSkips],
  'unmatchedExcludes': [...result.unmatchedExcludes],
};

String? _globError(String pattern) {
  try {
    Glob(pattern);
    return null;
  } on FormatException catch (e) {
    return 'invalid --exclude glob "$pattern": ${e.message}';
  }
}

String? _skipError(String entry) => Sanitizer.isSkipEntry(entry)
    ? null
    : 'invalid --skip entry "$entry": expected Type.member, '
          'prefix.Type.member or member';

String _display(String path) {
  final absolute = p.normalize(p.absolute(path));
  if (p.equals(absolute, p.current)) return '.';
  return p.isWithin(p.current, absolute) ? p.relative(absolute) : absolute;
}
