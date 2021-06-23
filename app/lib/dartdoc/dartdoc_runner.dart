// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.12

import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:pana/pana.dart' hide Pubspec, ReportStatus;
import 'package:path/path.dart' as p;

import 'package:pub_dartdoc_data/pub_dartdoc_data.dart';
import 'package:tar/tar.dart';

import '../frontend/static_files.dart';
import '../job/backend.dart';
import '../job/job.dart';
import '../package/backend.dart';
// ignore: import_of_legacy_library_into_null_safe
import '../package/models.dart';
import '../scorecard/backend.dart';
// ignore: import_of_legacy_library_into_null_safe
import '../scorecard/models.dart';
// ignore: import_of_legacy_library_into_null_safe
import '../shared/configuration.dart';
import '../shared/env_config.dart';
import '../shared/tool_env.dart';
import '../shared/urls.dart';
import '../shared/utils.dart' show createUuid;
import '../shared/versions.dart' as versions;

import 'backend.dart';
import 'customization.dart';
import 'dartdoc_options.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'models.dart';

final Logger _logger = Logger('pub.dartdoc.runner');

const statusFilePath = 'status.json';
const _archiveFilePath = 'package.tar.gz';
const _buildLogFilePath = 'log.txt';
const _packageTimeout = Duration(minutes: 10);
final _packageTimeoutExtended = _packageTimeout * 2;
const _pubDataFileName = 'pub-data.json';
final Duration _twoYears = const Duration(days: 2 * 365);

/// Generic interface to run dartdoc for SDK- and package-documentation.
abstract class DartdocRunner {
  Future<void> downloadAndExtract({
    required String package,
    required String version,
    required String destination,
  });

  Future<ProcessResult> runPubUpgrade({
    required ToolEnvironment toolEnv,
    required String pkgPath,
    required bool usesFlutter,
  });

  Future<DartdocRunnerResult> generatePackageDocs({
    required String package,
    required String version,
    required String pkgPath,
    required String canonicalUrl,
    required bool usesPreviewSdk,
    required ToolEnvironment toolEnv,
    required bool useLongerTimeout,
    required String outputDir,
  });
}

class DartdocRunnerResult {
  final List<String> args;
  final ProcessResult processResult;

  DartdocRunnerResult({
    required this.args,
    required this.processResult,
  });
}

class _DartdocRunner implements DartdocRunner {
  bool _initialized = false;

  Future<void> _initializeIfNeeded() async {
    if (_initialized) return;
    await runProc(
      ['dart', 'pub', 'get'],
      workingDirectory: resolvePubDartdocDirPath(),
    );
    _initialized = true;
  }

  @override
  Future<void> downloadAndExtract({
    required String package,
    required String version,
    required String destination,
  }) async {
    await downloadPackage(
      package,
      version,
      destination: destination,
      pubHostedUrl: activeConfiguration.primarySiteUri.toString(),
    );
  }

  @override
  Future<ProcessResult> runPubUpgrade({
    required ToolEnvironment toolEnv,
    required String pkgPath,
    required bool usesFlutter,
  }) async {
    return await toolEnv.runUpgrade(pkgPath, usesFlutter);
  }

  @override
  Future<DartdocRunnerResult> generatePackageDocs({
    required String package,
    required String version,
    required String pkgPath,
    required String canonicalUrl,
    required bool usesPreviewSdk,
    required ToolEnvironment toolEnv,
    required bool useLongerTimeout,
    required String outputDir,
  }) async {
    await _initializeIfNeeded();
    final args = [
      '--input',
      pkgPath,
      '--output',
      outputDir,
      '--rel-canonical-prefix',
      canonicalUrl,
      '--no-validate-links',
    ];
    if (toolEnv.dartSdkDir != null) {
      args.addAll(['--sdk-dir', toolEnv.dartSdkDir!]);
    }
    final flutterRoot = usesPreviewSdk
        ? envConfig.previewFlutterSdkDir
        : envConfig.stableFlutterSdkDir;
    final environment = <String, String>{
      'PUB_HOSTED_URL': activeConfiguration.primaryApiUri.toString(),
      if (flutterRoot != null) 'FLUTTER_ROOT': flutterRoot,
    };
    final dartCmd = p.join(toolEnv.dartSdkDir!, 'bin', 'dart');
    final pr = await runProc(
      [dartCmd, 'bin/pub_dartdoc.dart', ...args],
      environment: environment,
      workingDirectory: resolvePubDartdocDirPath(),
      timeout: useLongerTimeout ? _packageTimeoutExtended : _packageTimeout,
    );
    return DartdocRunnerResult(args: args, processResult: pr);
  }
}

class DartdocJobProcessor extends JobProcessor {
  final DartdocRunner _runner;

  DartdocJobProcessor({
    DartdocRunner? runner,
    required AliveCallback? aliveCallback,
  })  : _runner = runner ?? _DartdocRunner(),
        super(
          service: JobService.dartdoc,
          aliveCallback: aliveCallback,
        );

  @override
  Future<bool> shouldProcess(PackageVersion pv, DateTime updated) {
    return scoreCardBackend.shouldUpdateReport(
      pv,
      ReportType.dartdoc,
      updatedAfter: updated,
    );
  }

  @override
  Future<JobStatus> process(Job job) async {
    final packageStatus = await scoreCardBackend.getPackageStatus(
        job.packageName!, job.packageVersion!);
    // In case the package was deleted between scheduling and the actual delete.
    if (!packageStatus.exists) {
      _logger.info('Package does not exist: $job.');
      return JobStatus.skipped;
    }

    // We know that dartdoc will fail on this package, no reason to run it.
    if (packageStatus.isLegacy) {
      _logger.info('Package is on legacy SDK: $job.');
      await _storeScoreCard(job, _emptyReport());
      return JobStatus.skipped;
    }

    // Do not check for discontinued status, we still generate documentation for
    // such packages.

    if (packageStatus.isObsolete) {
      _logger
          .info('Package is older than two years and has newer release: $job.');
      await _storeScoreCard(job, _emptyReport());
      return JobStatus.skipped;
    }

    final logger =
        Logger('pub.dartdoc.runner/${job.packageName}/${job.packageVersion}');
    final tempDir =
        await Directory.systemTemp.createTemp('pub-dartlang-dartdoc');
    final tempDirPath = tempDir.resolveSymbolicLinksSync();
    final pkgPath = p.join(tempDirPath, 'pkg');
    final tarDir = p.join(tempDirPath, 'output');
    final outputDir = p.join(tarDir, job.packageName, job.packageVersion);

    // directories need to be created
    await Directory(outputDir).create(recursive: true);
    await Directory(pkgPath).create(recursive: true);

    final latestVersion =
        await packageBackend.getLatestVersion(job.packageName!);
    final bool isLatestStable = latestVersion == job.packageVersion;
    bool depsResolved = false;
    DartdocResult? dartdocResult;
    bool hasContent = false;
    PubDartdocData? dartdocData;

    String reportStatus = ReportStatus.failed;
    String? abortMessage;
    DartdocEntry? entry;
    try {
      await withToolEnv(
        usesPreviewSdk: packageStatus.usesPreviewSdk,
        fn: (toolEnv) async {
          final sw = Stopwatch()..start();
          final usesFlutter = packageStatus.usesFlutter;

          final logFileOutput = StringBuffer();
          logFileOutput.write('Dartdoc generation for $job\n\n'
              'runtime: ${versions.runtimeVersion}\n'
              'runtime Dart SDK: ${versions.runtimeSdkVersion}\n'
              'dartdoc: ${versions.dartdocVersion}\n'
              'pana: ${versions.panaVersion}\n'
              'toolEnv Dart SDK: ${toolEnv.runtimeInfo.sdkVersion}\n'
              'usesFlutter: $usesFlutter\n'
              'flutter: ${toolEnv.runtimeInfo.flutterVersions}\n'
              'started: ${DateTime.now().toUtc().toIso8601String()}\n\n');

          await _runner.downloadAndExtract(
            package: job.packageName!,
            version: job.packageVersion!,
            destination: pkgPath,
          );

          // Resolve dependencies only for non-legacy package versions.
          if (!packageStatus.isLegacy) {
            final output = await _resolveDependencies(
                logger, toolEnv, job, pkgPath, usesFlutter, logFileOutput);
            depsResolved = output == null;
            abortMessage ??= output;
          } else {
            logFileOutput.write(
                'Package version does not allow current SDK, skipping pub upgrade.\n\n');
          }

          // Generate docs only for packages that have healthy dependencies.
          if (depsResolved) {
            dartdocResult = await _generateDocs(
                toolEnv, logger, job, pkgPath, outputDir, logFileOutput,
                usesPreviewSdk: packageStatus.usesPreviewSdk);
            hasContent =
                dartdocResult!.hasIndexHtml && dartdocResult!.hasIndexJson;
          } else {
            logFileOutput
                .write('Dependencies were not resolved, skipping dartdoc.\n\n');
          }

          if (hasContent) {
            try {
              await DartdocCustomizer(job.packageName!, job.packageVersion!,
                      job.isLatestStable!)
                  .customizeDir(outputDir);
              logFileOutput.write('Content customization completed.\n\n');
            } catch (e, st) {
              // Do not block on customization failure.
              _logger.severe('Dartdoc customization failed ($job).', e, st);
              logFileOutput.write('Content customization failed.\n\n');
            }

            await _tar(tempDirPath, tarDir, outputDir, logFileOutput);
          } else {
            logFileOutput.write('No content found!\n\n');
          }

          entry = await _createEntry(toolEnv, job, outputDir, usesFlutter,
              depsResolved, hasContent, sw.elapsed);
          logFileOutput
              .write('entry created: ${entry!.uuid} in ${sw.elapsed}\n\n');

          logFileOutput
              .write('completed: ${entry!.timestamp.toIso8601String()}\n');
          await _writeLog(outputDir, logFileOutput);
        },
      );

      final oldEntry =
          await dartdocBackend.getEntry(job.packageName!, job.packageVersion!);
      if (entry!.isRegression(oldEntry)) {
        logger.severe('Regression detected in $job, aborting upload.');
        // If `isLatest` has changed, we still want to update the old entry,
        // even if the job failed. `isLatest` is used to redirect latest
        // versions from versioned url to url with `/latest/`, and this
        // is cheaper than checking it on each request.
        if (oldEntry!.isLatest != entry!.isLatest) {
          await dartdocBackend.updateOldIsLatest(oldEntry,
              isLatest: entry!.isLatest);
        }
      } else {
        await dartdocBackend.uploadDir(entry!, outputDir);
        reportStatus = hasContent ? ReportStatus.success : ReportStatus.failed;
      }

      if (!hasContent && isLatestStable) {
        reportIssueWithLatest(job, 'No content.');
      }

      dartdocData = await _loadPubDartdocData(logger, outputDir);
    } catch (e, st) {
      reportStatus = ReportStatus.aborted;
      if (isLatestStable) {
        reportIssueWithLatest(job, '$e\n$st');
      }
      abortMessage ??=
          'Running `dartdoc` failed with the following error: `$e`\n\n```\n$st\n```\n';
    } finally {
      await tempDir.delete(recursive: true);
    }

    final coverage = dartdocData?.coverage;
    ReportSection documentationSection;
    if (hasContent && coverage != null) {
      documentationSection = documentationCoverageSection(
        documented: coverage.documented,
        total: coverage.total,
      );
    } else {
      if (dartdocResult != null && dartdocResult!.wasTimeout) {
        abortMessage ??= '`dartdoc` timed out.';
      }
      if (abortMessage == null && dartdocResult != null) {
        final output =
            _mergeOutput(dartdocResult!.processResult, compress: true);
        abortMessage = '`dartdoc` failed with:\n\n```\n$output\n```';
      }
      abortMessage ??= '`dartdoc` failed with unknown reason.';
      documentationSection = dartdocFailedSection(abortMessage!);
    }
    await _storeScoreCard(
        job,
        DartdocReport(
          timestamp: DateTime.now().toUtc(),
          reportStatus: reportStatus,
          dartdocEntry: entry,
          documentationSection: documentationSection,
        ));

    if (abortMessage != null) {
      return JobStatus.aborted;
    } else {
      return hasContent ? JobStatus.success : JobStatus.failed;
    }
  }

  Future _storeScoreCard(Job job, DartdocReport report) async {
    await scoreCardBackend.updateReportOnCard(
        job.packageName!, job.packageVersion!,
        dartdocReport: report);
  }

  Future<String?> _resolveDependencies(
      Logger logger,
      ToolEnvironment toolEnv,
      Job job,
      String pkgPath,
      bool usesFlutter,
      StringBuffer logFileOutput) async {
    logFileOutput.write('Running pub upgrade:\n');
    final pr = await _runner.runPubUpgrade(
        toolEnv: toolEnv, pkgPath: pkgPath, usesFlutter: usesFlutter);
    _appendLog(logFileOutput, pr);
    if (pr.exitCode != 0) {
      final message = pr.stderr.toString();
      final isUserProblem = message.contains('version solving failed') ||
          message.contains('Git error.');
      final output = _mergeOutput(pr, compress: true);
      if (!isUserProblem) {
        logger.warning('Error while running pub upgrade for $job.\n$output');
      }
      return 'Failed to resolve dependencies.\n\n```$output```';
    }
    return null;
  }

  Future<DartdocResult> _generateDocs(
    ToolEnvironment toolEnv,
    Logger logger,
    Job job,
    String pkgPath,
    String outputDir,
    StringBuffer logFileOutput, {
    required bool usesPreviewSdk,
  }) async {
    logFileOutput.write('Running dartdoc:\n');
    final canonicalVersion =
        job.isLatestStable! ? 'latest' : job.packageVersion;
    final canonicalUrl = pkgDocUrl(job.packageName!,
        version: canonicalVersion, includeHost: true, omitTrailingSlash: true);

    // Create and/or customize dartdoc_options.yaml
    final optionsFile = File(p.join(pkgPath, 'dartdoc_options.yaml'));
    Map<String, dynamic>? originalContent;
    if (await optionsFile.exists()) {
      final content = await optionsFile.readAsString();
      try {
        originalContent = yamlToJson(content);
      } catch (_) {
        // ignore parse errors
      }
    }
    final updatedContent = customizeDartdocOptions(originalContent);
    await optionsFile.writeAsString(convert.json.encode(updatedContent));

    /// When [isReduced] is set, we are running dartdoc with reduced features,
    /// hopefully to complete within the time limit and fewer issues.
    Future<DartdocResult> runDartdoc() async {
      final result = await _runner.generatePackageDocs(
        package: job.packageName!,
        version: job.packageVersion!,
        pkgPath: pkgPath,
        canonicalUrl: canonicalUrl,
        usesPreviewSdk: usesPreviewSdk,
        toolEnv: toolEnv,
        useLongerTimeout: job.isLatest,
        outputDir: outputDir,
      );
      logFileOutput.writeln('Running: pub_dartdoc ${result.args.join(' ')}');
      final pr = result.processResult;
      final hasIndexHtml = await File(p.join(outputDir, 'index.html')).exists();
      final hasIndexJson = await File(p.join(outputDir, 'index.json')).exists();
      final stdoutStr = pr.stdout.toString();
      return DartdocResult(
        pr,
        pr.exitCode == 15 ||
            pr.exitCode == -9 ||
            (pr.exitCode != 0 && stdoutStr.contains('timeout')),
        hasIndexHtml,
        hasIndexJson,
      );
    }

    final sw = Stopwatch()..start();
    final r = await runDartdoc();
    sw.stop();
    logger.info('Running dartdoc for ${job.packageName} ${job.packageVersion} '
        'completed in ${sw.elapsed}.');

    _appendLog(logFileOutput, r.processResult);
    final hasContent = r.hasIndexHtml && r.hasIndexJson;

    if (r.processResult.exitCode != 0) {
      if (hasContent ||
          r.wasTimeout ||
          _isKnownFailurePattern(_mergeOutput(r.processResult))) {
        logger.info('Error while running dartdoc for $job (see log.txt).');
      } else {
        final output = _mergeOutput(r.processResult, compress: true);
        logger.warning('Error while running dartdoc for $job.\n$output');
      }
    }

    return r;
  }

  Future<DartdocEntry> _createEntry(
      ToolEnvironment toolEnv,
      Job job,
      String outputDir,
      bool usesFlutter,
      bool depsResolved,
      bool hasContent,
      Duration runDuration) async {
    int? archiveSize;
    int? totalSize;
    if (hasContent) {
      final archiveFile = File(p.join(outputDir, _archiveFilePath));
      archiveSize = await archiveFile.length();
      totalSize = await Directory(outputDir)
          .list(recursive: true)
          .where((fse) => fse is File)
          .cast<File>()
          .asyncMap((file) => file.length())
          .fold<int>(0, (a, b) => a + b);
      totalSize = totalSize - archiveSize;
    }
    final now = DateTime.now();
    final isObsolete = job.isLatestStable == false &&
        job.packageVersionUpdated!.difference(now).abs() > _twoYears;
    final entry = DartdocEntry(
      uuid: createUuid(),
      packageName: job.packageName,
      packageVersion: job.packageVersion,
      isLatest: job.isLatestStable,
      isObsolete: isObsolete,
      usesFlutter: usesFlutter,
      runtimeVersion: versions.runtimeVersion,
      sdkVersion: toolEnv.runtimeInfo.sdkVersion,
      dartdocVersion: versions.dartdocVersion,
      flutterVersion: toolEnv.runtimeInfo.flutterVersion,
      timestamp: DateTime.now().toUtc(),
      runDuration: runDuration,
      depsResolved: depsResolved,
      hasContent: hasContent,
      archiveSize: archiveSize,
      totalSize: totalSize,
    );

    // write entry into local file
    await File(p.join(outputDir, statusFilePath)).writeAsBytes(entry.asBytes());

    return entry;
  }

  Future<void> _writeLog(String outputDir, StringBuffer buffer) async {
    await File(p.join(outputDir, _buildLogFilePath))
        .writeAsString(buffer.toString());
  }

  void _appendLog(StringBuffer buffer, ProcessResult pr) {
    buffer.write('STDOUT:\n${pr.stdout}\n\n');
    buffer.write('STDERR:\n${pr.stderr}\n\n');
    buffer.write('exit code: ${pr.exitCode}\n');
  }

  Future<void> _tar(String tmpDir, String tarDir, String outputDir,
      StringBuffer logFileOutput) async {
    logFileOutput.write('Creating package archive...\n');
    final sw = Stopwatch()..start();

    Stream<TarEntry> _list() async* {
      final dir = Directory(tarDir);
      await for (final entry in dir.list(recursive: true)) {
        if (entry is File) {
          final data = await entry.readAsBytes();
          yield TarEntry.data(
            TarHeader(
              name: p.relative(entry.path, from: dir.path),
              size: data.length,
            ),
            data,
          );
        }
      }
    }

    final tmpTar = File(p.join(tmpDir, _archiveFilePath));
    await _list()
        .transform(tarWriter)
        .transform(gzip.encoder)
        .pipe(tmpTar.openWrite());
    await tmpTar.rename(p.join(outputDir, _archiveFilePath));
    logFileOutput.write('Created package archive in ${sw.elapsed}.\n');
  }

  Future<PubDartdocData?> _loadPubDartdocData(
      Logger logger, String outputDir) async {
    final file = File(p.join(outputDir, _pubDataFileName));
    if (!file.existsSync()) {
      return null;
    }
    try {
      final content = await file.readAsString();
      return PubDartdocData.fromJson(
          convert.json.decode(content) as Map<String, dynamic>);
    } catch (e, st) {
      logger.warning('Unable to parse $_pubDataFileName.', e, st);
      return null;
    }
  }
}

bool _isKnownFailurePattern(String output) {
  // dartdoc throws a generic exception with unexpected analysis errors e.g.
  // it could have encountered a file parsing issue, or an invalid reference.
  if (output.contains('Unhandled exception:') &&
      output.contains('encountered ') &&
      output.contains(' analysis errors') &&
      output.contains('Dartdoc.logAnalysisErrors')) {
    return true;
  }
  // dartdoc throws this exception when the imported library doesn't exists.
  if (output.contains('fatal error: unable to locate the input directory at')) {
    return true;
  }
  // dartdoc_options.yaml references a file missing (usually outside of the published package).
  if (output.contains('categories definition') &&
      output.contains('resolves to the missing file')) {
    return true;
  }
  // pkg/pub_dartdoc reached file count or total length limit
  if (output.contains('Reached ') &&
      output.contains(' files in the output directory.')) {
    return true;
  }
  if (output.contains('Reached ') &&
      output.contains(' bytes in the output directory.')) {
    return true;
  }
  return false;
}

/// Merges the stdout and stderr of [ProcessResult] into a single String, which
/// can be used in log messages. For long output, set [compress] to true,
/// keeping only the beginning and the end of stdout/stderr.
String _mergeOutput(ProcessResult pr, {bool compress = false}) {
  String doCompress(String input) {
    if (compress) {
      final list = input.split('\n');
      if (list.length > 50) {
        return list.take(20).join('\n') +
            '\n[...]\n' +
            list.skip(list.length - 20).join('\n');
      }
    }
    return input;
  }

  final stdout = doCompress(pr.stdout.toString());
  final stderr = doCompress(pr.stderr.toString());
  return 'exitCode: ${pr.exitCode}\nstdout: $stdout\nstderr: $stderr\n';
}

DartdocReport _emptyReport() => DartdocReport(
      timestamp: DateTime.now().toUtc(),
      reportStatus: ReportStatus.aborted,
      dartdocEntry: null,
      // TODO: add meaningful message for missing documentation on dartdoc
      documentationSection: null,
    );
