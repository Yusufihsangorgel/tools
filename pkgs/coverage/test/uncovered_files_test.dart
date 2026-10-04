// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:coverage/coverage.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A package with one file that has coverage data, `lib/covered.dart`, and
/// several files that don't, see [_createPackage].
late String _root;
late Resolver _resolver;

/// Turns the `/` separated [relativePath] into a path with the separators of
/// the platform, like the ones in the output.
String _native(String relativePath) => p.joinAll(p.posix.split(relativePath));

String _file(String relativePath) => p.join(_root, _native(relativePath));

/// A glob for [relativePattern] below the root of the package. A glob matches
/// the paths of the platform with `/` as the separator.
String _glob(String relativePattern) =>
    '${_root.replaceAll(r'\', '/')}/$relativePattern';

String _uri(String relativePath) => Uri.file(_file(relativePath)).toString();

void _write(String relativePath, List<String> lines) {
  File(_file(relativePath))
    ..createSync(recursive: true)
    ..writeAsStringSync('${lines.join('\n')}\n');
}

Future<void> _createPackage() async {
  _root = Directory.systemTemp
      .createTempSync('uncovered_files_test')
      .resolveSymbolicLinksSync();
  _write('lib/covered.dart', ['void covered() {', "  print('covered');", '}']);
  _write('lib/uncovered.dart', [
    '// Header comment.', // 1
    "import 'dart:io';", // 2
    '', // 3
    '/// Doc comment.', // 4
    'class Foo {', // 5
    '  // Indented comment.', // 6
    '  final int x = 1; // trailing comment', // 7
    '  ', // 8
    '  /* block comment */', // 9
    '}', // 10
  ]);
  _write('lib/src/inner.dart', [
    "const url = 'http://example.invalid';", // 1
    '// Comment.', // 2
    'int inner() => 1;', // 3
  ]);
  _write('lib/generated.g.dart', ['int generated() => 1;']);
  _write('lib/comments_only.dart', ['// Only a comment.', '', '   ']);
  _write('lib/ignored_file.dart', [
    '// coverage:ignore-file',
    'int ignored() => 1;',
  ]);
  _write('lib/partly.dart', [
    'int a() => 1;', // 1
    '// coverage:ignore-start', // 2
    'int b() => 2;', // 3
    '// coverage:ignore-end', // 4
    'int c() => 3; // coverage:ignore-line', // 5
    'int d() => 4;', // 6
  ]);
  _write('lib/readme.md', ['int notDart() => 1;']);
  _write('test/uncovered_test.dart', ['void main() {}']);
  _write('.dart_tool/hidden.dart', ['int hidden() => 1;']);
  _resolver = await Resolver.create(packagePath: _root);
}

/// The coverage data of `lib/covered.dart`.
Map<String, HitMap> _hitMaps() => {
  _uri('lib/covered.dart'): HitMap({2: 5}),
};

/// The `SF:` entries of [lcov].
List<String> _sources(String lcov) => [
  for (final line in lcov.split('\n'))
    if (line.startsWith('SF:')) line.substring(3),
];

/// The lcov record of [source], including the `SF:` and `end_of_record` lines.
String _record(String lcov, String source) {
  final start = lcov.indexOf('SF:$source\n');
  expect(start, isNonNegative, reason: '$source is not in\n$lcov');
  const end = 'end_of_record\n';
  return lcov.substring(start, lcov.indexOf(end, start) + end.length);
}

String _lcov({
  bool Function(String path)? includeUncovered,
  List<String>? reportOn,
  Set<Glob>? ignoreGlobs,
  bool checkIgnoredLines = false,
}) => _hitMaps().formatLcov(
  _resolver,
  basePath: _root,
  reportOn: reportOn,
  ignoreGlobs: ignoreGlobs,
  includeUncovered: includeUncovered,
  checkIgnoredLines: checkIgnoredLines,
);

void main() {
  setUpAll(_createPackage);

  tearDownAll(() {
    Directory(_root).deleteSync(recursive: true);
  });

  group('formatLcov', () {
    test('reports only the files with coverage data by default', () {
      expect(
        _lcov(),
        'SF:${_native('lib/covered.dart')}\n'
        'DA:2,5\n'
        'LF:1\n'
        'LH:1\n'
        'end_of_record\n',
      );
    });

    test('includes the uncovered files that includeUncovered accepts', () {
      final lcov = _lcov(includeUncovered: (_) => true);

      // The files without coverage data come after the others, sorted by path.
      // `lib/comments_only.dart` has no line that is not a comment, and
      // `.dart_tool/hidden.dart` is in a hidden directory.
      expect(_sources(lcov), [
        _native('lib/covered.dart'),
        _native('lib/generated.g.dart'),
        _native('lib/ignored_file.dart'),
        _native('lib/partly.dart'),
        _native('lib/src/inner.dart'),
        _native('lib/uncovered.dart'),
        _native('test/uncovered_test.dart'),
      ]);
      expect(
        _record(lcov, _native('lib/covered.dart')),
        'SF:${_native('lib/covered.dart')}\n'
        'DA:2,5\n'
        'LF:1\n'
        'LH:1\n'
        'end_of_record\n',
      );
      expect(
        _record(lcov, _native('lib/uncovered.dart')),
        'SF:${_native('lib/uncovered.dart')}\n'
        'DA:2,0\n'
        'DA:5,0\n'
        'DA:7,0\n'
        'DA:9,0\n'
        'DA:10,0\n'
        'LF:5\n'
        'LH:0\n'
        'end_of_record\n',
      );
      expect(
        _record(lcov, _native('lib/src/inner.dart')),
        'SF:${_native('lib/src/inner.dart')}\n'
        'DA:1,0\n'
        'DA:3,0\n'
        'LF:2\n'
        'LH:0\n'
        'end_of_record\n',
      );
    });

    test('limits the uncovered files like the files with coverage data', () {
      final lcov = _lcov(
        includeUncovered: (_) => true,
        reportOn: [_file('lib')],
        ignoreGlobs: {
          Glob(_glob('**/*.g.dart')),
          Glob(_glob('lib/ignored_file.dart')),
        },
      );

      expect(_sources(lcov), [
        _native('lib/covered.dart'),
        _native('lib/partly.dart'),
        _native('lib/src/inner.dart'),
        _native('lib/uncovered.dart'),
      ]);
    });

    test('applies the ignore comments to the uncovered files only when '
        'asked to', () {
      bool inLib(String path) => p.isWithin(_file('lib'), path);

      final lcov = _lcov(includeUncovered: inLib);
      expect(
        _record(lcov, _native('lib/partly.dart')),
        'SF:${_native('lib/partly.dart')}\n'
        'DA:1,0\nDA:3,0\nDA:5,0\nDA:6,0\n'
        'LF:4\nLH:0\nend_of_record\n',
      );
      expect(_sources(lcov), contains(_native('lib/ignored_file.dart')));

      final checked = _lcov(includeUncovered: inLib, checkIgnoredLines: true);
      expect(
        _record(checked, _native('lib/partly.dart')),
        'SF:${_native('lib/partly.dart')}\n'
        'DA:1,0\nDA:6,0\nLF:2\nLH:0\nend_of_record\n',
      );
      expect(
        _sources(checked),
        isNot(contains(_native('lib/ignored_file.dart'))),
      );
    });

    test('requires a package path to find the uncovered files', () async {
      final resolver = await Resolver.create();

      expect(() => _hitMaps().formatLcov(resolver), returnsNormally);
      expect(
        () => _hitMaps().formatLcov(resolver, includeUncovered: (_) => true),
        throwsStateError,
      );
    });
  });

  group('prettyPrint', () {
    test('does not report the uncovered files with function or branch '
        'coverage', () async {
      final hitMaps = {
        _uri('lib/covered.dart'): HitMap(
          {2: 5},
          {1: 1},
          {1: 'covered'},
          {2: 3},
        ),
      };

      expect(
        await hitMaps.prettyPrint(
          _resolver,
          Loader(),
          reportFuncs: true,
          includeUncovered: (_) => true,
        ),
        '${_file('lib/covered.dart')}\n'
        '      1|void covered() {\n'
        "       |  print('covered');\n"
        '       |}\n',
      );
      expect(
        await hitMaps.prettyPrint(
          _resolver,
          Loader(),
          reportBranches: true,
          includeUncovered: (_) => true,
        ),
        '${_file('lib/covered.dart')}\n'
        '       |void covered() {\n'
        "      3|  print('covered');\n"
        '       |}\n',
      );
    });
  });
}
