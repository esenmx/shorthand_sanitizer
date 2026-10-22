part of 'sanitizer.dart';

String? _cachedSdkPath;

/// Locates the Dart SDK for the analyzer, or null when none is found. A set
/// `DART_SDK` decides alone: null when it names no SDK, never a silent
/// fallback to another one. Unset, inside a JIT run the executable lives in
/// the SDK; an AOT-compiled binary does not, so fall back to the `dart` on
/// PATH (`which`, or `where` on Windows; following the Flutter shim, whose SDK
/// sits under `bin/cache/dart-sdk`). `package:cli_util`'s `sdkPath` is the
/// resolvedExecutable step alone — no validity check, no AOT or shim
/// fallback — so it cannot replace this.
String? sdkPath() {
  if (_cachedSdkPath != null) return _cachedSdkPath;

  final env = Platform.environment['DART_SDK'];
  if (env != null) return _isDartSdk(env) ? _cachedSdkPath = env : null;

  final exeSdk = p.dirname(p.dirname(Platform.resolvedExecutable));
  if (_isDartSdk(exeSdk)) return _cachedSdkPath = exeSdk;

  final which = _dartOnPath();
  if (which == null) return null;
  final String resolved;
  try {
    resolved = File(which).resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
  final bin = p.dirname(resolved);
  for (final candidate in [p.join(bin, 'cache', 'dart-sdk'), p.dirname(bin)]) {
    if (_isDartSdk(candidate)) return _cachedSdkPath = candidate;
  }
  return null;
}

/// Whether [dir] is a Dart SDK: it holds `version` and `lib/_internal`.
bool _isDartSdk(String dir) =>
    File(p.join(dir, 'version')).existsSync() &&
    Directory(p.join(dir, 'lib', '_internal')).existsSync();

/// `where` lists every match, with CRLF line endings.
String? _dartOnPath() {
  final ProcessResult lookup;
  try {
    lookup = Process.runSync(Platform.isWindows ? 'where' : 'which', ['dart']);
  } on ProcessException {
    return null;
  }
  if (lookup.exitCode != 0) return null;
  for (final line in LineSplitter.split(lookup.stdout.toString())) {
    if (line.trim() case final path when path.isNotEmpty) return path;
  }
  return null;
}

/// Linked element models — the SDK's, every package's, every on-disk
/// library's — persist across runs under the user's cache home
/// (`~/Library/Caches`, `$XDG_CACHE_HOME`, `%LOCALAPPDATA%`), at most
/// 64 MiB on disk, least recently used evicted first.
///
/// Only `.unlinked2`, `.linked`, and `.linked.digest` keys are retained:
/// `AnalysisDriver` also emits `.resolved` / `.resolved2` error+index bundles
/// for `getErrors` and `getIndex`, which `dotsan` never calls. While
/// [_SanitizerByteStore.speculative] is true (during in-memory overlay
/// verification or ephemeral temp-dir runs), new entries stay in the memory
/// tier only so transient candidate waves, bisections, pre-prune states,
/// `--dry-run` overlays, and test fixtures never write to the disk cache.
_SanitizerByteStore _createByteStore() => _sharedByteStore ??= _initByteStore();

_SanitizerByteStore? _sharedByteStore;

_SanitizerByteStore _initByteStore() {
  // cli_util knows no cache home elsewhere and throws an Error for it.
  if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
    return .new(null);
  }
  try {
    final dir = BaseDirectories('dotsan').cacheHome;
    Directory(dir).createSync(recursive: true);
    return .new(EvictingFileByteStore(dir, _maxDiskCacheBytes));
  } on Exception {
    return .new(null);
  }
}

const int _maxDiskCacheBytes = 64 << 20;
const int _maxMemoryCacheBytes = 128 << 20;

final class _SanitizerByteStore(final ByteStore? _disk) implements ByteStore {
  final _memory = MemoryCachingByteStore(NullByteStore(), _maxMemoryCacheBytes);

  /// When true, [putGet] caches only in [_memory] and skips [_disk].
  bool speculative = false;

  static bool _isRetainedKey(String key) =>
      key.endsWith('.unlinked2') ||
      key.endsWith('.linked') ||
      key.endsWith('.linked.digest');

  @override
  Uint8List? get(String key) {
    if (!_isRetainedKey(key)) return null;
    if (_memory.get(key) case final cached?) return cached;
    if (_disk?.get(key) case final fromDisk?) {
      _memory.putGet(key, fromDisk);
      return fromDisk;
    }
    return null;
  }

  @override
  Uint8List putGet(String key, Uint8List bytes) {
    if (!_isRetainedKey(key)) return bytes;
    _memory.putGet(key, bytes);
    if (!speculative) {
      _disk?.putGet(key, bytes);
    }
    return bytes;
  }

  @override
  void release(Iterable<String> keys) {}
}
