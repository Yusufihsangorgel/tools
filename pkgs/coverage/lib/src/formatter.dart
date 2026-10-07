// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'hitmap.dart';
import 'resolver.dart';
import 'util.dart';

@Deprecated('Migrate to FileHitMapsFormatter')
abstract class Formatter {
  /// Returns the formatted coverage data.
  Future<String> format(Map<String, Map<int, int>> hitmap);
}

/// Converts the given hitmap to lcov format and appends the result to
/// env.output.
///
/// Returns a [Future] that completes as soon as all map entries have been
/// emitted.
@Deprecated('Migrate to FileHitMapsFormatter.formatLcov')
class LcovFormatter implements Formatter {
  /// Creates a LCOV formatter.
  ///
  /// If [reportOn] is provided, coverage report output is limited to files
  /// prefixed with one of the paths included. If [basePath] is provided, paths
  /// are reported relative to that path.
  LcovFormatter(this.resolver, {this.reportOn, this.basePath});

  final Resolver resolver;
  final String? basePath;
  final List<String>? reportOn;

  @override
  Future<String> format(Map<String, Map<int, int>> hitmap) {
    return Future.value(
      hitmap
          .map((key, value) => MapEntry(key, HitMap(value)))
          .formatLcov(resolver, basePath: basePath, reportOn: reportOn),
    );
  }
}

/// Converts the given hitmap to a pretty-print format and appends the result
/// to env.output.
///
/// Returns a [Future] that completes as soon as all map entries have been
/// emitted.
@Deprecated('Migrate to FileHitMapsFormatter.prettyPrint')
class PrettyPrintFormatter implements Formatter {
  /// Creates a pretty-print formatter.
  ///
  /// If [reportOn] is provided, coverage report output is limited to files
  /// prefixed with one of the paths included.
  PrettyPrintFormatter(
    this.resolver,
    this.loader, {
    this.reportOn,
    this.reportFuncs = false,
  });

  final Resolver resolver;
  final Loader loader;
  final List<String>? reportOn;
  final bool reportFuncs;

  @override
  Future<String> format(Map<String, Map<int, int>> hitmap) {
    return hitmap
        .map((key, value) => MapEntry(key, HitMap(value)))
        .prettyPrint(
          resolver,
          loader,
          reportOn: reportOn,
          reportFuncs: reportFuncs,
        );
  }
}

extension FileHitMapsFormatter on Map<String, HitMap> {
  /// Converts the given hitmap to lcov format.
  ///
  /// If [reportOn] is provided, coverage report output is limited to files
  /// prefixed with one of the paths included. If [basePath] is provided, paths
  /// are reported relative to that path.
  ///
  /// If [includeUncovered] is provided, the `.dart` files below
  /// [Resolver.packagePath] that have no entry in this map are also reported
  /// when the function returns `true` for their absolute path. See
  /// [prettyPrint] for the details. Without it, only the files in this map are
  /// reported.
  String formatLcov(
    Resolver resolver, {
    String? basePath,
    List<String>? reportOn,
    Set<Glob>? ignoreGlobs,
    bool Function(String path)? includeUncovered,
    bool checkIgnoredLines = false,
  }) {
    final pathFilter = _getPathFilter(
      reportOn: reportOn,
      ignoreGlobs: ignoreGlobs,
    );
    final buf = StringBuffer();
    final files = _filesToReport(
      resolver,
      pathFilter,
      loader: Loader(),
      includeUncovered: includeUncovered,
      checkIgnoredLines: checkIgnoredLines,
    );
    for (final (resolved, v) in files) {
      final lineHits = v.lineHits;
      final funcHits = v.funcHits;
      final funcNames = v.funcNames;
      final branchHits = v.branchHits;
      var source = resolved;

      if (basePath != null) {
        source = p.relative(source, from: basePath);
      }

      buf.write('SF:$source\n');
      if (funcHits != null && funcNames != null) {
        for (final k in funcNames.keys.toList()..sort()) {
          buf.write('FN:$k,${funcNames[k]}\n');
        }
        for (final k in funcHits.keys.toList()..sort()) {
          if (funcHits[k]! != 0) {
            buf.write('FNDA:${funcHits[k]},${funcNames[k]}\n');
          }
        }
        buf.write('FNF:${funcNames.length}\n');
        buf.write('FNH:${funcHits.values.where((v) => v > 0).length}\n');
      }
      for (final k in lineHits.keys.toList()..sort()) {
        buf.write('DA:$k,${lineHits[k]}\n');
      }
      buf.write('LF:${lineHits.length}\n');
      buf.write('LH:${lineHits.values.where((v) => v > 0).length}\n');
      if (branchHits != null) {
        for (final k in branchHits.keys.toList()..sort()) {
          buf.write('BRDA:$k,0,0,${branchHits[k]}\n');
        }
      }
      buf.write('end_of_record\n');
    }

    return buf.toString();
  }

  /// Converts the given hitmap to a pretty-print format.
  ///
  /// If [reportOn] is provided, coverage report output is limited to files
  /// prefixed with one of the paths included. If [reportFuncs] is provided,
  /// only function coverage information will be shown.
  ///
  /// If [includeUncovered] is provided, the `.dart` files below
  /// [Resolver.packagePath] with no entry in this map are also reported when
  /// it returns `true` for their path, with every non-blank, non-`//` line at
  /// 0 hits (an estimate; see [_uncoveredFiles]). [checkIgnoredLines] applies
  /// `coverage:ignore-*` comments. Ignored when [reportFuncs] or
  /// [reportBranches] is set. Throws a [StateError] without a package path.
  Future<String> prettyPrint(
    Resolver resolver,
    Loader loader, {
    List<String>? reportOn,
    Set<Glob>? ignoreGlobs,
    bool reportFuncs = false,
    bool reportBranches = false,
    bool Function(String path)? includeUncovered,
    bool checkIgnoredLines = false,
  }) async {
    final pathFilter = _getPathFilter(
      reportOn: reportOn,
      ignoreGlobs: ignoreGlobs,
    );
    final buf = StringBuffer();
    final files = _filesToReport(
      resolver,
      pathFilter,
      loader: loader,
      includeUncovered: reportFuncs || reportBranches ? null : includeUncovered,
      checkIgnoredLines: checkIgnoredLines,
    );
    for (final (source, v) in files) {
      final lines = await loader.load(source);
      if (lines == null) {
        continue;
      }

      if (reportFuncs && v.funcHits == null) {
        throw StateError(
          'Function coverage formatting was requested, but the hit map is '
          'missing function coverage information. Did you run '
          'collect_coverage with the --function-coverage flag?',
        );
      }
      if (reportBranches && v.branchHits == null) {
        throw StateError(
          'Branch coverage formatting was requested, but the hit map is '
          'missing branch coverage information. Did you run '
          'collect_coverage with the --branch-coverage flag?',
        );
      }

      final hits = reportFuncs
          ? v.funcHits!
          : reportBranches
          ? v.branchHits!
          : v.lineHits;
      buf.writeln(source);
      for (var line = 1; line <= lines.length; line++) {
        var prefix = _prefix;
        if (hits.containsKey(line)) {
          prefix = hits[line].toString().padLeft(_prefix.length);
        }
        buf.writeln('$prefix|${lines[line - 1]}');
      }
    }

    return buf.toString();
  }

  /// Returns the local path and the hit map of every file to report on.
  ///
  /// These are the entries of this map that resolve to a path accepted by
  /// [pathFilter], followed by the uncovered files accepted by
  /// [includeUncovered], if provided.
  List<_ReportedFile> _filesToReport(
    Resolver resolver,
    _PathFilter pathFilter, {
    required Loader loader,
    required bool Function(String path)? includeUncovered,
    required bool checkIgnoredLines,
  }) {
    final files = <_ReportedFile>[];
    for (final entry in entries) {
      final source = resolver.resolve(entry.key);
      if (source == null) {
        continue;
      }

      if (!pathFilter(source)) {
        continue;
      }

      files.add((source, entry.value));
    }

    if (includeUncovered != null) {
      final covered = {for (final (source, _) in files) p.canonicalize(source)};
      files.addAll(
        _uncoveredFiles(
          resolver,
          covered,
          pathFilter,
          includeUncovered,
          checkIgnoredLines,
          loader,
        ),
      );
    }
    return files;
  }
}

const _prefix = '       ';

typedef _PathFilter = bool Function(String path);

typedef _ReportedFile = (String path, HitMap hitMap);

/// Returns the `.dart` files below [Resolver.packagePath] that are not in
/// [covered], are accepted by [pathFilter] and [includeUncovered], and have at
/// least one line that can hold code, sorted by path.
///
/// Only paths that pass [pathFilter] are passed to [includeUncovered]. The
/// directories whose names start with a `.` are not searched.
///
/// There is no coverage data for such a file, so every line that is not
/// blank and does not start with `//` is reported with 0 hits. This is an
/// estimate: it counts every other line, including the ones that the Dart VM
/// would not report as code once the file is loaded, such as `import`
/// directives or lines with only a closing bracket. Files without such a
/// line are left out.
///
/// If [checkIgnoredLines] is `true`, the `coverage:ignore-*` comments are
/// applied to the files found this way, like in [HitMap.parseJson].
List<_ReportedFile> _uncoveredFiles(
  Resolver resolver,
  Set<String> covered,
  _PathFilter pathFilter,
  bool Function(String path) includeUncovered,
  bool checkIgnoredLines,
  Loader loader,
) {
  final packagePath = resolver.packagePath;
  if (packagePath == null) {
    throw StateError(
      'Including uncovered files was requested, but the resolver has no '
      'package path to search. Create it with Resolver.create(packagePath: '
      '...).',
    );
  }

  final paths = <String>{};
  for (final file in _dartFilesIn(Directory(packagePath))) {
    final path = resolver.resolveSymbolicLinks(file.path);
    if (path != null &&
        !covered.contains(p.canonicalize(path)) &&
        pathFilter(path) &&
        includeUncovered(path)) {
      paths.add(path);
    }
  }

  final result = <_ReportedFile>[];
  for (final path in paths.toList()..sort()) {
    final lines = loader.loadSync(path);
    if (lines == null) {
      continue;
    }

    // Null means that the whole file is ignored.
    final ignoredLines = checkIgnoredLines
        ? getIgnoredLines(path, lines)
        : <List<int>>[];
    if (ignoredLines == null) {
      continue;
    }

    final lineHits = {
      for (var i = 0; i < lines.length; i++)
        if (_isCode(lines[i]) && !ignoredLines.ignoredContains(i + 1)) i + 1: 0,
    };
    if (lineHits.isNotEmpty) {
      result.add((path, HitMap(lineHits)));
    }
  }
  return result;
}

/// Returns the `.dart` files below [directory], without the ones in
/// directories whose names start with a `.` and without following links.
Iterable<File> _dartFilesIn(Directory directory) sync* {
  for (final entity in directory.listSync(followLinks: false)) {
    final name = p.basename(entity.path);
    if (name.startsWith('.')) {
      continue;
    }

    if (entity is Directory) {
      yield* _dartFilesIn(entity);
    } else if (entity is File && name.endsWith('.dart')) {
      yield entity;
    }
  }
}

/// Whether [line] is not blank and does not start with `//`.
bool _isCode(String line) {
  final trimmed = line.trim();
  return trimmed.isNotEmpty && !trimmed.startsWith('//');
}

_PathFilter _getPathFilter({List<String>? reportOn, Set<Glob>? ignoreGlobs}) {
  if (reportOn == null && ignoreGlobs == null) return (String path) => true;

  final absolutePaths = reportOn?.map(p.canonicalize).toList();

  return (String path) {
    final canonicalizedPath = p.canonicalize(path);

    if (absolutePaths != null &&
        !absolutePaths.any(canonicalizedPath.startsWith)) {
      return false;
    }
    if (ignoreGlobs != null &&
        ignoreGlobs.any((glob) => glob.matches(canonicalizedPath))) {
      return false;
    }

    return true;
  };
}
