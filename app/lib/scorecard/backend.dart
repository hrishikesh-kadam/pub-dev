// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.12

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:gcloud/service_scope.dart' as ss;
import 'package:logging/logging.dart';
import 'package:pool/pool.dart';
import 'package:pub_semver/pub_semver.dart';

// ignore: import_of_legacy_library_into_null_safe
import '../package/models.dart' show Package, PackageVersion;
import '../package/overrides.dart';
import '../shared/datastore.dart' as db;
import '../shared/popularity_storage.dart';
// ignore: import_of_legacy_library_into_null_safe
import '../shared/redis_cache.dart' show cache;
import '../shared/utils.dart';
import '../shared/versions.dart' as versions;
import '../tool/utils/dart_sdk_version.dart';

import 'helpers.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'models.dart';

final _logger = Logger('pub.scorecard.backend');

final Duration _deleteThreshold = const Duration(days: 182);
final _reportSizeWarnThreshold = 16 * 1024;
final _reportSizeDropThreshold = 32 * 1024;

/// The minimum age of the [PackageVersion] which will trigger a fallback to
/// older scorecards. Below this age we only display the current [ScoreCard].
final _fallbackMinimumAge = const Duration(hours: 4);

/// The maximum number of keys we'll try to lookup when we need to load the
/// scorecard or the report information for multiple versions.
///
/// The Datastore limit is 1000, but that caused resource constraint issues
/// https://github.com/dart-lang/pub-dev/issues/4040
///
/// Another issue was if the total size of the reports got too long
/// https://github.com/dart-lang/pub-dev/issues/4780
const _batchLookupMaxKeyCount = 10;

/// The concurrent request for the batch lookup.
const _batchLookupConcurrency = 4;

/// Sets the active scorecard backend.
void registerScoreCardBackend(ScoreCardBackend backend) =>
    ss.register(#_scorecard_backend, backend);

/// The active job backend.
ScoreCardBackend get scoreCardBackend =>
    ss.lookup(#_scorecard_backend) as ScoreCardBackend;

/// Handles the data store and lookup for ScoreCard.
class ScoreCardBackend {
  final db.DatastoreDB _db;
  ScoreCardBackend(this._db);

  /// Returns the [ScoreCardData] for the given package and version.
  Future<ScoreCardData?> getScoreCardData(
    String packageName,
    String? packageVersion, {
    bool onlyCurrent = false,
  }) async {
    final requiredReportTypes = ReportType.values;
    if (packageVersion == null || packageVersion == 'latest') {
      final key = _db.emptyKey.append(Package, id: packageName);
      final p = await _db.lookupOrNull<Package>(key);
      if (p == null) {
        return null;
      }
      packageVersion = p.latestVersion;
    }
    final cached = onlyCurrent
        ? null
        : await cache.scoreCardData(packageName, packageVersion).get()
            as ScoreCardData?;
    if (cached != null && cached.hasReports(requiredReportTypes)) {
      return cached;
    }

    final key = scoreCardKey(packageName, packageVersion);
    final current = (await _db.lookupOrNull<ScoreCard>(key))?.toData();
    if (current != null) {
      // only full cards will be stored in cache
      if (current.isCurrent && current.hasReports(ReportType.values)) {
        await cache.scoreCardData(packageName, packageVersion).set(current);
      }
      if (onlyCurrent || current.hasReports(requiredReportTypes)) {
        return current;
      }
    }

    if (onlyCurrent) return null;

    // List cards that at minimum have a pana report.
    final fallbackKeys = versions.fallbackRuntimeVersions
        .map((v) =>
            scoreCardKey(packageName, packageVersion!, runtimeVersion: v))
        .toList();
    final fallbackCards = await _db.lookup<ScoreCard>(fallbackKeys);
    final fallbackCardData =
        fallbackCards.where((c) => c != null).map((c) => c!.toData()).toList();

    if (fallbackCardData.isEmpty) return null;

    final fallbackCard = fallbackCardData
            .firstWhereOrNull((d) => d.hasReports(requiredReportTypes)) ??
        fallbackCardData
            .firstWhereOrNull((d) => d.hasReports([ReportType.pana]));

    // For recently uploaded version, we don't want to fallback to an analysis
    // coming from an older running deployment too early. A new analysis may
    // come soon from the current runtime, and if it is different in significant
    // ways (e.g. score or success status differs), it may confuse users looking
    // at it in the interim period.
    //
    // However, once the upload is above the specified age, it is better to
    // display and old analysis than to keep waiting on a new one.
    if (fallbackCard != null) {
      final age = DateTime.now().difference(fallbackCard.packageVersionCreated);
      if (age < _fallbackMinimumAge) {
        return null;
      }
    }
    return fallbackCard;
  }

  /// Creates or updates a [ScoreCard] entry with the provided [panaReport] and/or [dartdocReport].
  /// The report data will be converted to json+gzip and stored as a bytes in the [ScoreCard] entry.
  Future<void> updateReportOnCard(
    String packageName,
    String packageVersion, {
    PanaReport? panaReport,
    DartdocReport? dartdocReport,
  }) async {
    final key = scoreCardKey(packageName, packageVersion);
    final pAndPv = await _db.lookup([key.parent!, key.parent!.parent!]);
    final version = pAndPv[0] as PackageVersion?;
    final package = pAndPv[1] as Package?;
    if (package == null || version == null) {
      throw Exception('Unable to lookup $packageName $packageVersion.');
    }

    final currentSdkVersion = await getDartSdkVersion();
    final status = PackageStatus.fromModels(
        package, version, currentSdkVersion.semanticVersion);

    await db.withRetryTransaction(_db, (tx) async {
      var scoreCard = await tx.lookupOrNull<ScoreCard>(key);

      if (scoreCard == null) {
        _logger.info('Creating new ScoreCard $packageName $packageVersion.');
        scoreCard = ScoreCard.init(
          packageName: packageName,
          packageVersion: packageVersion,
          packageCreated: package.created,
          packageVersionCreated: version.created,
        );
      } else {
        _logger.info('Updating ScoreCard $packageName $packageVersion.');
        scoreCard.updated = DateTime.now().toUtc();
      }

      scoreCard.flags.clear();
      if (package.isDiscontinued) {
        scoreCard.addFlag(PackageFlags.isDiscontinued);
      }
      if (status.isLatestStable) {
        scoreCard.addFlag(PackageFlags.isLatestStable);
      }
      if (status.isLegacy) {
        scoreCard.addFlag(PackageFlags.isLegacy);
      }
      if (status.isObsolete) {
        scoreCard.addFlag(PackageFlags.isObsolete);
      }
      if (version.pubspec.usesFlutter) {
        scoreCard.addFlag(PackageFlags.usesFlutter);
      }

      scoreCard.popularityScore = popularityStorage.lookup(packageName);

      scoreCard.updateReports(
        panaReport: panaReport,
        dartdocReport: dartdocReport,
      );

      bool sizeCheck(String reportType, List<int>? bytes) {
        if (bytes == null || bytes.isEmpty) return false;
        final size = bytes.length;
        if (size > _reportSizeDropThreshold) {
          _logger.reportError(
              '$reportType report exceeded size threshold ($size > $_reportSizeWarnThreshold)');
          return true;
        } else if (size > _reportSizeWarnThreshold) {
          _logger.warning(
              '$reportType report exceeded size threshold ($size > $_reportSizeWarnThreshold)');
        }
        return false;
      }

      if (sizeCheck(ReportType.pana, scoreCard.panaReportJsonGz)) {
        // TODO: replace with something meaningful
        scoreCard.panaReportJsonGz = <int>[];
      }
      if (sizeCheck(ReportType.dartdoc, scoreCard.dartdocReportJsonGz)) {
        // TODO: replace with something meaningful
        scoreCard.dartdocReportJsonGz = <int>[];
      }

      tx.insert(scoreCard);
    });

    final isLatest = package.latestVersion == version.version;
    await Future.wait([
      cache.scoreCardData(packageName, packageVersion).purge(),
      cache.uiPackagePage(packageName, packageVersion).purge(),
      if (isLatest) cache.uiPackagePage(packageName, null).purge(),
      if (isLatest) cache.packageView(packageName).purge(),
    ]);
  }

  /// Load and deserialize a [ScoreCardData] for the given package's versions.
  Future<List<ScoreCardData?>> getScoreCardDataForAllVersions(
    String packageName,
    Iterable<String> versions, {
    String? runtimeVersion,
  }) async {
    final pool = Pool(_batchLookupConcurrency);
    final futures = <Future<List<ScoreCardData?>>>[];
    for (var start = 0;
        start < versions.length;
        start += _batchLookupMaxKeyCount) {
      final keys = versions
          .skip(start)
          .take(_batchLookupMaxKeyCount)
          .map((v) =>
              scoreCardKey(packageName, v, runtimeVersion: runtimeVersion))
          .toList();
      final f = pool.withResource(() async {
        final items = await _db.lookup<ScoreCard>(keys);
        return items.map((item) => item?.toData()).toList();
      });
      futures.add(f);
    }
    final lists = await Future.wait(futures);
    final results = lists.fold<List<ScoreCardData?>>(
      <ScoreCardData>[],
      (r, list) => r..addAll(list),
    );
    await pool.close();
    return results;
  }

  /// Updates the `updated` field of the [ScoreCard] entry, forcing search
  /// indexes to pick it up and update their index.
  Future<void> markScoreCardUpdated(
      String packageName, String packageVersion) async {
    final key = scoreCardKey(packageName, packageVersion);
    await db.withRetryTransaction(_db, (tx) async {
      final card = await tx.lookupOrNull<ScoreCard>(key);
      if (card == null) return;
      card.updated = DateTime.now().toUtc();
      tx.insert(card);
    });
  }

  /// Deletes the old entries that predate [versions.gcBeforeRuntimeVersion].
  Future<void> deleteOldEntries() async {
    final now = DateTime.now();

    // deleting reports
    await _db.deleteWithQuery(_db.query<ScoreCardReport>()
      ..filter('runtimeVersion <', versions.gcBeforeRuntimeVersion));
    await _db.deleteWithQuery(_db.query<ScoreCardReport>()
      ..filter('updated <', now.subtract(_deleteThreshold)));

    // deleting scorecards
    await _db.deleteWithQuery(_db.query<ScoreCard>()
      ..filter('runtimeVersion <', versions.gcBeforeRuntimeVersion));
    await _db.deleteWithQuery(_db.query<ScoreCard>()
      ..filter('updated <', now.subtract(_deleteThreshold)));
  }

  /// Returns the status of a package and version.
  Future<PackageStatus> getPackageStatus(String package, String version) async {
    final currentSdkVersion = await getDartSdkVersion();
    final packageKey = _db.emptyKey.append(Package, id: package);
    final List list = await _db
        .lookup([packageKey, packageKey.append(PackageVersion, id: version)]);
    final p = list[0] as Package;
    final pv = list[1] as PackageVersion;
    return PackageStatus.fromModels(p, pv, currentSdkVersion.semanticVersion);
  }

  /// Returns whether we should update the [reportType] report for the given
  /// package version.
  ///
  /// The method will return true, if either of the following is true:
  /// - it does not have a report yet,
  /// - the report was updated before [updatedAfter],
  /// - the report is older than [successThreshold] if it was a success,
  /// - the report is older than [failureThreshold] if it was a failure.
  Future<bool> shouldUpdateReport(
    PackageVersion? pv,
    String reportType, {
    Duration successThreshold = const Duration(days: 30),
    Duration failureThreshold = const Duration(days: 1),
    DateTime? updatedAfter,
  }) async {
    if (pv == null || isSoftRemoved(pv.package)) {
      return false;
    }

    // checking existing card
    final key = scoreCardKey(pv.package, pv.version);
    final card = await _db.lookupOrNull<ScoreCard>(key);
    if (card == null) return true;

    bool checkUpdatedAndStatus(DateTime? updated, String? reportStatus) {
      // checking existence
      if (updated == null) {
        return true;
      }
      // checking freshness
      if (updatedAfter != null && updatedAfter.isAfter(updated)) {
        return true;
      }
      // checking age
      final age = DateTime.now().toUtc().difference(updated);
      final isSuccess = reportStatus == ReportStatus.success;
      final ageThreshold = isSuccess ? successThreshold : failureThreshold;
      return age > ageThreshold;
    }

    final data = card.toData();
    if (reportType == ReportType.pana) {
      return checkUpdatedAndStatus(
          data.panaReport?.timestamp, data.panaReport?.reportStatus);
    } else if (reportType == ReportType.dartdoc) {
      return checkUpdatedAndStatus(
          data.dartdocReport?.timestamp, data.dartdocReport?.reportStatus);
    } else {
      throw AssertionError('Unknown report type: $reportType.');
    }
  }
}

class PackageStatus {
  final bool exists;
  final DateTime? publishDate;
  final Duration? age;
  final bool isLatestStable;
  final bool isDiscontinued;
  final bool isObsolete;
  final bool isLegacy;
  final bool usesFlutter;
  final bool usesPreviewSdk;
  final bool isPublishedByDartDev;

  PackageStatus._({
    required this.exists,
    this.publishDate,
    this.age,
    this.isLatestStable = false,
    this.isDiscontinued = false,
    this.isObsolete = false,
    this.isLegacy = false,
    this.usesFlutter = false,
    this.usesPreviewSdk = false,
    this.isPublishedByDartDev = false,
  });

  factory PackageStatus.fromModels(
      Package? p, PackageVersion? pv, Version currentSdkVersion) {
    if (p == null || pv == null || p.isNotVisible) {
      return PackageStatus._(exists: false);
    }
    final publishDate = pv.created;
    final isLatestStable = p.latestVersion == pv.version;
    final now = DateTime.now().toUtc();
    final age = now.difference(publishDate).abs();
    final isObsolete = age > twoYears && !isLatestStable;
    return PackageStatus._(
      exists: true,
      publishDate: publishDate,
      age: age,
      isLatestStable: isLatestStable,
      isDiscontinued: p.isDiscontinued,
      isObsolete: isObsolete,
      isLegacy: pv.pubspec.supportsOnlyLegacySdk,
      usesFlutter: pv.pubspec.usesFlutter,
      usesPreviewSdk: pv.pubspec.isPreviewForCurrentSdk(currentSdkVersion),
      isPublishedByDartDev:
          p.publisherId != null && isDartDevPublisher(p.publisherId),
    );
  }
}
