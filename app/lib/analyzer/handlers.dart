// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.12

import 'dart:async';

// ignore: import_of_legacy_library_into_null_safe
import 'package:shelf/shelf.dart' as shelf;

import '../shared/handlers.dart';

/// Handlers for the analyzer service.
Future<shelf.Response> analyzerServiceHandler(shelf.Request request) async {
  final path = request.requestedUri.path;
  final handler = {
    '/debug': _debugHandler,
    '/liveness_check': (_) => htmlResponse('OK'),
    '/readiness_check': (_) => htmlResponse('OK'),
    '/robots.txt': rejectRobotsHandler,
  }[path];

  if (handler != null) {
    return handler(request);
  } else {
    return notFoundHandler(request);
  }
}

/// Handler /debug requests
shelf.Response _debugHandler(shelf.Request request) => debugResponse();
