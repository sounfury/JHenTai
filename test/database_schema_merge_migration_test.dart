import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late Directory tempDir;
  late LogService originalLog;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'jhentai-schema-merge-migration-',
    );
    pathService.tempDir = tempDir;
    originalLog = log;
    log = LogService()..logDirPath = '${tempDir.path}/logs';
  });

  tearDown(() async {
    await log.clear();
    log = originalLog;
    for (int attempt = 0; ; attempt++) {
      try {
        await tempDir.delete(recursive: true);
        break;
      } on FileSystemException catch (error) {
        if (!Platform.isWindows || error.osError?.errorCode != 32 || attempt >= 9) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  Future<File> createCurrentDatabase() async {
    final File file = File('${tempDir.path}${Platform.pathSeparator}db.sqlite');
    final AppDb db = AppDb(executor: NativeDatabase(file));
    await db.customSelect('SELECT 1').getSingle();
    await db.close();
    return file;
  }

  Future<void> expectMergedSchema(File file) async {
    final AppDb db = AppDb(executor: NativeDatabase.createInBackground(file));
    try {
      await db.customSelect('SELECT 1').getSingle();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], 27);

      final tables =
          await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type = 'table' "
                "AND name = 'smart_cache_stat'",
              )
              .get();
      expect(tables.map((row) => row.data['name']).toSet(), {
        'smart_cache_stat',
      });

      final imageColumns =
          await db.customSelect('PRAGMA table_info(image)').get();
      expect(
        imageColumns.map((row) => row.data['name']),
        contains('originalImageUrl'),
      );
    } finally {
      await db.close();
    }
  }

  test(
    'upstream schema 25 gains smart cache without duplicating image column',
    () async {
      final File file = await createCurrentDatabase();
      final sqlite.Database raw = sqlite.sqlite3.open(file.path);
      try {
        raw.execute('DROP TABLE smart_cache_stat');
        raw.execute('DROP TABLE IF EXISTS reader_bookmark');
        raw.execute('PRAGMA user_version = 25');
      } finally {
        raw.dispose();
      }

      await expectMergedSchema(file);
    },
  );

  test(
    'Fork schema 26 gains upstream image column and retains legacy data',
    () async {
      final File file = await createCurrentDatabase();
      final sqlite.Database raw = sqlite.sqlite3.open(file.path);
      try {
        raw.execute('ALTER TABLE image DROP COLUMN originalImageUrl');
        raw.execute(
          'CREATE TABLE reader_bookmark (gallery_key TEXT, page_index INTEGER, note TEXT)',
        );
        raw.execute(
          "INSERT INTO reader_bookmark VALUES ('legacy-gallery', 2, 'legacy-note')",
        );
        raw.execute('PRAGMA user_version = 26');
      } finally {
        raw.dispose();
      }

      await expectMergedSchema(file);
      final sqlite.Database migrated = sqlite.sqlite3.open(file.path);
      try {
        expect(
          migrated.select('SELECT note FROM reader_bookmark').single['note'],
          'legacy-note',
        );
      } finally {
        migrated.dispose();
      }
    },
  );

  test(
    'mixed schema 26 with the image column already present upgrades cleanly',
    () async {
      final File file = await createCurrentDatabase();
      final sqlite.Database raw = sqlite.sqlite3.open(file.path);
      try {
        raw.execute('PRAGMA user_version = 26');
      } finally {
        raw.dispose();
      }

      await expectMergedSchema(file);
    },
  );
}
