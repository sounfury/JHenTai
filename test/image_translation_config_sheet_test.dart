import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/pages/setting/advanced/image_translation/setting_image_translation_page.dart';
import 'package:jhentai/src/service/engine/context_translation_contract.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/setting/image_translation_setting.dart';
import 'package:jhentai/src/widget/eh_codex_style_dropdown.dart';
import 'package:jhentai/src/widget/eh_apple_controls.dart';
import 'package:jhentai/src/widget/image_translation_config_sheet.dart';

void main() {
  late ImageTranslationSetting originalSetting;

  setUp(() {
    originalSetting = imageTranslationSetting;
  });

  tearDown(() {
    imageTranslationSetting = originalSetting;
  });

  test('text merge preference is serialized and restored', () {
    final ImageTranslationSetting setting = ImageTranslationSetting();
    // Manual single-line mode remains available when bubble detection is off.
    setting.enableBubbleDetection.value = false;
    setting.autoMergeText.value = false;
    final ImageTranslationSetting restored = ImageTranslationSetting();

    restored.applyBeanConfig(setting.toConfigString());

    expect(restored.autoMergeText.value, isFalse);
  });

  testWidgets('advanced settings apply changes without a save button', (
    WidgetTester tester,
  ) async {
    final _ImmediateSetting setting = _ImmediateSetting();
    setting.ocrEngine.value = ImageOcrEngine.appleLiveText;
    imageTranslationSetting = setting;

    await tester.pumpWidget(
      const GetMaterialApp(home: SettingImageTranslationPage()),
    );

    expect(find.text('saveSetting'), findsNothing);

    final EHCodexStyleDropdown<ImageOcrEngine> ocr = tester.widget(
      find.byKey(const ValueKey('image-translation-ocr-engine')),
    );
    ocr.onChanged?.call(ImageOcrEngine.appleLiveText);
    await tester.pump();

    expect(setting.ocrEngine.value, ImageOcrEngine.appleLiveText);
    expect(setting.saveCount, 1);
  });

  testWidgets('quick sheet exposes independent OCR and translator selectors', (
    WidgetTester tester,
  ) async {
    final ImageTranslationSetting setting = ImageTranslationSetting();
    setting.ocrEngine.value = ImageOcrEngine.onnx;
    setting.translatorEngine.value = ImageTranslationEngine.appleOnDevice;
    imageTranslationSetting = setting;

    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: ImageTranslationConfigSheet())),
    );

    await _showControl(tester, 'image-translation-ocr-engine');
    final EHCodexStyleDropdown<ImageOcrEngine> ocr = tester.widget(
      find.byKey(const ValueKey('image-translation-ocr-engine')),
    );
    await _showControl(tester, 'image-translation-translator-engine');
    final EHCodexStyleDropdown<ImageTranslationEngine> translator = tester
        .widget(
          find.byKey(const ValueKey('image-translation-translator-engine')),
        );

    expect(ocr.value, ImageOcrEngine.onnx);
    expect(translator.value, ImageTranslationEngine.appleOnDevice);
  });

  testWidgets('quick sheet exposes the text merge switch', (
    WidgetTester tester,
  ) async {
    final _ImmediateSetting setting = _ImmediateSetting();
    setting.enableBubbleDetection.value = false;
    setting.autoMergeText.value = true;
    imageTranslationSetting = setting;

    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: ImageTranslationConfigSheet())),
    );
    await _showControl(tester, 'image-translation-auto-merge-text');

    final EHAppleSwitchListTile tile = tester.widget(
      find.byKey(const ValueKey('image-translation-auto-merge-text')),
    );
    expect(tile.value, isTrue);
    tile.onChanged!(false);
    await tester.pump();
    expect(setting.autoMergeText.value, isFalse);
    expect(setting.saveCount, 1);
  });

  testWidgets('Apple on-device translation exposes the image language picker', (
    WidgetTester tester,
  ) async {
    final ImageTranslationSetting setting = ImageTranslationSetting();
    setting.ocrEngine.value = ImageOcrEngine.onnx;
    setting.translatorEngine.value = ImageTranslationEngine.appleOnDevice;
    imageTranslationSetting = setting;

    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: ImageTranslationConfigSheet())),
    );

    expect(
      find.byKey(const ValueKey('image-translation-apple-live-text-language')),
      findsOneWidget,
    );
  });

  testWidgets('image language picker is hidden outside Apple OCR/translation', (
    WidgetTester tester,
  ) async {
    final ImageTranslationSetting setting = ImageTranslationSetting();
    setting.ocrEngine.value = ImageOcrEngine.onnx;
    setting.translatorEngine.value = ImageTranslationEngine.api;
    imageTranslationSetting = setting;

    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: ImageTranslationConfigSheet())),
    );

    expect(
      find.byKey(const ValueKey('image-translation-apple-live-text-language')),
      findsNothing,
    );
  });

  testWidgets('advanced page keeps OCR and translator as separate controls', (
    WidgetTester tester,
  ) async {
    final ImageTranslationSetting setting = ImageTranslationSetting();
    setting.ocrEngine.value = ImageOcrEngine.appleLiveText;
    setting.translatorEngine.value = ImageTranslationEngine.api;
    imageTranslationSetting = setting;

    await tester.pumpWidget(
      const GetMaterialApp(home: SettingImageTranslationPage()),
    );

    final EHCodexStyleDropdown<ImageOcrEngine> ocr = tester.widget(
      find.byKey(const ValueKey('image-translation-ocr-engine')),
    );
    final EHCodexStyleDropdown<ImageTranslationEngine> translator = tester
        .widget(
          find.byKey(const ValueKey('image-translation-translator-engine')),
        );

    expect(ocr.value, ImageOcrEngine.appleLiveText);
    expect(translator.value, ImageTranslationEngine.api);
    expect(find.text('imageTranslationMethodSection'), findsNothing);
  });

  testWidgets('Apple translator exposes only one-page context mode', (
    WidgetTester tester,
  ) async {
    final ImageTranslationSetting setting = ImageTranslationSetting();
    setting.translatorEngine.value = ImageTranslationEngine.appleOnDevice;
    setting.contextBatchSize.value = ContextBatchSize.four;
    imageTranslationSetting = setting;

    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: ImageTranslationConfigSheet())),
    );
    await _showControl(tester, 'image-translation-context-batch-size');

    final EHCodexStyleDropdown<ContextBatchSize> context = tester.widget(
      find.byKey(const ValueKey('image-translation-context-batch-size')),
    );
    expect(context.value, ContextBatchSize.one);
    final List<DropdownMenuItem<ContextBatchSize>> items =
        context.items.cast<DropdownMenuItem<ContextBatchSize>>();
    expect(items.first.enabled, isTrue);
    expect(items.skip(1).every((item) => !item.enabled), isTrue);
    expect(
      find.text('imageTranslationContextAppleUnsupported'),
      findsOneWidget,
    );
  });

  testWidgets('CTD and LaMa Large display mode is opt-in', (
    WidgetTester tester,
  ) async {
    final ImageTranslationSetting setting = ImageTranslationSetting();
    imageTranslationSetting = setting;

    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: ImageTranslationConfigSheet())),
    );
    await _showControl(tester, 'image-translation-image-processing-mode');

    final EHCodexStyleDropdown<ImageProcessingDisplayMode> processing = tester
        .widget(
          find.byKey(const ValueKey('image-translation-image-processing-mode')),
        );
    expect(processing.value, ImageProcessingDisplayMode.overlay);
    final List<DropdownMenuItem<ImageProcessingDisplayMode>> items =
        processing.items.cast<DropdownMenuItem<ImageProcessingDisplayMode>>();
    expect(items, hasLength(2));
    expect(
      items.map(
        (DropdownMenuItem<ImageProcessingDisplayMode> item) => item.value,
      ),
      isNot(contains(ImageProcessingDisplayMode.translatedImage)),
    );
  });

  testWidgets('local GGUF exposes model download and bundled FFI runtime', (
    WidgetTester tester,
  ) async {
    final ImageTranslationSetting setting = ImageTranslationSetting();
    setting.translatorEngine.value = ImageTranslationEngine.localGguf;
    imageTranslationSetting = setting;

    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: ImageTranslationConfigSheet())),
    );
    await tester.pump();

    await _showControl(tester, 'image-translation-local-model');
    final EHCodexStyleDropdown<String> model = tester.widget(
      find.byKey(const ValueKey('image-translation-local-model')),
    );
    expect(model.value, setting.localModelId.value);
    await _showControl(tester, 'image-translation-local-model-download');
    expect(
      find.byKey(const ValueKey('image-translation-local-model-download')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('image-translation-managed-llama-runtime')),
      findsNothing,
    );
    await _showControl(tester, 'image-translation-local-ffi-runtime');
    expect(
      find.byKey(const ValueKey('image-translation-local-ffi-runtime')),
      findsOneWidget,
    );
  });
}

Future<void> _showControl(WidgetTester tester, String key) async {
  // Locate controls by identity instead of assuming a fixed sheet scroll offset.
  // Model initialization can show an animated indicator, so do not settle it.
  await tester.scrollUntilVisible(
    find.byKey(ValueKey(key)),
    150,
    scrollable:
        find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
  );
  await tester.pump();
}

class _ImmediateSetting extends ImageTranslationSetting {
  int saveCount = 0;

  @override
  Future<int> saveBeanConfig() async => ++saveCount;
}
