// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.12

// ignore: import_of_legacy_library_into_null_safe
import '../package/models.dart' show Package, PackageVersion;
import '../shared/datastore.dart' as db;
import '../shared/versions.dart' as versions;

// ignore: import_of_legacy_library_into_null_safe
import 'models.dart';

db.Key<String> scoreCardKey(
  String packageName,
  String packageVersion, {
  String? runtimeVersion,
}) {
  runtimeVersion ??= versions.runtimeVersion;
  return db.dbService.emptyKey
      .append(Package, id: packageName)
      .append(PackageVersion, id: packageVersion)
      .append(ScoreCard, id: runtimeVersion);
}
