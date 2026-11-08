part of 'sanitizer.dart';

var _siblingSerial = 0;

const _utf8Bom = [0xEF, 0xBB, 0xBF];

/// Octal 7777: `st_mode` without its file-type bits.
const _permissionBits = 0xFFF;

/// Octal 777: read, write and execute, without setuid, setgid and sticky.
const _accessBits = 0x1FF;

/// Octal 070: what the file's group may do.
const _groupBits = 0x38;

/// A file being staged, or new text no run reads: never the only copy of
/// anything, so a killed run's are safe to delete.
const _stagingSuffix = 'shorthand-tmp';

/// A file's complete original bytes: the name is taken only once they are all
/// on disk, and after a kill this can be the only copy left.
const _backupSuffix = 'shorthand-backup';

const _changedOnDisk = 'changed on disk since it was analyzed';

/// Replaces each file of [units] (path to the text the run analyzed and its
/// new text) or none of them. A symlink is written through to its target; the
/// original's mode, setuid, setgid and sticky included, group and UTF-8 BOM are
/// kept; a group this user cannot set is refused when the mode gives it access,
/// and given up when it gives none. A file that is gone or whose content no
/// longer matches `analyzed` was changed during the run, so nothing is
/// replaced. A file this user may not write (another owner, an ACL) is refused
/// too: a rename would replace it regardless.
///
/// Each new text and each original's bytes go to hidden sibling files first, so
/// a failure while writing touches no original, and undoing a replacement is
/// one more rename, which a full disk cannot fail. Returns the file that failed
/// and why, or null when every file was replaced. A process killed while this
/// runs leaves its sibling files behind, and between renames leaves some files
/// replaced: each rename is atomic, the set is not, and a backup can then be
/// the only copy of an original. An edit in the instant between the check and
/// the rename is still lost.
({String path, String error})? replaceFiles(
  Map<String, ({String analyzed, String text})> units, {
  void Function(String from, String to) rename = _rename,
  void Function(String path, List<int> bytes) write = _write,
}) {
  final siblings = <String>{};
  String stage(String target, int mode, String group, List<int> bytes) {
    final sibling = _createSibling(target);
    siblings.add(sibling);
    _matchGroup(sibling, group, mode);
    _matchMode(sibling, (mode & _accessBits) | 0x80);
    write(sibling, bytes);
    _matchMode(sibling, mode);
    return sibling;
  }

  String stageBackup(String target, int mode, String group, List<int> bytes) {
    final staging = stage(target, mode, group, bytes);
    final backup = _backupOf(staging);
    File(staging).renameSync(backup);
    siblings.add(backup);
    return backup;
  }

  final staged =
      <
        ({
          String path,
          String target,
          String analyzed,
          String fresh,
          String backup,
        })
      >[];
  final replaced = <({String target, String backup})>[];
  var current = '';
  try {
    for (final MapEntry(key: path, value: (:analyzed, :text))
        in units.entries) {
      current = path;
      if (!File(path).existsSync()) {
        return (path: path, error: _changedOnDisk);
      }
      final target = File(path).resolveSymbolicLinksSync();
      final original = File(target).readAsBytesSync();
      File(target).openSync(mode: .append).closeSync();
      if (original.isNotEmpty && File(target).lengthSync() == 0) {
        _deleteIfPresent(target);
        return (path: path, error: _changedOnDisk);
      }
      final mode = FileStat.statSync(target).mode & _permissionBits;
      final group = _groupOf(target);
      final encoded = [
        if (_hasBom(original)) ..._utf8Bom,
        ...utf8.encode(text),
      ];
      staged.add((
        path: path,
        target: target,
        analyzed: analyzed,
        fresh: stage(target, mode, group, encoded),
        backup: stageBackup(target, mode, group, original),
      ));
    }
    for (final (:path, :target, :analyzed, fresh: _, backup: _) in staged) {
      current = path;
      final onDisk = File(target).readAsBytesSync();
      if (utf8.decode(onDisk, allowMalformed: true) != analyzed) {
        return (path: path, error: _changedOnDisk);
      }
    }
    for (final (:path, :target, analyzed: _, :fresh, :backup) in staged) {
      current = path;
      rename(fresh, target);
      replaced.add((target: target, backup: backup));
    }
    return null;
  } on FileSystemException catch (e) {
    final reason = e.osError?.message ?? e.message;
    final stranded = <String>[];
    for (final (:target, :backup) in replaced.reversed) {
      try {
        rename(backup, target);
      } on FileSystemException {
        siblings.remove(backup);
        stranded.add('$target (original kept at $backup)');
      }
    }
    return (
      path: current,
      error: stranded.isEmpty
          ? reason
          : '$reason; could not restore ${stranded.join(', ')}',
    );
  } finally {
    siblings.forEach(_deleteIfPresent);
  }
}

void _rename(String from, String to) => File(from).renameSync(to);

void _write(String path, List<int> bytes) =>
    File(path).writeAsBytesSync(bytes, flush: true);

String _backupOf(String staging) => p.setExtension(staging, '.$_backupSuffix');

bool _hasBom(List<int> bytes) =>
    bytes.length >= _utf8Bom.length &&
    bytes[0] == _utf8Bom[0] &&
    bytes[1] == _utf8Bom[1] &&
    bytes[2] == _utf8Bom[2];

/// An empty hidden file beside [target]. Never named `*.dart`: one a killed run
/// leaves behind must not be collected as a source by the next run. A reused
/// pid must not overwrite a backup a killed run left, so that name stays free.
String _createSibling(String target) {
  final name = '.${p.basename(target)}.$pid';
  while (true) {
    final sibling = p.join(
      p.dirname(target),
      '$name.${_siblingSerial++}.$_stagingSuffix',
    );
    if (File(_backupOf(sibling)).existsSync()) continue;
    try {
      File(sibling).createSync(exclusive: true);
      return sibling;
    } on PathExistsException {
      continue;
    }
  }
}

/// Staging calls this twice. Before the content lands, so a private file's text
/// is never readable under the default mode; after it, because a write clears
/// setuid and setgid. dart:io has no chmod.
void _matchMode(String path, int mode) {
  if (Platform.isWindows) return;
  int current() => FileStat.statSync(path).mode & _permissionBits;
  if (current() == mode) return;
  final ProcessResult chmod;
  try {
    chmod = Process.runSync('chmod', [mode.toRadixString(8), path]);
  } on ProcessException catch (e) {
    throw FileSystemException('could not run chmod: ${e.message}', path);
  }
  if (chmod.exitCode != 0) {
    throw FileSystemException('chmod failed: ${chmod.stderr}', path);
  }
  if (current() != mode) {
    throw FileSystemException(
      'could not set mode ${mode.toRadixString(8)}',
      path,
    );
  }
}

/// The numeric group of [path]; empty on Windows. dart:io exposes none.
String _groupOf(String path) {
  if (Platform.isWindows) return '';
  final ProcessResult ls;
  try {
    ls = Process.runSync('ls', ['-ldn', path]);
  } on ProcessException catch (e) {
    throw FileSystemException('could not run ls: ${e.message}', path);
  }
  final fields = ls.stdout.toString().trim().split(RegExp(r'\s+'));
  if (ls.exitCode != 0 || fields.length < 4) {
    throw FileSystemException('could not read the group: ${ls.stderr}', path);
  }
  return fields[3];
}

/// Runs before the content lands: a rename keeps the sibling's group, which
/// would otherwise open the text to whichever group the directory gives it.
void _matchGroup(String path, String group, int mode) {
  if (Platform.isWindows || _groupOf(path) == group) return;
  ProcessResult? chgrp;
  try {
    chgrp = Process.runSync('chgrp', [group, path]);
  } on ProcessException {
    chgrp = null;
  }
  if (mode & _groupBits != 0 &&
      (chgrp == null || chgrp.exitCode != 0 || _groupOf(path) != group)) {
    throw FileSystemException('could not keep its group $group', path);
  }
}

void _deleteIfPresent(String path) {
  try {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // Cleanup must not mask the outcome the caller is about to report.
  }
}
