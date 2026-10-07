// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_process/test_process.dart';

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
      write(p.join('lib', 'a.dart'), ['void a() {', '  print(1);', '}']);
      write(p.join('lib', 'b.dart'), [
        '// Comment.',
        'void b() {',
        '  print(2);',
        '}',
      ]);
      write(p.join('test', 't.dart'), ['void main() {}']);
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

    Future<TestProcess> run(List<String> args) => TestProcess.start(
      Platform.resolvedExecutable,
      [script, '--in=coverage.json', '--base-directory=.', ...args],
      workingDirectory: packageDir,
    );

    test('adds the files that match any of the patterns', () async {
      final process = await run([
        '--lcov',
        '--include-uncovered=${p.posix.join('lib', 'b.dart')}',
        '--include-uncovered=${p.posix.join('test', '*.dart')}',
      ]);

      await process.shouldExit(0);
      expect(
        await process.stdout.rest
            .where((line) => line.startsWith('SF:'))
            .toList(),
        [
          'SF:${p.join('lib', 'a.dart')}',
          'SF:${p.join('lib', 'b.dart')}',
          'SF:${p.join('test', 't.dart')}',
        ],
      );
    });

    test('is not supported with --bazel', () async {
      final process = await run([
        '--lcov',
        '--bazel',
        '--include-uncovered=**',
      ]);

      await expectLater(
        process.stdout,
        emitsThrough(
          contains('--include-uncovered is not supported with --bazel'),
        ),
      );
      await process.shouldExit(1);
    });

    test('is not supported with function or branch output', () async {
      for (final flag in ['--pretty-print-func', '--pretty-print-branch']) {
        final process = await run([flag, '--include-uncovered=**']);

        await expectLater(
          process.stdout,
          emitsThrough(
            contains(
              '--include-uncovered is not supported with --pretty-print-func '
              'or --pretty-print-branch',
            ),
          ),
        );
        await process.shouldExit(1);
      }
    });
  });
}
