import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/l18n/zh_CN.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/widget/read_page_image_translation_overlay.dart';

const _root = 'test/acceptance/reader/no_text_status';
const _request = ImageTranslationRequest(
  cacheKey: 'no-text-acceptance',
  imagePath: 'unused',
);

void main() {
  late ImageTranslationService previousService;
  setUp(() {
    Get.testMode = true;
    Get.addTranslations({'zh_CN': zh_CN.keys()});
    Get.locale = const Locale('zh', 'CN');
    previousService = imageTranslationService;
    imageTranslationService = ImageTranslationService();
    Get.put(imageTranslationService);
  });
  tearDown(() {
    Get.reset();
    imageTranslationService = previousService;
  });

  testWidgets('实际无文字缓存进入阅读页后显示无文字，保留手动重试', (tester) async {
    final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
      );
    }
    final cached = ImageTranslationResult.fromCacheJson(
      jsonDecode(File('$_root/cached_result.json').readAsStringSync()),
    );
    // Production cache restore calls copyWith(fromCache: true), which clears
    // the optional errorMessage while retaining the noText status.
    final restored = cached.copyWith(fromCache: true);
    expect(restored.status, ImageTranslationStatus.noText);
    expect(restored.errorMessage, isNull);
    expect(restored.isFailure, isFalse);
    imageTranslationService.publishResult(_request.cacheKey, restored);
    int retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReadPageImageTranslationOverlay(
            request: _request,
            onRetry: () async {
              retries++;
            },
          ),
        ),
      ),
    );
    expect(find.text('未在图片中识别到文字。'), findsOneWidget);
    expect(find.text('图片文字翻译失败。'), findsNothing);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('真正的翻译失败仍显示失败提示', (tester) async {
    imageTranslationService.publishResult(
      _request.cacheKey,
      const ImageTranslationResult(status: ImageTranslationStatus.failed),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReadPageImageTranslationOverlay(request: _request),
        ),
      ),
    );
    expect(find.text('图片文字翻译失败。'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('未在图片中识别到文字。'), findsNothing);
  });
}
