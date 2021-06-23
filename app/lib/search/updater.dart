// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.12

import 'dart:async';
import 'dart:math';

import 'package:gcloud/service_scope.dart' as ss;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

// ignore: import_of_legacy_library_into_null_safe
import '../package/models.dart' show Package;
import '../shared/datastore.dart';
import '../shared/exceptions.dart';
import '../shared/scheduler_stats.dart';
import '../shared/task_scheduler.dart';
import '../shared/task_sources.dart';

import 'backend.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'search_service.dart';

final Logger _logger = Logger('pub.search.updater');

/// Sets the index updater.
void registerIndexUpdater(IndexUpdater updater) =>
    ss.register(#_indexUpdater, updater);

/// The active index updater.
IndexUpdater get indexUpdater => ss.lookup(#_indexUpdater) as IndexUpdater;

class IndexUpdater implements TaskRunner {
  final DatastoreDB _db;
  final PackageIndex _packageIndex;
  Timer? _statsTimer;

  IndexUpdater(this._db, this._packageIndex);

  /// Loads the package index snapshot, or if it fails, creates a minimal
  /// package index with only package names and minimal information.
  Future<void> init() async {
    final isReady = await _initSnapshot();
    if (!isReady) {
      _logger.info('Loading minimum package index...');
      int cnt = 0;
      await for (final pd in searchBackend.loadMinimumPackageIndex()) {
        await _packageIndex.addPackage(pd);
        cnt++;
        if (cnt % 500 == 0) {
          _logger.info('Loaded $cnt minimum package data (${pd.package})');
        }
      }
      await _packageIndex.markReady();
      _logger.info('Minimum package index loaded with $cnt packages.');
    }
    snapshotStorage.startTimer();
  }

  /// Updates all packages in the index.
  /// It is slower than searchBackend.loadMinimum_packageIndex, but provides a
  /// complete document for the index.
  @visibleForTesting
  Future<void> updateAllPackages() async {
    await for (final p in _db.query<Package>().run()) {
      try {
        final doc = await searchBackend.loadDocument(p.name);
        await _packageIndex.addPackage(doc);
      } on RemovedPackageException catch (_) {
        await _packageIndex.removePackage(p.name);
      }
    }
    await _packageIndex.markReady();
  }

  /// Returns whether the snapshot was initialized and loaded properly.
  Future<bool> _initSnapshot() async {
    try {
      _logger.info('Loading snapshot...');
      await snapshotStorage.fetch();
      final documents = snapshotStorage.documents;
      await _packageIndex.addPackages(documents.values);
      // Arbitrary sanity check that the snapshot is not entirely bogus.
      // Index merge will enable search.
      if (documents.length > 10) {
        _logger.info('Merging index after snapshot.');
        await _packageIndex.markReady();
        _logger.info('Snapshot load completed.');
        return true;
      }
    } catch (e, st) {
      _logger.warning('Error while fetching snapshot.', e, st);
    }
    return false;
  }

  /// Starts the scheduler to update the package index.
  void runScheduler({required Stream<Task> manualTriggerTasks}) {
    final scheduler = TaskScheduler(
      this,
      [
        ManualTriggerTaskSource(manualTriggerTasks),
        DatastoreHeadTaskSource(
          _db,
          TaskSourceModel.package,
          sleep: const Duration(minutes: 10),
        ),
        DatastoreHeadTaskSource(
          _db,
          TaskSourceModel.scorecard,
          sleep: const Duration(minutes: 10),
          skipHistory: true,
        ),
        _PeriodicUpdateTaskSource(),
      ],
    );
    scheduler.run();

    _statsTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      updateLatestStats(scheduler.stats());
    });
  }

  Future<void> close() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    // TODO: close scheduler
  }

  @override
  Future<void> runTask(Task task) async {
    try {
      final sd = snapshotStorage.documents[task.package];

      // Skip tasks that originate before the current document in the snapshot
      // was created (e.g. the index and the snapshot was updated since the task
      // was created).
      // This preempts unnecessary work at startup (scanned Packages are updated
      // only if the index was not updated since the last snapshot), and also
      // deduplicates the periodic-updates which may not complete in 2 hours.
      if (sd != null && sd.timestamp.isAfter(task.updated)) return;

      final doc = await searchBackend.loadDocument(task.package);
      snapshotStorage.add(doc);
      await _packageIndex.addPackage(doc);
    } on RemovedPackageException catch (_) {
      _logger.info('Removing: ${task.package}');
      snapshotStorage.remove(task.package);
      await _packageIndex.removePackage(task.package);
    }
  }
}

/// A task source that generates an update task for stale documents.
///
/// It scans the current search snapshot every two hours, and selects the
/// packages that have not been updated in the last 24 hours.
class _PeriodicUpdateTaskSource implements TaskSource {
  @override
  Stream<Task> startStreaming() async* {
    for (;;) {
      await Future.delayed(Duration(hours: 2));
      final now = DateTime.now();
      final tasks = snapshotStorage.documents.values
          .where((pd) {
            final ageInMonths = now.difference(pd.updated ?? now).inDays ~/ 30;
            // Packages updated in the past two years will get updated daily,
            // each additional month adds an extra hour to the update time
            // difference. Neglected packages (after 14 years of the last update)
            // get refreshed in the index once in a week.
            final updatePeriodHours = max(24, min(ageInMonths, 7 * 24));
            return now.difference(pd.timestamp).inHours >= updatePeriodHours;
          })
          .map((pd) => Task(pd.package, pd.version, now))
          .toList();
      _logger
          .info('Periodic scheduler found ${tasks.length} packages to update.');
      for (Task task in tasks) {
        yield task;
      }
    }
  }
}
