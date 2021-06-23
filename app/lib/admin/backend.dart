// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.12

import 'dart:convert';

import 'package:client_data/admin_api.dart' as api;
import 'package:collection/collection.dart';
import 'package:convert/convert.dart';
import 'package:gcloud/service_scope.dart' as ss;
import 'package:gcloud/storage.dart';
import 'package:logging/logging.dart';
import 'package:pool/pool.dart';
import 'package:pub_semver/pub_semver.dart';

import '../account/backend.dart';
// ignore: import_of_legacy_library_into_null_safe
import '../account/models.dart';
import '../dartdoc/backend.dart';
import '../job/model.dart';
import '../package/backend.dart'
    show TarballStorage, checkPackageVersionParams, packageBackend;
// ignore: import_of_legacy_library_into_null_safe
import '../package/models.dart';
// ignore: import_of_legacy_library_into_null_safe
import '../publisher/models.dart';
// ignore: import_of_legacy_library_into_null_safe
import '../scorecard/models.dart';
// ignore: import_of_legacy_library_into_null_safe
import '../shared/configuration.dart';
import '../shared/datastore.dart';
import '../shared/exceptions.dart';
import '../shared/tags.dart';
import '../tool/utils/dart_sdk_version.dart';

final _logger = Logger('pub.admin.backend');
final _continuationCodec = utf8.fuse(hex);

/// Sets the admin backend service.
void registerAdminBackend(AdminBackend backend) =>
    ss.register(#_adminBackend, backend);

/// The active admin backend service.
AdminBackend get adminBackend => ss.lookup(#_adminBackend) as AdminBackend;

/// Represents the backend for the admin handling and authentication.
class AdminBackend {
  final DatastoreDB _db;
  AdminBackend(this._db);

  /// Require that the incoming request is authorized by an administrator with
  /// the given [permission].
  Future<User> _requireAdminPermission(AdminPermission permission) async {
    ArgumentError.checkNotNull(permission, 'permission');

    final user = await requireAuthenticatedUser();
    final admin = activeConfiguration.admins.firstWhereOrNull(
        (a) => a.oauthUserId == user.oauthUserId && a.email == user.email);
    if (admin == null || !admin.permissions.contains(permission)) {
      _logger.warning(
          'User (${user.userId} / ${user.email}) is trying to access unauthorized admin APIs.');
      throw AuthorizationException.userIsNotAdminForPubSite();
    }
    return user;
  }

  /// List users.
  ///
  ///
  Future<api.AdminListUsersResponse> listUsers({
    String? email,
    String? oauthUserId,
    String? continuationToken,
    int limit = 1000,
  }) async {
    InvalidInputException.checkRange(limit, 'limit', minimum: 1, maximum: 1000);
    await _requireAdminPermission(AdminPermission.listUsers);

    final query = _db.query<User>()..limit(limit);

    if (email != null) {
      InvalidInputException.checkNull(oauthUserId, '?ouid=');
      InvalidInputException.checkNull(continuationToken, '?ct=');
      query.filter('email =', email);
    } else if (oauthUserId != null) {
      InvalidInputException.checkNull(continuationToken, '?ct=');
      query.filter('oauthUserId =', oauthUserId);
    } else if (continuationToken != null) {
      String lastId;
      try {
        lastId = _continuationCodec.decode(continuationToken);
      } on FormatException catch (_) {
        throw InvalidInputException.continuationParseError();
      }
      InvalidInputException.checkNotNull(lastId, '?ct=');

      // NOTE: we should fix https://github.com/dart-lang/gcloud/issues/23
      //       and remove the toDatastoreKey conversion here.
      final key =
          _db.modelDB.toDatastoreKey(_db.emptyKey.append(User, id: lastId));
      query.filter('__key__ >', key);
      query.order('__key__');
    } else {
      query.order('__key__');
    }

    final users = await query.run().toList();
    // We may return a page with users less then a limit, but we always
    // set the continuation token to the correct value.
    final newContinuationToken = users.length < limit
        ? null
        : _continuationCodec.encode(users.last.userId);
    users.removeWhere((u) => u.isDeleted);

    return api.AdminListUsersResponse(
      users: users
          .map(
            (u) => api.AdminUserEntry(
              userId: u.userId,
              email: u.email,
              oauthUserId: u.oauthUserId,
            ),
          )
          .toList(),
      continuationToken: newContinuationToken,
    );
  }

  /// Removes user from the Datastore and updates the packages and other
  /// entities they may have controlled.
  Future<void> removeUser(String userId) async {
    final caller = await _requireAdminPermission(AdminPermission.removeUsers);
    final user = await accountBackend.lookupUserById(userId);
    if (user == null) return;
    if (user.isDeleted) return;

    _logger.info('${caller.userId} (${caller.email}) initiated the delete '
        'of ${user.userId} (${user.email})');

    // Package.uploaders
    final pool = Pool(10);
    final futures = <Future>[];
    final pkgQuery = _db.query<Package>()..filter('uploaders =', user.userId);
    await for (final p in pkgQuery.run()) {
      final f = pool
          .withResource(() => _removeUploaderFromPackage(p.key, user.userId));
      futures.add(f);
    }
    await Future.wait(futures);
    await pool.close();

    // PublisherMember
    // Publisher.contactEmail
    final memberQuery = _db.query<PublisherMember>()
      ..filter('userId =', user.userId);
    await for (final m in memberQuery.run()) {
      await _removeMember(user, m);
    }

    // Like
    await _removeAndDecrementLikes(user);

    // User
    // OAuthUserID
    // TODO: consider deleting User if there are no other references to it
    await _markUserDeleted(user);
  }

  // Remove like entities and decrement likes count on all packages liked by [user].
  Future<void> _removeAndDecrementLikes(User user) async {
    final pool = Pool(5);
    final futures = <Future>[];
    for (final like in await accountBackend.listPackageLikes(user)) {
      final f = pool
          .withResource(() => accountBackend.unlikePackage(user, like.package));
      futures.add(f);
    }
    await Future.wait(futures);
    await pool.close();
  }

  Future<void> _removeUploaderFromPackage(Key pkgKey, String userId) async {
    await withRetryTransaction(_db, (tx) async {
      final p = await tx.lookupValue<Package>(pkgKey);
      p.removeUploader(userId);
      if (p.uploaders.isEmpty) {
        p.isDiscontinued = true;
      }
      tx.insert(p);
    });
  }

  Future<void> _removeMember(User user, PublisherMember member) async {
    final seniorMember =
        await _remainingSeniorMember(member.publisherKey, member.userId);
    await withRetryTransaction(_db, (tx) async {
      final p = await tx.lookupValue<Publisher>(member.publisherKey);
      if (seniorMember == null) {
        p.isAbandoned = true;
        p.contactEmail = null;
        // TODO: consider deleting Publisher if there are no other references to it
      } else if (p.contactEmail == user.email) {
        final seniorUser =
            await accountBackend.lookupUserById(seniorMember.userId);
        p.contactEmail = seniorUser!.email;
      }
      tx.queueMutations(inserts: [p], deletes: [member.key]);
    });
    if (seniorMember == null) {
      // mark packages under the publisher discontinued
      final query = _db.query<Package>()
        ..filter('publisherId =', member.publisherId);
      final pool = Pool(4);
      final futures = <Future>[];
      await for (final package in query.run()) {
        if (package.isDiscontinued) continue;
        final f = pool.withResource(
          () => withRetryTransaction(_db, (tx) async {
            final p = await tx.lookupValue<Package>(package.key);
            p.isDiscontinued = true;
            tx.insert(p);
          }),
        );
        futures.add(f);
      }
      await Future.wait(futures);
      await pool.close();
    }
  }

  /// Returns the member of the publisher that (a) is not removed,
  /// (b) preferably is an admin, and (c) is member of the publisher for the
  /// longest time.
  ///
  /// If there are no more admins left, the "oldest" non-admin member is returned.
  Future<PublisherMember?> _remainingSeniorMember(
      Key publisherKey, String excludeUserId) async {
    final otherMembers = await _db
        .query<PublisherMember>(ancestorKey: publisherKey)
        .run()
        .where((m) => m.userId != excludeUserId)
        .toList();

    if (otherMembers.isEmpty) return null;

    // sort admins in the front, and on equal level sort by created time
    otherMembers.sort((a, b) {
      if (a.role == b.role) return a.created.compareTo(b.created);
      if (a.role == PublisherMemberRole.admin) return -1;
      if (b.role == PublisherMemberRole.admin) return 1;
      return a.created.compareTo(b.created);
    });

    return otherMembers.first;
  }

  Future<void> _markUserDeleted(User user) async {
    await withRetryTransaction(_db, (tx) async {
      final u = await tx.lookupValue<User>(user.key);
      final deleteKeys = <Key>[];
      if (user.oauthUserId != null) {
        final mappingKey =
            _db.emptyKey.append(OAuthUserID, id: user.oauthUserId);
        final mapping = (await tx.lookup<OAuthUserID>([mappingKey])).single;
        if (mapping != null) {
          deleteKeys.add(mappingKey);
        }
      }

      u
        ..oauthUserId = null
        ..created = null
        ..isDeleted = true;
      tx.queueMutations(inserts: [u], deletes: deleteKeys);
    });
  }

  /// Removes the package from the Datastore and updates other related
  /// entities. It is safe to call [removePackage] on an already removed
  /// package, as the call is idempotent.
  ///
  /// Creates a [ModeratedPackage] instance (if not already present) in
  /// Datastore representing the removed package. No new package with the same
  /// name can be published.
  Future<void> removePackage(String packageName) async {
    final caller = await _requireAdminPermission(AdminPermission.removePackage);

    _logger.info('${caller.userId} (${caller.email}) initiated the delete '
        'of package $packageName');

    List<Version>? versionsNames;
    await withRetryTransaction(_db, (tx) async {
      final deletes = <Key>[];
      final packageKey = _db.emptyKey.append(Package, id: packageName);
      final package = await tx.lookupOrNull<Package>(packageKey);
      if (package == null) {
        _logger
            .info('Package $packageName not found. Removing related elements.');
      } else {
        deletes.add(packageKey);
      }

      final versionsQuery = tx.query<PackageVersion>(packageKey);
      final versions = await versionsQuery.run().toList();
      // The delete package operation could be aborted after the `PackageVersion`
      // entries are deleted, but before the archives are started.
      // TODO: when this list is empty, query other related entities to fetch the versions
      versionsNames = versions.map((v) => v.semanticVersion).toList();
      deletes.addAll(versions.map((v) => v.key));

      final moderatedPkgKey =
          _db.emptyKey.append(ModeratedPackage, id: packageName);
      ModeratedPackage? moderatedPkg =
          await _db.lookupOrNull<ModeratedPackage>(moderatedPkgKey);
      if (moderatedPkg == null) {
        moderatedPkg = ModeratedPackage()
          ..parentKey = _db.emptyKey
          ..id = packageName
          ..name = packageName
          ..moderated = DateTime.now().toUtc()
          ..versions = versions.map((v) => v.version).toList()
          ..publisherId = package?.publisherId
          ..uploaders = package?.uploaders;

        _logger.info('Adding package to moderated packages ...');
      }
      tx.queueMutations(deletes: deletes, inserts: [moderatedPkg]);
    });

    final pool = Pool(10);
    final futures = <Future>[];
    final TarballStorage storage = TarballStorage(storageService,
        storageService.bucket(activeConfiguration.packageBucketName), '');
    versionsNames!.forEach((final v) {
      final future = pool.withResource(() async {
        await storage.remove(packageName, v.toString());
      });
      futures.add(future);
    });
    await Future.wait(futures);
    await pool.close();

    _logger.info('Removing package from dartdoc backend ...');
    await dartdocBackend.removeAll(packageName, concurrency: 32);

    _logger.info('Removing package from PackageVersionInfo ...');
    await _deleteWithQuery(
        _db.query<PackageVersionInfo>()..filter('package =', packageName));

    _logger.info('Removing package from PackageVersionAsset ...');
    await _deleteWithQuery(
        _db.query<PackageVersionAsset>()..filter('package =', packageName));

    _logger.info('Removing package from Jobs ...');
    await _deleteWithQuery(
        _db.query<Job>()..filter('packageName =', packageName));

    _logger.info('Removing package from ScoreCardReport ...');
    await _deleteWithQuery(
        _db.query<ScoreCardReport>()..filter('packageName =', packageName));

    _logger.info('Removing package from ScoreCard ...');
    await _deleteWithQuery(
        _db.query<ScoreCard>()..filter('packageName =', packageName));

    _logger.info('Removing package from Like ...');
    await _deleteWithQuery(
        _db.query<Like>()..filter('packageName =', packageName));

    _logger.info('Package "$packageName" got successfully removed.');
    _logger.info(
        'NOTICE: Redis caches referencing the package will expire given time.');
  }

  /// Removes the specific package version from the Datastore and updates other
  /// related entities. It is safe to call [removePackageVersion] on an already
  /// removed version, as the call is idempotent.
  Future<void> removePackageVersion(String packageName, String version) async {
    final caller = await _requireAdminPermission(AdminPermission.removePackage);

    _logger.info('${caller.userId} (${caller.email}) initiated the delete '
        'of package $packageName $version');

    final currentDartSdk = await getDartSdkVersion();
    await withRetryTransaction(_db, (tx) async {
      final Key packageKey = _db.emptyKey.append(Package, id: packageName);
      final package = await tx.lookupOrNull<Package>(packageKey);
      if (package == null) {
        print('Package $packageName does not exist.');
      }

      final versionsQuery = tx.query<PackageVersion>(packageKey);
      final versions = await versionsQuery.run().toList();
      final versionNames = versions.map((v) => v.version).toList();
      if (versionNames.contains(version)) {
        tx.delete(packageKey.append(PackageVersion, id: version));
      } else {
        print('Package $packageName does not have a version $version.');
      }

      if (versionNames.length == 1 && versionNames.single == version) {
        throw Exception(
            'Last version detected. Use full package removal without the version qualifier.');
      }

      bool updatePackage = false;
      if (package != null && package.latestVersion == version) {
        package.latestVersionKey = null;
        package.latestPublished = null;
        updatePackage = true;
      }
      if (package != null && package.latestPrereleaseVersion == version) {
        package.latestPrereleaseVersionKey = null;
        package.latestPrereleasePublished = null;
        updatePackage = true;
      }
      if (package != null && package.latestPreviewVersion == version) {
        package.latestPreviewVersionKey = null;
        package.latestPreviewPublished = null;
      }
      if (updatePackage) {
        package!.lastVersionPublished = null;
        versions.where((v) => v.version != version).forEach((v) => package
            .updateVersion(v, dartSdkVersion: currentDartSdk.semanticVersion));
        package.updated = DateTime.now().toUtc();
        tx.insert(package);
      }
    });

    final bucket = storageService.bucket(activeConfiguration.packageBucketName);
    final storage = TarballStorage(storageService, bucket, '');
    print('Removing GCS objects ...');
    await storage.remove(packageName, version);

    await dartdocBackend.removeAll(packageName, version: version);

    await _deleteWithQuery(
      _db.query<PackageVersionInfo>()..filter('package =', packageName),
      where: (PackageVersionInfo info) => info.version == version,
    );

    await _deleteWithQuery(
      _db.query<PackageVersionAsset>()..filter('package =', packageName),
      where: (PackageVersionAsset asset) => asset.version == version,
    );

    await _deleteWithQuery(
      _db.query<Job>()..filter('packageName =', packageName),
      where: (Job job) => job.packageVersion == version,
    );
  }

  Future _deleteWithQuery<T>(Query query,
      {bool Function(T item)? where}) async {
    final deletes = <Key>[];
    await for (Model m in query.run()) {
      final shouldDelete = where == null || where(m as T);
      if (shouldDelete) {
        deletes.add(m.key);
        if (deletes.length >= 500) {
          await _db.commit(deletes: deletes);
          deletes.clear();
        }
      }
    }
    if (deletes.isNotEmpty) {
      await _db.commit(deletes: deletes);
    }
  }

  /// Handles GET '/api/admin/packages/<package>/assigned-tags'
  ///
  /// Note, this API end-point is intentioanlly locked down even if it doesn't
  /// return anything secret. This is because the /admin/ section is only
  /// intended to be exposed to administrators. Users can read the assigned-tags
  /// through API that returns list of package tags.
  Future<api.AssignedTags> handleGetAssignedTags(
    String packageName,
  ) async {
    checkPackageVersionParams(packageName);
    await _requireAdminPermission(AdminPermission.manageAssignedTags);
    final package = await packageBackend.lookupPackage(packageName);
    if (package == null) {
      throw NotFoundException.resource(packageName);
    }

    return api.AssignedTags(
      assignedTags: package.assignedTags,
    );
  }

  /// Handles POST '/api/admin/packages/<package>/assigned-tags'
  Future<api.AssignedTags> handlePostAssignedTags(
    String packageName,
    api.PatchAssignedTags body,
  ) async {
    await _requireAdminPermission(AdminPermission.manageAssignedTags);

    InvalidInputException.check(
      body.assignedTagsAdded
          .every((tag) => allowedTagPrefixes.any(tag.startsWith)),
      'Only following tag-prefixes are allowed "${allowedTagPrefixes.join("\", ")}"',
    );
    InvalidInputException.check(
      body.assignedTagsAdded
          .toSet()
          .intersection(body.assignedTagsRemoved.toSet())
          .isEmpty,
      'assignedTagsAdded cannot contain tags also removed assignedTagsRemoved',
    );

    return await withRetryTransaction(_db, (tx) async {
      final package = await tx.lookupOrNull<Package>(_db.emptyKey.append(
        Package,
        id: packageName,
      ));

      if (package == null) {
        throw NotFoundException.resource(packageName);
      }

      if (package.assignedTags.any(body.assignedTagsRemoved.contains) ||
          !body.assignedTagsAdded.every(package.assignedTags.contains)) {
        package.assignedTags
          ..removeWhere(body.assignedTagsRemoved.contains)
          ..addAll(body.assignedTagsAdded);
        package.updated = DateTime.now().toUtc();
        tx.insert(package);
      }

      return api.AssignedTags(
        assignedTags: package.assignedTags,
      );
    });
  }

  /// Handles GET '/api/admin/packages/<package>/uploaders'
  ///
  /// Returns the list of uploaders for a package.
  Future<api.PackageUploaders> handleGetPackageUploaders(
    String packageName,
  ) async {
    checkPackageVersionParams(packageName);
    await _requireAdminPermission(AdminPermission.managePackageOwnership);
    final package = await packageBackend.lookupPackage(packageName);
    if (package == null) {
      throw NotFoundException.resource(packageName);
    }
    InvalidInputException.check(
        package.publisherId == null, 'Package must not be under a publisher.');

    final uploaders = <api.AdminUserEntry>[];
    for (final userId in package.uploaders) {
      final email = await accountBackend.getEmailOfUserId(userId);
      uploaders.add(api.AdminUserEntry(userId: userId, email: email));
    }
    return api.PackageUploaders(uploaders: uploaders);
  }
}
