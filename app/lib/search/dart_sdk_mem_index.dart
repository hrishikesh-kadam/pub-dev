// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.12

import 'package:gcloud/service_scope.dart' as ss;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:retry/retry.dart';

import '../shared/cached_value.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'models.dart';
import 'sdk_mem_index.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'search_service.dart';

final _logger = Logger('search.dart_sdk_mem_index');

/// Sets the Dart SDK in-memory index.
void registerDartSdkMemIndex(DartSdkMemIndex updater) =>
    ss.register(#_dartSdkMemIndex, updater);

/// The active Dart SDK in-memory index.
DartSdkMemIndex get dartSdkMemIndex =>
    ss.lookup(#_dartSdkMemIndex) as DartSdkMemIndex;

/// Dart SDK in-memory index that fetches `index.json` from
/// api.dart.dev and returns search results based on [SdkMemIndex].
class DartSdkMemIndex {
  final _index = CachedValue<SdkMemIndex>(
    name: 'dart-sdk-index',
    interval: Duration(days: 1),
    maxAge: Duration(days: 30),
    timeout: Duration(hours: 1),
    updateFn: _createDartSdkMemIndex,
  );

  Future<void> start() async {
    await _index.start();
  }

  Future<void> close() async {
    await _index.close();
  }

  Future<List<SdkLibraryHit>> search(String query, {int? limit}) async {
    if (!_index.isAvailable) return <SdkLibraryHit>[];
    return await _index.value!.search(query, limit: limit);
  }

  @visibleForTesting
  void setDartdocIndex(DartdocIndex index, {String? version}) {
    final smi = SdkMemIndex.dart(version: version);
    smi.addDartdocIndex(index);
    // ignore: invalid_use_of_visible_for_testing_member
    _index.setValue(smi);
  }
}

Future<SdkMemIndex?> _createDartSdkMemIndex() async {
  try {
    return await retry(
      () async {
        final index = SdkMemIndex.dart();
        final uri = index.baseUri.resolve('index.json');
        final rs = await http.get(uri);
        if (rs.statusCode != 200) {
          throw Exception('Unexpected status code for $uri: ${rs.statusCode}');
        }
        final content = DartdocIndex.parseJsonText(rs.body);
        await index.addDartdocIndex(content);
        return index;
      },
      maxAttempts: 3,
    );
  } catch (e, st) {
    _logger.warning('Unable to load Dart SDK index.', e, st);
    return null;
  }
}
