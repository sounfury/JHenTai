import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/log.dart';

/// Services normally initialize logging through the app's PathService.
/// Isolated service tests instead own a temporary log directory.
void setUpTestLogging() {
  late LogService originalLog;
  late LogService testLog;
  late Directory directory;
  setUpAll(() async {
    originalLog = log;
    directory = await Directory.systemTemp.createTemp(
      'jh-translation-test-log-',
    );
    testLog = LogService()..logDirPath = '${directory.path}/logs';
    log = testLog;
  });
  tearDownAll(() async {
    await testLog.clear();
    log = originalLog;
    await directory.delete(recursive: true);
  });
}
