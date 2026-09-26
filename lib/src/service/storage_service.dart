import 'dart:io';

import 'package:get_storage/get_storage.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:path/path.dart';

import 'log.dart';
import 'jh_service.dart';

StorageService storageService = StorageService();

class StorageService
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static const String storageFileName = 'jhentai';

  late final GetStorage _storage;

  @override
  Future<void> doInitBean() async {
    _migrateOldConfigFile();
    _storage = GetStorage(storageFileName, pathService.jhDataDir.path);
    await _storage.initStorage;
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<void> write(String key, dynamic value) {
    return _storage.write(key, value);
  }

  T? read<T>(String key) {
    return _storage.read(key);
  }

  T getKeys<T>() {
    return _storage.getKeys();
  }

  Future<void> remove(String key) async {
    _storage.remove(key);
  }

  void _migrateOldConfigFile() {
    try {
      File oldConfigFile =
          File(join(pathService.getVisibleDir().path, '.GetStorage.gs'));
      File oldBakFile =
          File(join(pathService.getVisibleDir().path, '.GetStorage.bak'));
      File targetGsFile = File(join(pathService.jhDataDir.path, 'jhentai.gs'));
      File targetBakFile = File(join(pathService.jhDataDir.path, 'jhentai.bak'));

      if (!targetGsFile.existsSync()) {
        File oldDirectGsFile = File(join(pathService.getVisibleDir().path, 'jhentai.gs'));
        if (oldDirectGsFile.existsSync()) {
          oldDirectGsFile.copySync(targetGsFile.path);
        }
      }
      if (!targetBakFile.existsSync()) {
        File oldDirectBakFile = File(join(pathService.getVisibleDir().path, 'jhentai.bak'));
        if (oldDirectBakFile.existsSync()) {
          oldDirectBakFile.copySync(targetBakFile.path);
        }
      }
    } on Exception catch (e) {
      log.uploadError(e);
    }
  }
}
