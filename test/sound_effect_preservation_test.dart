import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/image_inpainting_service.dart';
import 'package:jhentai/src/utils/image_text_grouping.dart';

RecognizedTextBlock block(String text, double left) => RecognizedTextBlock(
  text: text,
  confidence: 1,
  left: left,
  top: 10,
  width: 30,
  height: 40,
);

void main() {
  test(
    'preserved sound effects tolerate OCR line breaks but not translation',
    () {
      expect(translationPreservesSource('ドン\nドン', 'ドンドン'), isTrue);
      expect(translationPreservesSource('ドン', '砰'), isFalse);
      expect(translationPreservesSource('', ''), isFalse);
      expect(translationPreservesSource('ドン！', 'ドン'), isFalse);
    },
  );

  for (final bool grouped in <bool>[false, true]) {
    test('preserved effects are excluded from erasure (grouped: $grouped)', () {
      final RecognizedTextBlock effect = block('ドン', 10);
      final RecognizedTextBlock dialogue = block('待って', 300);
      final ImageTranslationResult result = ImageTranslationResult(
        status: ImageTranslationStatus.success,
        blocks: <RecognizedTextBlock>[effect, dialogue],
        mergeTextBlocks: false,
        translatedText: 'ドン\n等等',
        translatedGroups: grouped ? <String>['ドン', '等等'] : <String>[],
      );
      expect(translatedBlocksEligibleForErase(result), <RecognizedTextBlock>[
        dialogue,
      ]);
    });
  }

  test('group translation takes precedence over redistributed line text', () {
    final RecognizedTextBlock effect = block('ドン', 10);
    final ImageTranslationResult result = ImageTranslationResult(
      status: ImageTranslationStatus.success,
      blocks: <RecognizedTextBlock>[effect],
      translatedText: '砰',
      translatedGroups: <String>['ドン'],
    );
    expect(translatedBlocksEligibleForErase(result), isEmpty);
  });
}
