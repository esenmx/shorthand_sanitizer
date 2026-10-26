part of 'sanitizer.dart';

/// Absolute and normalized, case kept: `p.canonicalize` lowercases on
/// Windows, where package-config roots keep their case.
String _canonical(String path) => p.normalize(p.absolute(path));

final _realCache = <String, String>{};

/// [path] with symlinks resolved, for deciding membership only: a path
/// through a link (macOS `/tmp` and `/var` are links) and the real one must
/// match, while reports keep the path as given.
String _real(String path) {
  if (_realCache[path] case final cached?) return cached;
  try {
    return _realCache[path] = File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}

/// Which package a file belongs to, and whether the analyzer was handed that
/// package's own config. One per [Sanitizer.run]; lookups are memoised.
final class _PackageGate() {
  final _roots = <String, String?>{};
  final _configs = <String, PackageConfig?>{};

  String? rootOf(String file) =>
      _rootOfDir(p.dirname(file)) ?? _rootOfDir(p.dirname(_real(file)));

  String? _rootOfDir(String dir) {
    if (_roots.containsKey(dir)) return _roots[dir];
    final parent = p.dirname(dir);
    return _roots[dir] = switch (dir) {
      _ when File(p.join(dir, 'pubspec.yaml')).existsSync() => dir,
      _ when parent == dir => null,
      _ => _rootOfDir(parent),
    };
  }

  /// Whether [c]'s package config has an entry whose root is [root] and
  /// which holds [file]. A nested package without its own config joins the
  /// enclosing package's context, whose config attributes the file to the
  /// enclosing package — so a config merely existing proves nothing.
  Future<bool> isConfigured(AnalysisContext c, String file, String root) async {
    final packagesFile = c.contextRoot.packagesFile;
    if (packagesFile == null) return false;
    final config = await _configOf(packagesFile.path);
    final pkg =
        config?.packageOf(.file(file)) ?? config?.packageOf(.file(_real(file)));
    return pkg != null &&
        (p.equals(_canonical(p.fromUri(pkg.root)), root) ||
            p.equals(_real(p.fromUri(pkg.root)), _real(root)));
  }

  Future<PackageConfig?> _configOf(String path) async {
    if (_configs.containsKey(path)) return _configs[path];
    try {
      return _configs[path] = await loadPackageConfig(File(path));
    } on Exception {
      return _configs[path] = null;
    }
  }
}

/// Canonical paths of the files under [paths], each once, sorted. Files
/// left alone — excluded, generated — and unreadable directories are
/// recorded in [result]. When [gitRealPaths] is provided, only files in that
/// set are collected.
List<String> _collectFiles(
  List<String> paths,
  String? Function(String path) excludedBy,
  SanitizeResult result, {
  required bool skipGenerated,
  Set<String>? gitRealPaths,
}) {
  // Keyed by real path: one file reached through a symlink and directly
  // is still one file.
  final files = <String, String>{};
  final seen = <String>{};
  void consider(String path) {
    final canon = _canonical(path);
    final resolved = _real(canon);
    if (!seen.add(resolved)) return;
    if (excludedBy(canon) case final reason?) {
      if (gitRealPaths == null || gitRealPaths.contains(resolved)) {
        result.excluded.add((path: canon, reason: reason));
      }
    } else if (gitRealPaths != null && !gitRealPaths.contains(resolved)) {
      return;
    } else if (skipGenerated && _isGeneratedFile(canon)) {
      result.skippedGenerated.add(canon);
    } else {
      files.putIfAbsent(resolved, () => canon);
    }
  }

  for (final rootPath in paths) {
    if (FileSystemEntity.isFileSync(rootPath)) {
      consider(rootPath);
      continue;
    }

    final dirQueue = <Directory>[.new(rootPath)];
    while (dirQueue.isNotEmpty) {
      final dir = dirQueue.removeLast();
      final List<FileSystemEntity> entities;
      try {
        entities = dir.listSync(followLinks: false);
      } on FileSystemException catch (e) {
        result.unreadableDirectories.add((
          path: _canonical(dir.path),
          error: e.osError?.message ?? e.message,
        ));
        continue;
      }
      // A package's own build output, not a `build/` directory of sources.
      final isPackageRoot = File(p.join(dir.path, 'pubspec.yaml')).existsSync();
      for (final entity in entities) {
        final base = p.basename(entity.path);
        if (entity is Directory) {
          if (base.startsWith('.') || (isPackageRoot && base == 'build')) {
            continue;
          }
          dirQueue.add(entity);
        } else if (entity is File && entity.path.endsWith('.dart')) {
          consider(entity.path);
        }
      }
    }
  }
  return files.values.toList()..sort();
}

/// Discovers `.dart` files modified, staged, or untracked in git (or changed
/// since [since] when non-null) across the repositories containing [paths],
/// returning their `_real(...)` paths.
///
/// Throws a [StateError] when a target path is not inside a git repository or
/// a git command fails, or an [ArgumentError] when [since] is not a valid git
/// revision.
Set<String> _discoverGitChangedFiles({
  required List<String> paths,
  String? since,
}) {
  if (since != null && (since.isEmpty || since.startsWith('-'))) {
    throw ArgumentError.value(since, 'since', 'unknown git revision "$since"');
  }
  final probeTargets = paths.isEmpty ? [p.current] : paths;
  final repoRoots = <String>{};
  for (final target in probeTargets) {
    final canon = _canonical(target);
    final dir = FileSystemEntity.isDirectorySync(canon)
        ? canon
        : p.dirname(canon);
    final ProcessResult top;
    try {
      top = Process.runSync('git', ['-C', dir, 'rev-parse', '--show-toplevel']);
    } on ProcessException catch (e) {
      throw StateError('could not run git: ${e.message}');
    }
    if (top.exitCode != 0) {
      throw StateError('not a git repository: $target');
    }
    repoRoots.add(_canonical(top.stdout.toString().trim()));
  }

  final realPaths = <String>{};
  for (final repoRoot in repoRoots) {
    if (since != null) {
      final verify = Process.runSync('git', [
        '-C',
        repoRoot,
        'rev-parse',
        '--verify',
        '--end-of-options',
        '$since^{commit}',
      ]);
      if (verify.exitCode != 0) {
        throw ArgumentError.value(
          since,
          'since',
          'unknown git revision "$since"',
        );
      }
    }

    final commands = [
      if (since != null) ...[
        [
          '-C',
          repoRoot,
          'diff',
          '--name-only',
          '-z',
          '--diff-filter=ACMR',
          '--end-of-options',
          since,
          '--',
        ],
        ['-C', repoRoot, 'ls-files', '-z', '--others', '--exclude-standard'],
      ] else ...[
        [
          '-C',
          repoRoot,
          'ls-files',
          '-z',
          '--modified',
          '--others',
          '--exclude-standard',
        ],
        [
          '-C',
          repoRoot,
          'diff',
          '--name-only',
          '-z',
          '--cached',
          '--diff-filter=ACMR',
        ],
      ],
    ];

    for (final args in commands) {
      final r = Process.runSync('git', args);
      if (r.exitCode != 0) {
        throw StateError('git failed: ${r.stderr.toString().trim()}');
      }
      for (final rel in r.stdout.toString().split('\x00')) {
        if (rel.isEmpty || !rel.endsWith('.dart')) continue;
        final full = _canonical(p.join(repoRoot, rel));
        if (File(full).existsSync()) {
          realPaths.add(_real(full));
        }
      }
    }
  }
  return realPaths;
}
