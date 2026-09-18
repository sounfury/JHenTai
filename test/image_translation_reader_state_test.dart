import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';

void main() {
  test('only completed pages with actual translated content enable visibility', () {
    const block = RecognizedTextBlock(
      text: 'source', confidence: 1, width: 16, height: 80,
    );
    for (final status in ImageTranslationStatus.values) {
      // Retained text from an earlier attempt must not turn a failed or busy
      // page into an eye button that cannot start a fresh translation.
      final result = ImageTranslationResult(
        status: status,
        blocks: [block],
        translatedText: '译文',
        imageWidth: 100,
        imageHeight: 100,
      );
      expect(result.hasDisplayableTranslation,
          status == ImageTranslationStatus.success, reason: status.name);
    }
    expect(const ImageTranslationResult.idle().hasDisplayableTranslation, isFalse);
    expect(const ImageTranslationResult(
      status: ImageTranslationStatus.success, blocks: [block], translatedText: ' ',
    ).hasDisplayableTranslation, isFalse);
    expect(const ImageTranslationResult(
      status: ImageTranslationStatus.success, translatedText: '译文',
    ).hasDisplayableTranslation, isFalse);
  });

  test('queued and active work remain busy until a terminal result arrives', () {
    for (final status in ImageTranslationStatus.values) {
      final result = ImageTranslationResult(status: status);
      expect(result.isProcessing, {
        ImageTranslationStatus.queued,
        ImageTranslationStatus.downloading,
        ImageTranslationStatus.recognizing,
        ImageTranslationStatus.translating,
      }.contains(status));
    }
  });
}
