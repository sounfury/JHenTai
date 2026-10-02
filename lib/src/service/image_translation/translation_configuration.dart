import '../../setting/image_translation_setting.dart';
import '../../setting/inference_setting.dart';
import '../inference/onnx_model_store.dart';
import '../inference_service.dart';

const int imageTranslationPromptVersion = 7;
const int contextTranslationPromptVersion = 5;

typedef ImageTranslationConfiguration =
    ({
      String? ocrModel,
      String modelVersion,
      String targetLanguage,
      Map<String, dynamic> ocr,
      Map<String, dynamic> translation,
    });

/// Copy the settings once so single-page and context cache keys use the same
/// model identities and output-affecting options, without a JSON round trip.
ImageTranslationConfiguration captureImageTranslationConfiguration() {
  final setting = imageTranslationSetting;
  final bool onnx = setting.ocrEngine.value == ImageOcrEngine.onnx;
  return (
    ocrModel:
        onnx
            ? OnnxModelStore.instance.fingerprintOf(
                  setting.onnxModelId.value,
                ) ??
                setting.ocrEngine.value.name
            : setting.ocrEngine.value.name,
    modelVersion: switch (setting.translatorEngine.value) {
      ImageTranslationEngine.api => setting.translatorModel.value,
      ImageTranslationEngine.localGguf => setting.localModelId.value,
      ImageTranslationEngine.appleOnDevice => 'apple-on-device',
    },
    targetLanguage: setting.targetLanguage.value,
    ocr: <String, dynamic>{
      'engine': setting.ocrEngine.value.name,
      'language': setting.appleLiveTextLanguage.value,
      'backend':
          onnx
              ? inferenceService.resolveBackendFor(InferenceDomain.ocr)?.name
              : null,
      'mangaAutoSuggest': setting.mangaOcrAutoSuggest.value,
      'bubbleDetection': setting.enableBubbleDetection.value,
      'bubbleModel':
          setting.enableBubbleDetection.value
              ? OnnxModelStore.instance.fingerprintOf(
                OnnxModelStore.bubbleSegmentationManifestId,
              )
              : null,
      'sfxFilter': 8,
      'bubbleMaskLayout': 1,
      'ocrArtifactFilter': 1,
    },
    translation: <String, dynamic>{
      'engine': setting.translatorEngine.value.name,
      'provider': setting.translatorProvider.value.name,
      'endpoint': setting.translatorEndpoint.value,
      'target': setting.targetLanguage.value,
      'thinking': setting.enableThinking.value,
      'mergeTextBlocks': setting.autoMergeText.value,
    },
  );
}
