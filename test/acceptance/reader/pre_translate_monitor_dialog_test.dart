import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_metadata.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/pages/details/details_page_logic.dart';
import 'package:jhentai/src/pages/details/pre_translate_monitor_dialog.dart';
import 'package:jhentai/src/service/gallery_pre_translate_preference.dart';
import 'package:jhentai/src/service/gallery_pre_translate_runner.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';

// UI acceptance uses the real dialog, persistence and detail-page scheduling.
// Network/model execution is replaced at the runner boundary.
class _MemoryConfig extends LocalConfigService {
  final Map<String, String> values = {};

  @override
  Future<String?> read({
    required ConfigEnum configKey,
    String subConfigKey = LocalConfigService.defaultSubConfigKey,
  }) async => values['${configKey.key}:$subConfigKey'];

  @override
  Future<int> write({
    required ConfigEnum configKey,
    String subConfigKey = LocalConfigService.defaultSubConfigKey,
    required String value,
  }) async {
    values['${configKey.key}:$subConfigKey'] = value;
    return 1;
  }
}

class _AcceptanceRunner extends GalleryPreTranslateRunner {
  PreTranslateJobProgress? job;
  int starts = 0;

  @override
  PreTranslateJobProgress? progressFor(int gid) => job;

  @override
  bool isRunningFor(int gid) => job?.status == PreTranslateJobStatus.running;

  @override
  void startForGallery({
    required GalleryUrl galleryUrl,
    required int pageCount,
    int? requestedPageCount,
    int? requestedConcurrency,
    List<GalleryThumbnail>? seedThumbnails,
    String? galleryLanguage,
    String? galleryTagsCsv,
  }) {
    starts++;
    job = PreTranslateJobProgress(
      gid: galleryUrl.gid,
      total: requestedPageCount!,
      concurrency: requestedConcurrency!,
    )..status = PreTranslateJobStatus.running;
    update([progressIdFor(galleryUrl.gid)]);
  }

  @override
  void inspectForGallery({
    required GalleryUrl galleryUrl,
    required int pageCount,
    int? requestedPageCount,
    int? requestedConcurrency,
    List<GalleryThumbnail>? seedThumbnails,
  }) {
    job = PreTranslateJobProgress(
      gid: galleryUrl.gid,
      total: requestedPageCount!,
      concurrency: requestedConcurrency!,
    )..status = PreTranslateJobStatus.ready;
    update([progressIdFor(galleryUrl.gid)]);
  }

  @override
  void cancelForGallery(int gid) {
    job?.status = PreTranslateJobStatus.canceled;
    update([progressIdFor(gid)]);
  }
}

void main() {
  late LocalConfigService originalConfig;
  late GalleryPreTranslateRunner originalRunner;
  late ImageTranslationService originalTranslation;
  late _AcceptanceRunner runner;
  late DetailsPageLogic logic;
  const GalleryUrl url = GalleryUrl(isEH: true, gid: 42, token: '0123456789');

  setUp(() {
    Get.testMode = true;
    originalConfig = localConfigService;
    originalRunner = galleryPreTranslateRunner;
    originalTranslation = imageTranslationService;
    localConfigService = _MemoryConfig();
    galleryPreTranslateRunner = runner = _AcceptanceRunner();
    imageTranslationService = ImageTranslationService();
    Get.put<GalleryPreTranslateRunner>(runner);
    Get.put<ImageTranslationService>(imageTranslationService);
    logic = DetailsPageLogic();
    logic.state.galleryUrl = url;
    logic.state.galleryMetadata = GalleryMetadata(
      galleryUrl: url,
      title: '',
      japaneseTitle: '',
      category: '',
      cover: GalleryImage(url: ''),
      pageCount: 600,
      rating: 0,
      language: 'japanese',
      publishTime: '',
      isExpunged: false,
      size: '',
      torrentCount: 0,
      tags: LinkedHashMap<String, List<GalleryTag>>(),
    );
  });

  tearDown(() {
    Get.reset();
    localConfigService = originalConfig;
    galleryPreTranslateRunner = originalRunner;
    imageTranslationService = originalTranslation;
  });

  Future<void> open(WidgetTester tester, {int pageCount = 600}) async {
    final GalleryPreTranslateOptions options =
        await GalleryPreTranslatePreference.optionsFor(url.gid);
    await tester.pumpWidget(
      GetMaterialApp(
        locale: const Locale('zh', 'CN'),
        translations: LocaleText(),
        home: Scaffold(
          body: PreTranslateMonitorDialog(
            logic: logic,
            gid: url.gid,
            initialEnabled: await GalleryPreTranslatePreference.isEnabled(
              url.gid,
            ),
            initialOptions: options,
            pageCount: pageCount,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('select entire gallery, start, change concurrency and reopen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await open(tester);
    await tester.drag(find.byType(Slider).first, const Offset(1000, 0));
    await tester.pumpAndSettle();
    expect(find.text('整本（600 页）'), findsOneWidget);
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(runner.job!.total, 600);
    expect(runner.starts, 1);

    await tester.drag(find.byType(Slider).last, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用并继续'));
    await tester.pumpAndSettle();
    expect(runner.job!.concurrency, 1);
    expect(runner.starts, 2);
    expect(
      (await GalleryPreTranslatePreference.optionsFor(url.gid)).pageCount,
      600,
    );
    expect((await GalleryPreTranslatePreference.optionsFor(99)).pageCount, 30);

    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    expect(runner.job!.status, PreTranslateJobStatus.canceled);
    await tester.pumpWidget(const SizedBox.shrink());
    await open(tester);
    expect(tester.widget<Slider>(find.byType(Slider).first).value, 600);
    expect(tester.widget<Slider>(find.byType(Slider).last).value, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single-page gallery and empty state fit a narrow window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await open(tester, pageCount: 1);
    expect(tester.widget<Slider>(find.byType(Slider).first).onChanged, isNull);
    expect(find.text('开始').hitTestable(), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('background repair displays a Chinese status', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    runner.job = PreTranslateJobProgress(gid: url.gid, total: 1, concurrency: 1)
      ..status = PreTranslateJobStatus.running;
    runner.job!.pages.first.phase = PreTranslatePagePhase.repairing;
    await open(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在修复背景'), findsOneWidget);
    expect(find.text('translationStageMasking'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
