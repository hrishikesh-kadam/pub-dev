// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.12

import 'dart:async';
import 'dart:math' as math;

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:pool/pool.dart';

import '../package/backend.dart';
// ignore: import_of_legacy_library_into_null_safe
import '../package/models.dart' show Package, PackageVersion;
import '../shared/datastore.dart' as db;
// ignore: import_of_legacy_library_into_null_safe
import '../shared/redis_cache.dart';
import '../shared/task_scheduler.dart';
import '../shared/task_sources.dart';
import '../shared/utils.dart' show DurationTracker;

import 'backend.dart';
import 'model.dart';

export 'model.dart';

final _logger = Logger('pub.job');
final _random = math.Random.secure();

typedef AliveCallback = FutureOr Function();

abstract class JobProcessor {
  final JobService service;
  final String _serviceAsString;
  final AliveCallback? _aliveCallback;
  final _trackers = <String, DurationTracker>{};

  JobProcessor({
    required this.service,

    /// [JobProcessor] calls this to indicate that it is still alive and working.
    /// It is expected to be called between jobs.
    AliveCallback? aliveCallback,
  })  : _serviceAsString = jobServiceAsString(service),
        _aliveCallback = aliveCallback;

  Future<JobStatus> process(Job job);

  Future<bool> shouldProcess(PackageVersion pv, DateTime updated);

  /// Never completes.
  Future<void> run() async {
    int sleepSeconds = 0;
    for (;;) {
      final status = await _runOneJob();
      if (_aliveCallback != null) await _aliveCallback!();
      final wasProcessing =
          status == JobStatus.success || status == JobStatus.skipped;
      sleepSeconds = wasProcessing ? 0 : math.min(sleepSeconds + 1, 60);
      await Future.delayed(Duration(seconds: sleepSeconds));
    }
  }

  Future<JobStatus> _runOneJob() async {
    JobStatus status = JobStatus.none;
    String jobDescription = '[pull]';
    final sw = Stopwatch()..start();
    var statEvent = 'failed';
    try {
      final job = await jobBackend.lockAvailable(service);
      if (job != null) {
        jobDescription = '${job.packageName} ${job.packageVersion}';
        _logger.info('$_serviceAsString job started: $jobDescription');
        try {
          status = await process(job);
          status = JobStatus.success;
          statEvent = 'success';
          _logger.info('$_serviceAsString job completed: $jobDescription');
        } on db.DatastoreError catch (e, st) {
          _logger.info('$_serviceAsString job error $jobDescription', e, st);
        } catch (e, st) {
          _logger.severe('$_serviceAsString job error $jobDescription', e, st);
        }
        await jobBackend.complete(job, status, sw.elapsed);
      }
    } on db.DatastoreError catch (e, st) {
      statEvent = 'datastore-error';
      _logger.info('$_serviceAsString job error $jobDescription', e, st);
    } catch (e, st) {
      statEvent = 'error';
      _logger.severe('$_serviceAsString job error $jobDescription', e, st);
    }
    _trackers.putIfAbsent(statEvent, () => DurationTracker()).add(sw.elapsed);
    return status;
  }

  void reportIssueWithLatest(Job job, String message) {
    _logger.info(
        '$_serviceAsString failed for latest version of ${job.packageName} (${job.packageVersion}): $message');
  }

  Map stats() {
    return _trackers
        .map((key, value) => MapEntry<String, Map>(key, value.toShortStat()));
  }
}

class JobMaintenance {
  final db.DatastoreDB _db;
  final JobProcessor _processor;
  JobMaintenance(this._db, this._processor);

  Future<void> run() {
    final futures = <Future>[
      syncDatastoreHead(),
      syncDatastoreHistory(),
      updateStates(),
      _processor.run(),
    ];
    return Future.wait(futures);
  }

  /// Scans datastore for job updates, unlocks pending jobs and then runs the
  /// available jobs.
  @visibleForTesting
  Future<void> scanUpdateAndRunOnce() async {
    await for (final pv in _db.query<PackageVersion>().run()) {
      await jobBackend.trigger(
        _processor.service,
        pv.package,
        version: pv.version,
        updated: pv.created,
      );
    }
    await jobBackend.unlockStaleProcessing(_processor.service);
    await jobBackend.checkIdle(_processor.service, _processor.shouldProcess);
    for (;;) {
      final status = await _processor._runOneJob();
      if (status == JobStatus.none) {
        break;
      }
    }
  }

  /// Never completes.
  Future<void> syncDatastoreHead() async {
    final source = DatastoreHeadTaskSource(_db, TaskSourceModel.version,
        skipHistory: true);
    final stream = source.startStreaming();
    await for (Task task in stream) {
      try {
        await jobBackend.trigger(
          _processor.service,
          task.package,
          version: task.version,
          updated: task.updated,
        );
      } catch (e, st) {
        _logger.info('Head sync failed for $task', e, st);
      }
    }
  }

  /// Reads the current package versions and syncs them with job entries.
  Future<void> syncDatastoreHistory() async {
    final packages = <String, Package>{};
    await for (final p in _db.query<Package>().run()) {
      packages[p.name] = p;
    }
    final packageNames = packages.keys.toList()..shuffle();

    Future<void> updateJob(PackageVersion pv, bool skipLatestStable) async {
      try {
        final p = packages[pv.package];
        if (p == null || p.isNotVisible) return;
        final releases = await packageBackend.latestReleases(p);
        final isLatestStable = releases.stable.version == pv.version;
        final isLatestPrerelease = releases.showPrerelease &&
            releases.prerelease.version == pv.version;
        final isLatestPreview =
            releases.showPreview && releases.preview.version == pv.version;
        if (isLatestStable && skipLatestStable) return;
        final shouldProcess = await _processor.shouldProcess(pv, pv.created);
        await jobBackend.createOrUpdate(
          service: _processor.service,
          package: pv.package,
          version: pv.version,
          isLatestStable: isLatestStable,
          isLatestPrerelease: isLatestPrerelease,
          isLatestPreview: isLatestPreview,
          packageVersionUpdated: pv.created,
          shouldProcess: shouldProcess,
        );
      } catch (e, st) {
        _logger.info(
            'History sync failed for ${pv.package} ${pv.version}', e, st);
      }
    }

    // prevent updating the latest versions if they were already scanned recently
    await cache
        .jobHistoryLatestScanned(jobServiceAsString(_processor.service))
        .get(() async {
      final pool = Pool(4);
      final futures = <Future>[];
      for (final package in packageNames) {
        final p = packages[package]!;
        final pv = await _db.lookupValue<PackageVersion>(p.latestVersionKey);
        final f = pool.withResource(() => updateJob(pv, false));
        futures.add(f);
      }
      await Future.wait(futures);
      await pool.close();
      return true;
    });

    for (final package in packageNames) {
      final cacheEntry = cache.jobHistoryPackageScanned(
          jobServiceAsString(_processor.service), package);

      await cacheEntry.get(() async {
        final pool = Pool(4);
        final futures = <Future>[];
        final versions = await packageBackend.versionsOfPackage(package);
        versions.shuffle();
        for (final pv in versions) {
          final f = pool.withResource(() => updateJob(pv, true));
          futures.add(f);
        }
        await Future.wait(futures);
        await pool.close();
        return true;
      });
    }
  }

  /// Never completes
  Future<void> updateStates() async {
    for (;;) {
      await Future.delayed(Duration(minutes: 1 + _random.nextInt(10)));
      try {
        await jobBackend.unlockStaleProcessing(_processor.service);
      } catch (e, st) {
        _logger.warning('Error unlocking stale jobs.', e, st);
      }

      await Future.delayed(Duration(minutes: 1 + _random.nextInt(10)));
      try {
        await jobBackend.checkIdle(
            _processor.service, _processor.shouldProcess);
      } catch (e, st) {
        _logger.warning('Error updating idle jobs.', e, st);
      }
    }
  }
}
