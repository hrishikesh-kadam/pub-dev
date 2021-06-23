// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.12

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:logging/logging.dart';

import '../shared/utils.dart' show boundedList;

import 'scope_specificity.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'search_service.dart';
import 'text_utils.dart';
import 'token_index.dart';

final _logger = Logger('search.mem_index');
final _textSearchTimeout = Duration(milliseconds: 500);

class InMemoryPackageIndex implements PackageIndex {
  final Map<String, PackageDocument> _packages = <String, PackageDocument>{};
  final _packageNameIndex = _PackageNameIndex();
  final TokenIndex _descrIndex = TokenIndex();
  final TokenIndex _readmeIndex = TokenIndex();
  final TokenIndex _apiSymbolIndex = TokenIndex();
  final TokenIndex _apiDartdocIndex = TokenIndex();
  final _likeTracker = _LikeTracker();
  final _updatedPackages = ListQueue<String>();
  final bool _alwaysUpdateLikeScores;
  DateTime? _lastUpdated;
  bool _isReady = false;

  InMemoryPackageIndex({
    math.Random? random,
    @visibleForTesting bool alwaysUpdateLikeScores = false,
  }) : _alwaysUpdateLikeScores = alwaysUpdateLikeScores;

  @override
  Future<IndexInfo> indexInfo() async {
    return IndexInfo(
      isReady: _isReady,
      packageCount: _packages.length,
      lastUpdated: _lastUpdated,
      updatedPackages: _updatedPackages.toList(),
    );
  }

  void _trackUpdated(String package) {
    while (_updatedPackages.length >= 20) {
      _updatedPackages.removeFirst();
    }
    _updatedPackages.addLast(package);
  }

  @override
  Future<void> markReady() async {
    _isReady = true;
  }

  @override
  Future<void> addPackage(PackageDocument doc) async {
    _packages[doc.package] = doc;

    // The method could be a single sync block, however, while the index update
    // happens, we are not serving queries. With the forced async segments,
    // the waiting queries will be served earlier.
    await Future.delayed(Duration.zero);
    _packageNameIndex.add(doc.package);

    await Future.delayed(Duration.zero);
    _descrIndex.add(doc.package, doc.description);

    await Future.delayed(Duration.zero);
    _readmeIndex.add(doc.package, doc.readme);

    for (ApiDocPage page in doc.apiDocPages ?? const []) {
      final pageId = _apiDocPageId(doc.package, page);
      if (page.symbols != null && page.symbols.isNotEmpty) {
        await Future.delayed(Duration.zero);
        _apiSymbolIndex.add(pageId, page.symbols.join(' '));
      }
      if (page.textBlocks != null && page.textBlocks.isNotEmpty) {
        await Future.delayed(Duration.zero);
        _apiDartdocIndex.add(pageId, page.textBlocks.join(' '));
      }
    }

    await Future.delayed(Duration.zero);
    _likeTracker.trackLikeCount(doc.package, doc.likeCount ?? 0);
    if (_alwaysUpdateLikeScores) {
      await _likeTracker._updateScores();
    } else {
      await _likeTracker._updateScoresIfNeeded();
    }

    await Future.delayed(Duration.zero);
    _lastUpdated = DateTime.now().toUtc();
    _trackUpdated(doc.package);
  }

  @override
  Future<void> addPackages(Iterable<PackageDocument> documents) async {
    for (PackageDocument doc in documents) {
      await addPackage(doc);
    }
    await _likeTracker._updateScores();
  }

  @override
  Future<void> removePackage(String package) async {
    final doc = _packages.remove(package);
    if (doc == null) return;
    _packageNameIndex.remove(package);
    _descrIndex.remove(package);
    _readmeIndex.remove(package);
    for (ApiDocPage page in doc.apiDocPages ?? const []) {
      final pageId = _apiDocPageId(doc.package, page);
      _apiSymbolIndex.remove(pageId);
      _apiDartdocIndex.remove(pageId);
    }
    _likeTracker.removePackage(doc.package);
    _lastUpdated = DateTime.now().toUtc();
    _trackUpdated('-$package');
  }

  @override
  Future<PackageSearchResult> search(ServiceSearchQuery query) async {
    final Set<String> packages = Set.from(_packages.keys);

    // filter on package prefix
    if (query.parsedQuery?.packagePrefix != null) {
      final String prefix = query.parsedQuery.packagePrefix.toLowerCase();
      packages.removeWhere(
        (package) =>
            !_packages[package]!.package.toLowerCase().startsWith(prefix),
      );
    }

    // filter on tags
    final combinedTagsPredicate =
        query.tagsPredicate.appendPredicate(query.parsedQuery.tagsPredicate);
    if (combinedTagsPredicate.isNotEmpty) {
      packages.retainWhere(
          (package) => combinedTagsPredicate.matches(_packages[package]!.tags));
    }

    // filter on dependency
    if (query.parsedQuery.hasAnyDependency) {
      packages.removeWhere((package) {
        final doc = _packages[package]!;
        if (doc.dependencies == null) return true;
        for (String dependency in query.parsedQuery.allDependencies) {
          if (!doc.dependencies.containsKey(dependency)) return true;
        }
        for (String dependency in query.parsedQuery.refDependencies) {
          final type = doc.dependencies[dependency];
          if (type == null || type == DependencyTypes.transitive) return true;
        }
        return false;
      });
    }

    // filter on owners
    if (query.uploaderOrPublishers != null) {
      assert(query.uploaderOrPublishers.isNotEmpty);

      packages.removeWhere((package) {
        final doc = _packages[package]!;
        if (doc.publisherId != null) {
          return !query.uploaderOrPublishers.contains(doc.publisherId);
        }
        if (doc.uploaderEmails == null) {
          return true; // turn this into an error in the future.
        }
        return !query.uploaderOrPublishers.any(doc.uploaderEmails.contains);
      });
    }

    // filter on publisher
    if (query.publisherId != null || query.parsedQuery.publisher != null) {
      final publisherId = query.publisherId ?? query.parsedQuery.publisher;
      packages.removeWhere((package) {
        final doc = _packages[package]!;
        return doc.publisherId != publisherId;
      });
    }

    // filter on email
    if (query.parsedQuery.emails.isNotEmpty) {
      packages.removeWhere((package) {
        final doc = _packages[package];
        if (doc?.uploaderEmails == null) {
          return true;
        }
        for (final email in query.parsedQuery.emails) {
          if (doc!.uploaderEmails.contains(email)) {
            return false;
          }
        }
        return true;
      });
    }

    PackageHit? highlightedHit;
    if (query.considerHighlightedHit) {
      final queryText = query.parsedQuery.text;
      final matchingPackage =
          _packages[queryText] ?? _packages[queryText.toLowerCase()];

      if (matchingPackage != null) {
        // Remove higlighted package from the final packages set.
        packages.remove(matchingPackage.package);

        // higlight only if we are on the first page
        if (query.includeHighlightedHit) {
          highlightedHit = PackageHit(package: matchingPackage.package);
        }
      }
    }

    // do text matching
    final textResults = _searchText(packages, query.parsedQuery.text);

    // filter packages that doesn't match text query
    if (textResults != null) {
      final keys = textResults.pkgScore.getKeys();
      packages.removeWhere((x) => !keys.contains(x));
    }

    late List<PackageHit> packageHits;
    switch (query.order ?? SearchOrder.top) {
      case SearchOrder.top:
        final hasSpecificScope = query.sdk != null;
        final List<Score> scores = [
          _getOverallScore(packages),
          if (textResults != null) textResults.pkgScore,
          if (hasSpecificScope) Score(_scopeSpecificityScore(query, packages)),
        ];
        final overallScore = Score.multiply(scores);
        packageHits = _rankWithValues(overallScore.getValues());
        break;
      case SearchOrder.text:
        final score = textResults?.pkgScore ?? Score.empty();
        packageHits = _rankWithValues(score.getValues());
        break;
      case SearchOrder.created:
        packageHits = _rankWithComparator(packages, _compareCreated);
        break;
      case SearchOrder.updated:
        packageHits = _rankWithComparator(packages, _compareUpdated);
        break;
      case SearchOrder.popularity:
        packageHits = _rankWithValues(getPopularityScore(packages));
        break;
      case SearchOrder.like:
        packageHits = _rankWithValues(getLikeScore(packages));
        break;
      case SearchOrder.points:
        packageHits = _rankWithValues(getPubPoints(packages));
        break;
    }

    // bound by offset and limit (or randomize items)
    final totalCount = packageHits.length + (highlightedHit == null ? 0 : 1);
    packageHits =
        boundedList(packageHits, offset: query.offset, limit: query.limit);

    if (textResults != null && textResults.topApiPages.isNotEmpty) {
      packageHits = packageHits.map((ps) {
        final apiPages = textResults.topApiPages[ps.package]
            // TODO: extract title for the page
            ?.map((String page) => ApiPageRef(path: page))
            .toList();
        return ps.change(apiPages: apiPages);
      }).toList();
    }

    return PackageSearchResult(
      timestamp: DateTime.now().toUtc(),
      totalCount: totalCount,
      highlightedHit: highlightedHit,
      packageHits: packageHits,
    );
  }

  Map<String, double> _scopeSpecificityScore(
      ServiceSearchQuery query, Iterable<String> packages) {
    final scopeSpecificity = <String, double>{};
    packages.forEach((String package) {
      final doc = _packages[package]!;
      scopeSpecificity[package] = scoreScopeSpecificity(query.sdk, doc.tags);
    });
    return scopeSpecificity;
  }

  @visibleForTesting
  Map<String, double> getPopularityScore(Iterable<String> packages) {
    return Map.fromIterable(
      packages,
      value: (package) => _packages[package]?.popularity ?? 0.0,
    );
  }

  @visibleForTesting
  Map<String, double> getLikeScore(Iterable<String> packages) {
    return Map.fromIterable(
      packages,
      value: (package) => (_packages[package]?.likeCount?.toDouble() ?? 0.0),
    );
  }

  @visibleForTesting
  Map<String, double> getPubPoints(Iterable<String> packages) {
    return Map.fromIterable(
      packages,
      value: (package) =>
          (_packages[package]?.grantedPoints?.toDouble() ?? 0.0),
    );
  }

  Score _getOverallScore(Iterable<String> packages) {
    final values = Map<String, double>.fromIterable(packages, value: (package) {
      final doc = _packages[package]!;
      final downloadScore = doc.popularity ?? 0.0;
      final likeScore = _likeTracker.getLikeScore(doc.package);
      final popularity = (downloadScore + likeScore) / 2;
      final points = (doc.grantedPoints ?? 0) / math.max(1, doc.maxPoints ?? 0);
      final overall = popularity * 0.5 + points * 0.5;
      // don't multiply with zero.
      return 0.5 + 0.5 * overall;
    });
    return Score(values);
  }

  _TextResults? _searchText(Set<String> packages, String? text) {
    final sw = Stopwatch()..start();
    if (text != null && text.isNotEmpty) {
      final words = splitForQuery(text);
      if (words.isEmpty) {
        return _TextResults(Score.empty(), <String, List<String>>{});
      }

      bool aborted = false;

      bool checkAborted() {
        if (!aborted && sw.elapsed > _textSearchTimeout) {
          aborted = true;
          _logger.info(
              '[pub-aborted-search-query] Aborted text search after ${sw.elapsedMilliseconds} ms.');
        }
        return aborted;
      }

      final nameScore =
          _packageNameIndex.searchWords(words, packages: packages);

      final descr =
          _descrIndex.searchWords(words, weight: 0.90, limitToIds: packages);
      final readme =
          _readmeIndex.searchWords(words, weight: 0.75, limitToIds: packages);

      final core = Score.max([nameScore, descr, readme]);

      var symbolPages = Score.empty();
      if (!checkAborted()) {
        symbolPages = _apiSymbolIndex.searchWords(words, weight: 0.70);
      }

      // Do documentation text search only when there was no reasonable core result
      // and no reasonable API symbol result.
      var dartdocPages = Score.empty();
      final shouldSearchApiText =
          core.getMaxValue() < 0.4 && symbolPages.getMaxValue() < 0.3;
      if (!checkAborted() && shouldSearchApiText) {
        dartdocPages = _apiDartdocIndex.searchWords(words, weight: 0.40);
      }

      final apiDocScore = Score.max([symbolPages, dartdocPages]);
      final apiPackages = <String, double>{};
      for (String key in apiDocScore.getKeys()) {
        final pkg = _apiDocPkg(key);
        if (!packages.contains(pkg)) continue;
        final value = apiDocScore[key];
        apiPackages[pkg] = math.max(value, apiPackages[pkg] ?? 0.0);
      }
      final apiPkgScore = Score(apiPackages);
      var score = Score.max([core, apiPkgScore])
          .project(packages)
          .removeLowValues(fraction: 0.2, minValue: 0.01);

      // filter results based on exact phrases
      final phrases =
          extractExactPhrases(text).map(normalizeBeforeIndexing).toList();
      if (!aborted && phrases.isNotEmpty) {
        final Map<String, double> matched = <String, double>{};
        for (String package in score.getKeys()) {
          final doc = _packages[package]!;
          final bool matchedAllPhrases = phrases.every((phrase) =>
              doc.package.contains(phrase) ||
              doc.description.contains(phrase) ||
              doc.readme.contains(phrase));
          if (matchedAllPhrases) {
            matched[package] = score[package];
          }
        }
        score = Score(matched);
      }

      final apiDocKeys = apiDocScore.getKeys().toList()
        ..sort((a, b) => -apiDocScore[a].compareTo(apiDocScore[b]));
      final topApiPages = <String, List<String>>{};
      for (String key in apiDocKeys) {
        final pkg = _apiDocPkg(key);
        final pages = topApiPages.putIfAbsent(pkg, () => []);
        if (pages.length < 3) {
          final page = _apiDocPath(key);
          pages.add(page);
        }
      }

      return _TextResults(score, topApiPages);
    }
    return null;
  }

  List<PackageHit> _rankWithValues(Map<String, double> values) {
    final list = values.entries
        .map((e) => PackageHit(package: e.key, score: e.value))
        .toList();
    list.sort((a, b) {
      final int scoreCompare = -a.score.compareTo(b.score);
      if (scoreCompare != 0) return scoreCompare;
      // if two packages got the same score, order by last updated
      return _compareUpdated(_packages[a.package]!, _packages[b.package]!);
    });
    return list;
  }

  List<PackageHit> _rankWithComparator(Set<String> packages,
      int Function(PackageDocument a, PackageDocument b) compare) {
    final list = packages
        .map((package) => PackageHit(package: _packages[package]!.package))
        .toList();
    list.sort((a, b) => compare(_packages[a.package]!, _packages[b.package]!));
    return list;
  }

  int _compareCreated(PackageDocument a, PackageDocument b) {
    if (a.created == null) return -1;
    if (b.created == null) return 1;
    return -a.created.compareTo(b.created);
  }

  int _compareUpdated(PackageDocument a, PackageDocument b) {
    if (a.updated == null) return -1;
    if (b.updated == null) return 1;
    return -a.updated.compareTo(b.updated);
  }

  String _apiDocPageId(String package, ApiDocPage page) {
    return '$package::${page.relativePath}';
  }

  String _apiDocPkg(String id) {
    return id.split('::').first;
  }

  String _apiDocPath(String id) {
    return id.split('::').last;
  }
}

class _TextResults {
  final Score pkgScore;
  final Map<String, List<String>> topApiPages;

  _TextResults(this.pkgScore, this.topApiPages);
}

/// A simple (non-inverted) index designed for package name lookup.
class _PackageNameIndex {
  /// Maps package name to a reduced form of the name:
  /// the same character parts, but without `-`.
  final _namesWithoutGaps = <String, String>{};

  String _collapseName(String package) => package.replaceAll('_', '');

  /// Add a new [package] to the index.
  void add(String package) {
    _namesWithoutGaps[package] = _collapseName(package);
  }

  /// Remove a [package] from the index.
  void remove(String package) {
    _namesWithoutGaps.remove(package);
  }

  /// Search [text] and return the matching packages with scores.
  Score search(String text) {
    return searchWords(splitForQuery(text));
  }

  /// Search using the parsed [words] and return the match packages with scores.
  Score searchWords(List<String> words, {Set<String>? packages}) {
    final pkgNamesToCheck = packages ?? _namesWithoutGaps.keys;
    final values = <String, double>{};
    for (final pkg in pkgNamesToCheck) {
      // Calculate the collapsed format of the package name based on the cache.
      // Fallback value is used in cases where concurrent updates of the index
      // would cause inconsistencies and empty value in the cache.
      final nameWithoutGaps = _namesWithoutGaps[pkg] ?? _collapseName(pkg);
      final matchedChars = List<bool>.filled(nameWithoutGaps.length, false);
      var unmatchedNgrams = 0;

      bool matchPattern(Pattern pattern) {
        var matched = false;
        pattern.allMatches(nameWithoutGaps).forEach((m) {
          matched = true;
          for (var i = m.start; i < m.end; i++) {
            matchedChars[i] = true;
          }
        });
        return matched;
      }

      // all words must be found inside the collapsed name
      var matchesPkg = true;
      for (final word in words) {
        // try singular/plural exact match.
        var matchedWord = matchPattern(_pluralizePattern(word));

        // try ngram matches
        if (!matchedWord && word.length > 3) {
          final parts = ngrams(word, 3, 3);
          var matchedCount = 0;
          for (final part in parts) {
            if (matchPattern(part)) {
              matchedCount++;
            }
          }
          unmatchedNgrams += parts.length - matchedCount;

          // accept word match if more than half of the n-grams are matched
          matchedWord = matchedCount > parts.length ~/ 2;
        }

        // failed to match word
        if (!matchedWord) {
          matchesPkg = false;
          break;
        }
      }

      if (!matchesPkg) continue;
      final matchedCharCount = matchedChars.where((c) => c).length;
      values[pkg] = matchedCharCount / (matchedChars.length + unmatchedNgrams);
    }
    return Score(values);
  }

  Pattern _pluralizePattern(String word) {
    if (word.length < 3) return word;
    if (word.endsWith('s')) {
      final singularEscaped = RegExp.escape(word.substring(0, word.length - 1));
      return RegExp('${singularEscaped}s?');
    }
    final wordEscaped = RegExp.escape(word);
    return RegExp('${wordEscaped}s?');
  }
}

class _LikeScore {
  final String package;
  int likeCount = 0;
  double score = 0.0;

  _LikeScore(this.package, {this.likeCount = 0, this.score = 0.0});
}

class _LikeTracker {
  final _values = <String, _LikeScore>{};
  bool _changed = false;
  DateTime? _lastUpdated;

  double getLikeScore(String package) {
    return _values[package]?.score ?? 0.0;
  }

  void trackLikeCount(String package, int likeCount) {
    final v = _values.putIfAbsent(package, () => _LikeScore(package));
    if (v.likeCount != likeCount) {
      _changed = true;
      v.likeCount = likeCount;
    }
  }

  void removePackage(String package) {
    final removed = _values.remove(package);
    _changed |= removed != null;
  }

  Future<void> _updateScoresIfNeeded() async {
    if (!_changed) {
      // we know there is nothing to update
      return;
    }
    final now = DateTime.now();
    if (_lastUpdated != null && now.difference(_lastUpdated!).inHours < 12) {
      // we don't need to update too frequently
      return;
    }

    await _updateScores();
  }

  /// Updates `_LikeScore.score` values, setting them between 0.0 (no likes) to
  /// 1.0 (most likes).
  Future<void> _updateScores() async {
    final sw = Stopwatch()..start();
    final entries = _values.values.toList();

    // The method could be a single sync block, however, while the index update
    // happens, we are not serving queries. With the forced async segments,
    // the waiting queries will be served earlier.
    await Future.delayed(Duration.zero);
    entries.sort((a, b) => a.likeCount.compareTo(b.likeCount));

    await Future.delayed(Duration.zero);
    for (int i = 0; i < entries.length; i++) {
      if (i > 0 && entries[i].likeCount == entries[i - 1].likeCount) {
        entries[i].score = entries[i - 1].score;
      } else {
        entries[i].score = (i + 1) / entries.length;
      }
    }
    _changed = false;
    _lastUpdated = DateTime.now();
    _logger.info('Updated like scores in ${sw.elapsed} (${entries.length})');
  }
}
