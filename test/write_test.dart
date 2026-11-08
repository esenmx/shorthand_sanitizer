import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:shorthand_sanitizer/shorthand_sanitizer.dart';
import 'package:shorthand_sanitizer/src/sanitizer.dart' show replaceFiles;
import 'package:test/test.dart';

import 'helpers.dart';

const _lib = '''
part 'sub/p.dart';
enum Fit { a, b }
Fit f() => Fit.a;
''';
const _part = '''
part of '../main.dart';
Fit g() => Fit.b;
''';

const _site = 'enum Fit { a }\nFit f() => Fit.a;\n';

/// The permission bits of [path], as `ls -l` would show them.
String _mode(String path) =>
    (FileStat.statSync(path).mode & 0xFFF).toRadixString(8);

/// The numeric group of [path].
String _group(String path) => Process.runSync('ls', [
  '-ldn',
  path,
]).stdout.toString().trim().split(RegExp(r'\s+'))[3];

void _chmod(String mode, String path) {
  final run = Process.runSync('chmod', [mode, path]);
  if (run.exitCode != 0) throw StateError('chmod failed: ${run.stderr}');
}

Directory _partLibrary(String name, {String part = _part}) =>
    fixture(name, {'lib/main.dart': _lib, 'lib/sub/p.dart': part});

/// Every file under [dir] that is not a source, a pubspec or pub's own.
List<String> _strays(Directory dir) => [
  for (final entity in dir.listSync(recursive: true))
    if (entity is File &&
        !p.isWithin(p.join(dir.path, '.dart_tool'), entity.path) &&
        !const {
          'main.dart',
          'p.dart',
          'pubspec.yaml',
          'pubspec.lock',
        }.contains(p.basename(entity.path)))
      entity.path,
];

void main() {
  group('a failure while writing changes no original', () {
    test('a file-size limit kills the run before any unit is replaced', () {
      final dir = _partLibrary(
        'write_ulimit',
        part: _part + '// ${'x' * 70}\n' * 7700,
      );
      final main = File(p.join(dir.path, 'lib', 'main.dart'));
      final part = File(p.join(dir.path, 'lib', 'sub', 'p.dart'));
      final mainBefore = main.readAsBytesSync();
      final partBefore = part.readAsBytesSync();
      check(partBefore.length).isGreaterThan(500000);

      ProcessResult limited(List<String> args) => Process.runSync('sh', [
        '-c',
        r'ulimit -f 200; exec "$@"',
        'sh',
        Platform.resolvedExecutable,
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        p.absolute('bin/shorthand.dart'),
        ...args,
      ], workingDirectory: dir.path);

      // Only the rewrite can hit the limit: analysis alone stays under it.
      final control = limited(['-n', 'lib']);
      check(because: '${control.stderr}', control.exitCode).equals(0);
      check(control.stdout as String)
          .endsWith('would convert 2 site(s) in 2 file(s)\n');

      final run = limited(['lib']);

      check(because: '${run.stderr}', run.exitCode).not((it) => it.equals(0));
      check(main.readAsBytesSync()).deepEquals(mainBefore);
      check(part.readAsBytesSync()).deepEquals(partBefore);

      // SIGXFSZ lands just after the write fails, so cleanup may or may not
      // finish first: any sibling left must be one no run reads.
      for (final stray in _strays(dir)) {
        check(p.basename(stray))
          ..startsWith('.')
          ..matchesPattern(RegExp(r'\.shorthand-(tmp|backup)$'));
      }

      final retry = shorthand(['lib'], cwd: dir.path);
      check(because: '${retry.stderr}', retry.exitCode).equals(0);
      check(main.readAsStringSync()).contains('Fit f() => .a;');
      check(part.readAsStringSync()).contains('Fit g() => .b;');
    }, testOn: '!windows');

    test('a directory refusing the temp file leaves every unit alone', () {
      final dir = _partLibrary('write_dir');
      final main = File(p.join(dir.path, 'lib', 'main.dart'));
      final part = File(p.join(dir.path, 'lib', 'sub', 'p.dart'));
      _chmod('555', part.parent.path);
      addTearDown(() => _chmod('755', part.parent.path));

      final run = shorthand(['lib'], cwd: dir.path);

      check(because: '${run.stderr}', run.exitCode).equals(74);
      check(run.stderr as String).contains('could not write');
      check(run.stdout as String).equals('converted 0 site(s) in 0 file(s)\n');
      check(main.readAsStringSync()).equals(_lib);
      check(part.readAsStringSync()).equals(_part);
      check(_strays(dir)).isEmpty();
    }, testOn: '!windows');
  });

  group('a failing rename', () {
    /// A rename that refuses its [failAt]th call (1-based) and, with
    /// [restoreToo], every call after it.
    void Function(String, String) failingRename(
      int failAt, {
      bool restoreToo = false,
    }) {
      var calls = 0;
      return (from, to) {
        calls++;
        if (calls == failAt || (restoreToo && calls > failAt)) {
          throw FileSystemException('refused', to, const OSError('refused'));
        }
        File(from).renameSync(to);
      };
    }

    ({File first, File second, Directory dir}) units() {
      final dir = tempDir('write_rename');
      return (
        first: File(p.join(dir.path, 'first.dart'))
          ..writeAsBytesSync([0xEF, 0xBB, 0xBF, 0x61]),
        second: File(p.join(dir.path, 'second.dart'))
          ..writeAsStringSync('second'),
        dir: dir,
      );
    }

    test('restores the units already replaced and leaves no sibling', () {
      final (:first, :second, :dir) = units();
      if (!Platform.isWindows) _chmod('640', first.path);

      final failure = replaceFiles({
        first.path: (analyzed: 'a', text: 'new first'),
        second.path: (analyzed: 'second', text: 'new second'),
      }, rename: failingRename(2));

      check(failure).isNotNull().equals((path: second.path, error: 'refused'));
      check(first.readAsBytesSync()).deepEquals([0xEF, 0xBB, 0xBF, 0x61]);
      if (!Platform.isWindows) check(_mode(first.path)).equals('640');
      check(second.readAsStringSync()).equals('second');
      check(dir.listSync().map((e) => p.basename(e.path)).toSet())
          .deepEquals({'first.dart', 'second.dart'});
    });

    test('names a unit it could not restore and keeps its original', () {
      final (:first, :second, :dir) = units();

      final stranded = replaceFiles({
        first.path: (analyzed: 'a', text: 'new first'),
        second.path: (analyzed: 'second', text: 'new second'),
      }, rename: failingRename(2, restoreToo: true));

      final firstReal = first.resolveSymbolicLinksSync();
      check(stranded?.error).isNotNull()
        ..startsWith('refused; could not restore $firstReal (original kept at')
        ..contains('.shorthand-backup');
      check(first.readAsBytesSync())
          .deepEquals([0xEF, 0xBB, 0xBF, ...utf8.encode('new first')]);
      check(second.readAsStringSync()).equals('second');
      final kept = [
        for (final e in dir.listSync())
          if (p.basename(e.path).endsWith('.shorthand-backup')) e,
      ];
      check(kept).length.equals(1);
      check(File(kept.single.path).readAsBytesSync())
          .deepEquals([0xEF, 0xBB, 0xBF, 0x61]);
    });

    test('a file edited to invalid bytes counts as changed, not a crash', () {
      final (:first, :second, dir: _) = units();
      second.writeAsBytesSync([0xE9]);

      final failure = replaceFiles({
        first.path: (analyzed: 'a', text: 'new first'),
        second.path: (analyzed: 'second', text: 'new second'),
      });

      check(failure).isNotNull().equals((
        path: second.path,
        error: 'changed on disk since it was analyzed',
      ));
      check(second.readAsBytesSync()).deepEquals([0xE9]);
    });

    test('a file changed since analysis stops the whole library', () {
      final (:first, :second, :dir) = units();
      second.writeAsStringSync('second, edited');

      final failure = replaceFiles({
        first.path: (analyzed: 'a', text: 'new first'),
        second.path: (analyzed: 'second', text: 'new second'),
      });

      check(failure).isNotNull().equals((
        path: second.path,
        error: 'changed on disk since it was analyzed',
      ));
      check(first.readAsBytesSync()).deepEquals([0xEF, 0xBB, 0xBF, 0x61]);
      check(second.readAsStringSync()).equals('second, edited');
      check(dir.listSync().map((e) => p.basename(e.path)).toSet())
          .deepEquals({'first.dart', 'second.dart'});
    });
  });

  group('a file changed during a run', () {
    /// Runs `shorthand lib/a.dart` and calls [change] while analysis, having
    /// read a.dart, is blocked reading its import from a pipe.
    Future<({int exit, String errors, File file})> runChanging(
      void Function(File file) change,
    ) async {
      final dir = fixture('write_edit', {
        'lib/a.dart': "import 'dep.dart';\nFit f() => Fit.a;\n",
      });
      final file = File(p.join(dir.path, 'lib', 'a.dart'));
      final dep = p.join(dir.path, 'lib', 'dep.dart');
      final mkfifo = Process.runSync('mkfifo', [dep]);
      check(because: '${mkfifo.stderr}', mkfifo.exitCode).equals(0);
      addTearDown(() => File(dep).deleteSync());

      final run = await Process.start(Platform.resolvedExecutable, [
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        p.absolute('bin/shorthand.dart'),
        p.join('lib', 'a.dart'),
      ], workingDirectory: dir.path);
      addTearDown(run.kill);
      final errors = run.stderr.transform(utf8.decoder).join();
      run.stdout.drain<void>().ignore();

      // The open returns only once the run is reading the pipe. It blocks in a
      // child because an open blocked in this VM could hang the VM's exit.
      final writer = await Process.start('sh', [
        '-c',
        r'exec 3>"$1"; echo open; read -r _; echo "enum Fit { a }" >&3',
        'sh',
        dep,
      ]);
      addTearDown(writer.kill);
      final opened = await writer.stdout
          .transform(utf8.decoder)
          .first
          .timeout(const .new(seconds: 90));
      check(opened.trim()).equals('open');

      change(file);
      writer.stdin.writeln('go');
      await writer.stdin.close();

      final exit = await run.exitCode.timeout(const .new(seconds: 90));
      return (exit: exit, errors: await errors, file: file);
    }

    const changing = Timeout(Duration(minutes: 4));

    test(
      'an edit survives it, and the run exits 74',
      () async {
        const edited = "import 'dep.dart';\nFit f() => Fit.a;\n// saved\n";
        final (:exit, :errors, :file) = await runChanging(
          (file) => file.writeAsStringSync(edited),
        );
        check(because: errors, exit).equals(74);
        check(errors).contains('changed on disk since it was analyzed');
        check(file.readAsStringSync()).equals(edited);
      },
      testOn: '!windows',
      timeout: changing,
    );

    test(
      'an edit to invalid bytes survives it, and the run exits 74',
      () async {
        const edited = [0x2F, 0x2F, 0xE9, 0x0A];
        final (:exit, :errors, :file) = await runChanging(
          (file) => file.writeAsBytesSync(edited),
        );
        check(because: errors, exit).equals(74);
        check(errors).contains('changed on disk since it was analyzed');
        check(file.readAsBytesSync()).deepEquals(edited);
      },
      testOn: '!windows',
      timeout: changing,
    );

    test(
      'a deleted file stays deleted, and the run exits 74',
      () async {
        final (:exit, :errors, :file) = await runChanging(
          (file) => file.deleteSync(),
        );
        check(because: errors, exit).equals(74);
        check(errors).contains('changed on disk since it was analyzed');
        check(file.existsSync()).isFalse();
      },
      testOn: '!windows',
      timeout: changing,
    );
  });

  group('staging', () {
    test('a kill while staging a backup leaves no backup to restore', () {
      final dir = fixture('write_kill_staging', {'lib/a.dart': _site});
      final file = File(p.join(dir.path, 'lib', 'a.dart'));
      final original = 'enum Fit { a }\n${'// padding\n' * 200}';
      file.writeAsStringSync(original);
      write(dir, 'kill.dart', '''
import 'dart:io';
import 'package:shorthand_sanitizer/src/sanitizer.dart';

void main(List<String> args) {
  var writes = 0;
  replaceFiles({
    args[0]: (analyzed: File(args[0]).readAsStringSync(), text: 'new'),
  }, write: (path, bytes) {
    if (++writes == 2) {
      File(path).writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2), flush: true);
      Process.killPid(pid, ProcessSignal.sigkill);
      sleep(const Duration(minutes: 1));
    }
    File(path).writeAsBytesSync(bytes, flush: true);
  });
}
''');
      final killed = Process.runSync(Platform.resolvedExecutable, [
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        p.join(dir.path, 'kill.dart'),
        file.path,
      ]);
      check(
        because: '${killed.stderr}',
        killed.exitCode,
      ).not((it) => it.equals(0));

      check(file.readAsStringSync()).equals(original);
      final names = [
        for (final e in file.parent.listSync()) p.basename(e.path),
      ];
      check(names.where((n) => n.endsWith('.shorthand-backup'))).isEmpty();
      check(names.where((n) => n.endsWith('.shorthand-tmp'))).length.equals(2);
    }, testOn: '!windows');

    test('a stale backup is never overwritten by a reused pid', () {
      final dir = tempDir('write_stale');
      final file = File(p.join(dir.path, 'a.dart'))..writeAsStringSync('old');
      final stale = [
        for (var serial = 0; serial < 2000; serial++)
          File(p.join(dir.path, '.a.dart.$pid.$serial.shorthand-backup'))
            ..writeAsStringSync('stale'),
      ];

      check(replaceFiles({file.path: (analyzed: 'old', text: 'new')})).isNull();

      check(file.readAsStringSync()).equals('new');
      for (final backup in stale) {
        check(backup.readAsStringSync()).equals('stale');
      }
    });

    for (final (mode, private) in [
      ('600', '600'),
      ('640', '640'),
      ('4755', '755'),
    ]) {
      test('mode $mode: text lands on a file already mode $private', () {
        final dir = tempDir('write_private');
        final file = File(p.join(dir.path, 'a.dart'))..writeAsStringSync('old');
        _chmod(mode, file.path);
        final seen = <String>[];

        final failure = replaceFiles(
          {file.path: (analyzed: 'old', text: 'new')},
          write: (path, bytes) {
            seen.add(_mode(path));
            File(path).writeAsBytesSync(bytes, flush: true);
          },
        );

        check(failure).isNull();
        check(seen).deepEquals([private, private]);
        check(_mode(file.path)).equals(mode);
      }, testOn: '!windows');
    }

    test('a read-only file is refused, though a rename would replace it', () {
      final dir = tempDir('write_read_only');
      final file = File(p.join(dir.path, 'a.dart'))..writeAsStringSync('old');
      _chmod('444', file.path);
      addTearDown(() => _chmod('644', file.path));

      final failure = replaceFiles({file.path: (analyzed: 'old', text: 'new')});

      check(failure).isNotNull().has((f) => f.path, 'path').equals(file.path);
      check(file.readAsStringSync()).equals('old');
      check(dir.listSync().map((e) => p.basename(e.path)))
          .deepEquals(['a.dart']);
    }, testOn: '!windows');

    test('a file this user may not write is refused, whatever its mode', () {
      final dir = tempDir('write_acl');
      final file = File(p.join(dir.path, 'a.dart'))..writeAsStringSync('old');
      final user = Platform.environment['USER'];
      final deny = Process.runSync('chmod', [
        '+a',
        '$user deny write',
        file.path,
      ]);
      check(because: '${deny.stderr}', deny.exitCode).equals(0);

      final failure = replaceFiles({file.path: (analyzed: 'old', text: 'new')});

      check(failure).isNotNull().has((f) => f.path, 'path').equals(file.path);
      check(file.readAsStringSync()).equals('old');
      check(dir.listSync().map((e) => p.basename(e.path)))
          .deepEquals(['a.dart']);
    }, testOn: 'mac-os');

    test('a read-only file is refused before anything is staged', () {
      final dir = tempDir('write_read_only_seam');
      final file = File(p.join(dir.path, 'a.dart'))..writeAsStringSync('old');
      _chmod('444', file.path);
      addTearDown(() => _chmod('644', file.path));

      final failure = replaceFiles({
        file.path: (analyzed: 'old', text: 'new'),
      }, write: (path, bytes) {});

      check(failure).isNotNull().has((f) => f.path, 'path').equals(file.path);
      check(file.readAsStringSync()).equals('old');
    }, testOn: '!windows');

    group("a file's group", () {
      /// A group this user can set that a new file in [dir] does not get, or
      /// null when this user has only one.
      String? otherGroup(Directory dir) {
        final probe = File(p.join(dir.path, 'probe'))..createSync();
        final own = _group(probe.path);
        probe.deleteSync();
        final groups = Process.runSync('id', ['-G']).stdout.toString();
        for (final group in groups.trim().split(RegExp(r'\s+'))) {
          if (group == own) continue;
          if (Process.runSync('chgrp', [group, dir.path]).exitCode == 0) {
            Process.runSync('chgrp', [own, dir.path]);
            return group;
          }
        }
        return null;
      }

      /// A directory holding a `chgrp` that always fails, for PATH.
      String failingChgrp() {
        final bin = tempDir('fake_chgrp');
        final chgrp = File(p.join(bin.path, 'chgrp'))
          ..writeAsStringSync('#!/bin/sh\nexit 1\n');
        _chmod('755', chgrp.path);
        return '${bin.path}:${Platform.environment['PATH']}';
      }

      test('lands on every sibling before the text does', () {
        final dir = tempDir('write_group');
        final group = otherGroup(dir);
        if (group == null) {
          markTestSkipped('this user has only one group');
          return;
        }
        final file = File(p.join(dir.path, 'a.dart'))..writeAsStringSync('old');
        Process.runSync('chgrp', [group, file.path]);
        _chmod('640', file.path);
        final seen = <String>[];

        final failure = replaceFiles(
          {file.path: (analyzed: 'old', text: 'new')},
          write: (path, bytes) {
            seen.add(_group(path));
            File(path).writeAsBytesSync(bytes, flush: true);
          },
        );

        check(failure).isNull();
        check(seen).deepEquals([group, group]);
        check(file.readAsStringSync()).equals('new');
        check(_group(file.path)).equals(group);
        check(_mode(file.path)).equals('640');
      });

      Directory groupFixture(String name, String group, String mode) {
        final dir = fixture(name, {'lib/a.dart': _site});
        final file = p.join(dir.path, 'lib', 'a.dart');
        Process.runSync('chgrp', [group, file]);
        _chmod(mode, file);
        return dir;
      }

      test('that cannot be kept stops the write when it has access', () {
        final probe = tempDir('write_group_probe');
        final group = otherGroup(probe);
        if (group == null) {
          markTestSkipped('this user has only one group');
          return;
        }
        final dir = groupFixture('write_group_refused', group, '640');
        final file = p.join(dir.path, 'lib', 'a.dart');

        final run = shorthand(
          [p.join('lib', 'a.dart')],
          cwd: dir.path,
          environment: {'PATH': failingChgrp()},
        );

        check(because: '${run.stderr}', run.exitCode).equals(74);
        check(run.stderr as String).contains('could not keep its group');
        check(File(file).readAsStringSync()).equals(_site);
        check(_group(file)).equals(group);
      });

      test('that cannot be kept is given up when it has no access', () {
        final probe = tempDir('write_group_probe');
        final group = otherGroup(probe);
        if (group == null) {
          markTestSkipped('this user has only one group');
          return;
        }
        final dir = groupFixture('write_group_given_up', group, '600');
        final file = p.join(dir.path, 'lib', 'a.dart');

        final run = shorthand(
          [p.join('lib', 'a.dart')],
          cwd: dir.path,
          environment: {'PATH': failingChgrp()},
        );

        check(because: '${run.stderr}', run.exitCode).equals(0);
        check(File(file).readAsStringSync()).contains('Fit f() => .a;');
        check(_mode(file)).equals('600');
      });
    }, testOn: '!windows');

    test('a deleted file is reported and not created', () {
      final dir = tempDir('write_deleted');
      final file = File(p.join(dir.path, 'a.dart'));

      final failure = replaceFiles({file.path: (analyzed: 'old', text: 'new')});

      check(failure).isNotNull().equals((
        path: file.path,
        error: 'changed on disk since it was analyzed',
      ));
      check(file.existsSync()).isFalse();
      check(dir.listSync()).isEmpty();
    });
  });

  group('a run killed between renames', () {
    const fit = 'enum Fit { a }\n';
    const sink = "import 'fit.dart';\nvoid take(Fit f) {}\n";
    const main = "import 'fit.dart';\nimport 'sink.dart';\npart 'p.dart';\n";
    const part = "part of 'main.dart';\nvoid run() => take(Fit.a);\n";

    /// The first of two renames lands, then SIGKILL: `main.dart` has lost the
    /// import `p.dart` still needs, and no `finally` runs.
    Directory killedAfterFirstRename() {
      final dir = fixture('write_kill', {
        'lib/fit.dart': fit,
        'lib/sink.dart': sink,
        'lib/main.dart': main,
        'lib/p.dart': part,
      });
      write(dir, 'kill.dart', r'''
import 'dart:io';
import 'package:shorthand_sanitizer/src/sanitizer.dart';

void main(List<String> args) {
  var renames = 0;
  replaceFiles({
    args[0]: (
      analyzed: File(args[0]).readAsStringSync(),
      text: "import 'sink.dart';\npart 'p.dart';\n",
    ),
    args[1]: (
      analyzed: File(args[1]).readAsStringSync(),
      text: "part of 'main.dart';\nvoid run() => take(.a);\n",
    ),
  }, rename: (from, to) {
    if (++renames == 2) {
      Process.killPid(pid, ProcessSignal.sigkill);
      sleep(const Duration(minutes: 1));
    }
    File(from).renameSync(to);
  });
}
''');
      _chmod('640', p.join(dir.path, 'lib', 'main.dart'));
      final killed = Process.runSync(Platform.resolvedExecutable, [
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        p.join(dir.path, 'kill.dart'),
        p.join(dir.path, 'lib', 'main.dart'),
        p.join(dir.path, 'lib', 'p.dart'),
      ]);
      check(
        because: '${killed.stderr}',
        killed.exitCode,
      ).not((it) => it.equals(0));
      return dir;
    }

    Iterable<File> ending(Directory dir, String suffix) =>
        Directory(p.join(dir.path, 'lib'))
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith(suffix));

    test('leaves the only copy of an original in a named backup', () {
      final dir = killedAfterFirstRename();

      final mainFile = File(p.join(dir.path, 'lib', 'main.dart'));
      check(mainFile.readAsStringSync()).not((it) => it.equals(main));
      check([
        for (final backup in ending(dir, '.shorthand-backup'))
          backup.readAsStringSync(),
      ]).unorderedEquals([main, part]);
      check([
        for (final fresh in ending(dir, '.shorthand-tmp'))
          fresh.readAsStringSync(),
      ]).unorderedEquals(["part of 'main.dart';\nvoid run() => take(.a);\n"]);

      final rerun = shorthand(['lib'], cwd: dir.path);
      check(because: '${rerun.stderr}', rerun.exitCode).equals(65);
      check(mainFile.readAsStringSync()).not((it) => it.equals(main));
    }, testOn: '!windows');

    test('recovers as documented: move each backup over its file', () {
      final dir = killedAfterFirstRename();

      for (final backup in ending(dir, '.shorthand-backup')) {
        final name = RegExp(r'^\.(.+)\.\d+\.\d+\.shorthand-backup$')
            .firstMatch(p.basename(backup.path))
            ?.group(1);
        check(name).isNotNull();
        backup.renameSync(p.join(p.dirname(backup.path), '$name'));
      }
      for (final fresh in ending(dir, '.shorthand-tmp')) {
        fresh.deleteSync();
      }

      final mainFile = File(p.join(dir.path, 'lib', 'main.dart'));
      final partFile = File(p.join(dir.path, 'lib', 'p.dart'));
      check(mainFile.readAsStringSync()).equals(main);
      check(partFile.readAsStringSync()).equals(part);
      check(_mode(mainFile.path)).equals('640');

      final rerun = shorthand(['lib'], cwd: dir.path);
      check(because: '${rerun.stderr}', rerun.exitCode).equals(0);
      check(partFile.readAsStringSync()).contains('take(.a)');
    }, testOn: '!windows');

    for (final (doc, name, keep) in [
      (
        'README.md',
        '`.<file>.<pid>.<n>.shorthand-backup`',
        'keep it until you have checked',
      ),
      (
        'skills/shorthand-sanitizer-usage/SKILL.md',
        '`.*.shorthand-backup`',
        'never remove one unchecked',
      ),
    ]) {
      test('$doc says a backup is complete and kept until checked', () {
        final text = File(doc)
            .readAsStringSync()
            .replaceAll(RegExp(r'\s+'), ' ');
        check(text)
          ..contains("$name always holds a file's complete original bytes")
          ..contains(keep)
          ..contains('Run `dart analyze` first');
      });
    }
  });

  group('a rewrite keeps the file itself', () {
    for (final mode in ['755', '600', '664', '640', '4755', '2755']) {
      test('mode $mode survives', () async {
        final dir = fixture('write_mode', {'lib/a.dart': _site});
        final file = p.join(dir.path, 'lib', 'a.dart');
        _chmod(mode, file);

        final result = await Sanitizer().run([file]);

        check(result.writeFailures).isEmpty();
        check(File(file).readAsStringSync()).contains('Fit f() => .a;');
        check(_mode(file)).equals(mode);
      }, testOn: '!windows');
    }

    test('a symlink stays one, and its target takes the write', () async {
      final dir = fixture('write_link', {'store/real.dart': _site});
      final real = p.join(dir.path, 'store', 'real.dart');
      final link = Link(p.join(dir.path, 'lib', 'a.dart'))
        ..createSync(real, recursive: true);

      final result = await Sanitizer().run([link.path]);

      check(result.writeFailures).isEmpty();
      check(FileSystemEntity.isLinkSync(link.path)).isTrue();
      check(link.targetSync()).equals(real);
      check(File(real).readAsStringSync()).contains('Fit f() => .a;');
      check(Directory(p.dirname(link.path)).listSync().map((e) => e.path))
          .deepEquals([link.path]);
    }, testOn: '!windows');

    test('a successful run leaves no sibling behind', () async {
      final dir = _partLibrary('write_clean');

      final result = await Sanitizer().run([p.join(dir.path, 'lib')]);

      check(result.convertedCount).equals(2);
      check(_strays(dir)).isEmpty();
    });
  });
}
