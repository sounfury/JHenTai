import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/utils/image_text_grouping.dart';
import 'package:jhentai/src/utils/ocr_artifact_filter.dart';

RecognizedTextBlock _block(
  String text,
  double left,
  double top,
  double width,
  double height,
) => RecognizedTextBlock(
  text: text,
  confidence: 1,
  left: left,
  top: top,
  width: width,
  height: height,
);

void main() {
  test('overlapping Latin OCR ghost is folded into the Japanese glyph', () {
    final blocks = mergeOverlappingOcrArtifacts(<RecognizedTextBlock>[
      const RecognizedTextBlock(
        text: '周',
        confidence: 0.991,
        left: 1034.7,
        top: 123.7,
        width: 34.2,
        height: 41.5,
      ),
      const RecognizedTextBlock(
        text: 'iM',
        confidence: 0.696,
        left: 1023.6,
        top: 130.9,
        width: 24.7,
        height: 30.8,
      ),
      const RecognizedTextBlock(
        text: '末',
        confidence: 0.535,
        left: 1019.8,
        top: 158.6,
        width: 57.2,
        height: 77.8,
      ),
      _block('楽しみに待ってます…！！', 964.4, 163.4, 58.2, 526.2),
    ]);
    expect(blocks.map((block) => block.text), <String>[
      '周',
      '末',
      '楽しみに待ってます…！！',
    ]);
    expect(blocks.first.left, 1023.6);
    expect(translationUsesVerticalLayout(blocks, <int>[0, 1, 2]), isTrue);
  });

  test('separate or confident Latin text is retained', () {
    final blocks = mergeOverlappingOcrArtifacts(<RecognizedTextBlock>[
      const RecognizedTextBlock(
        text: 'OK',
        confidence: 0.95,
        left: 10,
        top: 10,
        width: 30,
        height: 30,
      ),
      const RecognizedTextBlock(
        text: 'iM',
        confidence: 0.69,
        left: 100,
        top: 100,
        width: 25,
        height: 30,
      ),
      const RecognizedTextBlock(
        text: '周',
        confidence: 0.99,
        left: 10,
        top: 10,
        width: 30,
        height: 30,
      ),
    ]);
    expect(blocks.map((block) => block.text), <String>['OK', 'iM', '周']);
  });

  test(
    'touching OCR fragments in one vertical bubble remain one utterance',
    () {
      // This shape occurred in a page where OCR split 週末 into 周, iM and 末.
      // The following long vertical column still belongs to that same bubble.
      final List<RecognizedTextBlock> blocks = <RecognizedTextBlock>[
        _block('周', 1034.7, 123.7, 34.2, 41.5),
        _block('iM', 1023.6, 130.9, 24.7, 30.8),
        _block('末', 1019.8, 158.6, 57.2, 77.8),
        _block('楽しみに待ってます…！！', 964.4, 163.4, 58.2, 526.2),
        _block('たくさん楽しもう！', 181.4, 463.0, 37.3, 298.9),
      ];
      final List<RecognizedTextContainer> containers =
          containersFromBubbleDetection(
            blocks,
            const DetectionResult(
              regions: <DetectedTextRegion>[
                DetectedTextRegion(
                  left: 945,
                  top: 100,
                  width: 160,
                  height: 610,
                  confidence: 0.77,
                ),
                DetectedTextRegion(
                  left: 150,
                  top: 330,
                  width: 140,
                  height: 460,
                  confidence: 0.95,
                ),
              ],
            ),
            imageWidth: 1160,
            imageHeight: 900,
          );
      expect(containers, hasLength(2));
      expect(containers.first.blockIndices, <int>[0, 1, 2, 3]);
      final List<RecognizedTextGroup> groups = translationTextGroups(
        blocks,
        containers: containers,
      );
      expect(groups.first.textOf(blocks), contains('末\n楽しみに待ってます'));
      expect(groups.last.blockIndices, <int>[4]);
    },
  );
}
