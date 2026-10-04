// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../bin/format_coverage.dart';

void main() {
  late Directory testDir;
  setUp(() {
    testDir = Directory.systemTemp.createTempSync('coverage_test_temp');
  });

  tearDown(() async {
    if (testDir.existsSync()) testDir.deleteSync(recursive: true);
  });

  test('considers all json files', () async {
    final fileA = File(p.join(testDir.path, 'coverage_a.json'));
    fileA.createSync();
    final fileB = File(p.join(testDir.path, 'coverage_b.json'));
    fileB.createSync();
    final fileC = File(p.join(testDir.path, 'not_coverage.foo'));
    fileC.createSync();

    final files = filesToProcess(testDir.path);
    expect(files.length, equals(2));
    expect(
      files.map((f) => f.path),
      containsAll([endsWith('coverage_a.json'), endsWith('coverage_b.json')]),
    );
  });

  group('include-uncovered', tags: ['integration'], () {
    final script = p.absolute('bin', 'format_coverage.dart');

    late String packageDir;

    void write(String relativePath, List<String> lines) {
      File(p.join(packageDir, relativePath))
        ..createSync(recursive: true)
        ..writeAsStringSync('${lines.join('\n')}\n');
    }

    setUp(() {
      packageDir = testDir.resolveSymbolicLinksSync();
      write('lib/a.dart', ['void a() {', '  print(1);', '}']);
      write('lib/b.dart', ['// Comment.', 'void b() {', '  print(2);', '}']);
      write('lib/c.g.dart', ['void c() {}']);
      write('lib/d.dart', ['// coverage:ignore-file', 'void d() {}']);
      write('test/t.dart', ['void main() {}']);
      // Only lib/a.dart has coverage data.
      File(p.join(packageDir, 'coverage.json')).writeAsStringSync(
        jsonEncode({
          'coverage': [
            {
              'source': Uri.file(
                p.join(packageDir, 'lib', 'a.dart'),
              ).toString(),
              'hits': [2, 3],
            },
          ],
        }),
      );
    });

    Future<ProcessResult> run(List<String> args) => Process.run(
      Platform.resolvedExecutable,
      [script, '--in=coverage.json', '--base-directory=.', ...args],
      workingDirectory: packageDir,
    );

    test('reports only the files with coverage data by default', () async {
      final result = await run(['--lcov']);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        result.stdout,
        'SF:${p.join('lib', 'a.dart')}\n'
        'DA:2,3\n'
        'LF:1\n'
        'LH:1\n'
        'end_of_record\n',
      );
    });

    test('adds the matching files to the lcov output', () async {
      final result = await run([
        '--lcov',
        '--include-uncovered=lib/**',
        '--ignore-files=lib/*.g.dart',
      ]);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        result.stdout,
        'SF:${p.join('lib', 'a.dart')}\n'
        'DA:2,3\n'
        'LF:1\n'
        'LH:1\n'
        'end_of_record\n'
        'SF:${p.join('lib', 'b.dart')}\n'
        'DA:2,0\n'
        'DA:3,0\n'
        'DA:4,0\n'
        'LF:3\n'
        'LH:0\n'
        'end_of_record\n'
        'SF:${p.join('lib', 'd.dart')}\n'
        'DA:2,0\n'
        'LF:1\n'
        'LH:0\n'
        'end_of_record\n',
      );
    });

    test('adds the files that match any of the patterns', () async {
      final result = await run([
        '--lcov',
        '--include-uncovered=lib/b.dart',
        '--include-uncovered=test/*.dart',
      ]);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        (result.stdout as String).split('\n').where((l) => l.startsWith('SF:')),
        [
          'SF:${p.join('lib', 'a.dart')}',
          'SF:${p.join('lib', 'b.dart')}',
          'SF:${p.join('test', 't.dart')}',
        ],
      );
    });

    test('applies the ignore comments with --check-ignore', () async {
      final result = await run([
        '--lcov',
        '--check-ignore',
        '--include-uncovered=lib/*.dart',
      ]);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        (result.stdout as String).split('\n').where((l) => l.startsWith('SF:')),
        [
          'SF:${p.join('lib', 'a.dart')}',
          'SF:${p.join('lib', 'b.dart')}',
          'SF:${p.join('lib', 'c.g.dart')}',
        ],
      );
    });

    test('adds the matching files to the pretty print output', () async {
      final result = await run([
        '--pretty-print',
        '--check-ignore',
        '--include-uncovered=lib/b.dart',
        '--include-uncovered=lib/d.dart',
      ]);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        result.stdout,
        '${p.join(packageDir, 'lib', 'a.dart')}\n'
        '       |void a() {\n'
        '      3|  print(1);\n'
        '       |}\n'
        '${p.join(packageDir, 'lib', 'b.dart')}\n'
        '       |// Comment.\n'
        '      0|void b() {\n'
        '      0|  print(2);\n'
        '      0|}\n',
      );
    });

    test('is not supported with --bazel', () async {
      final result = await run(['--lcov', '--bazel', '--include-uncovered=**']);

      expect(result.exitCode, 1);
      expect(
        result.stdout,
        contains('--include-uncovered is not supported with --bazel'),
      );
    });
  });
}
