import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/image_inpainting_service.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/utils/image_text_grouping.dart';

/// Ground-truth Blue Archive page used to lock the sparse-OCR + full-page CTD
/// erase regression. Offline RapidOCR on this PNG yields 16 blocks; a healthy
/// app path must cover most dialogue/caption boxes (>> 1–2).
void main() {
  final File fixturePng = File(
    'test/fixtures/blue_archive_kotori_sauna_page.png',
  );
  final File fixtureBlocks = File(
    'test/fixtures/sauna_page_rapidocr_blocks.json',
  );

  test('fixture PNG and OCR dump are present', () {
    expect(fixturePng.existsSync(), isTrue);
    expect(fixtureBlocks.existsSync(), isTrue);
    expect(fixturePng.lengthSync(), greaterThan(100000));
  });

  test('offline RapidOCR dump covers most bubbles on the sauna page', () {
    final Map<String, dynamic> decoded =
        jsonDecode(fixtureBlocks.readAsStringSync()) as Map<String, dynamic>;
    final List<dynamic> raw = decoded['blocks'] as List<dynamic>;
    expect(raw.length, greaterThanOrEqualTo(10),
        reason: 'healthy recognition on this page is >> 1–2 bubbles');
    expect(decoded['imageSize'], <dynamic>[1280, 1807]);

    final List<RecognizedTextBlock> blocks = raw
        .map(
          (dynamic item) => RecognizedTextBlock.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
    // Spread across top / mid / bottom tiers of the page.
    expect(blocks.any((RecognizedTextBlock b) => b.top < 700), isTrue);
    expect(
      blocks.any((RecognizedTextBlock b) => b.top > 700 && b.top < 1300),
      isTrue,
    );
    expect(blocks.any((RecognizedTextBlock b) => b.top > 1300), isTrue);
  });

  test('page-spanning bubble box splits into multiple containers', () {
    final Map<String, dynamic> decoded =
        jsonDecode(fixtureBlocks.readAsStringSync()) as Map<String, dynamic>;
    final List<RecognizedTextBlock> blocks = (decoded['blocks'] as List<dynamic>)
        .map(
          (dynamic item) => RecognizedTextBlock.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);

    // One detector region covering almost the whole page (but under the
    // 80%/95% reject thresholds) would previously violently merge every OCR
    // line into a single translation unit.
    final List<RecognizedTextContainer> containers =
        containersFromBubbleDetection(
          blocks,
          const DetectionResult(
            regions: <DetectedTextRegion>[
              DetectedTextRegion(
                left: 40,
                top: 40,
                width: 1000,
                height: 1400,
                confidence: 0.9,
              ),
            ],
          ),
          imageWidth: 1280,
          imageHeight: 1807,
        );
    expect(containers.length, greaterThanOrEqualTo(3),
        reason: 'disconnected OCR clusters must not share one container');
    final Set<int> covered = <int>{
      for (final RecognizedTextContainer c in containers) ...c.blockIndices,
    };
    // Region is intentionally smaller than the full page, so only in-region
    // OCR lines are covered — but they must not collapse to a single bubble.
    expect(covered.length, greaterThanOrEqualTo(8));
    expect(containers.length, lessThan(covered.length));
  });

  test('sparse translation cannot authorize full-page CTD erase masks', () {
    final Map<String, dynamic> decoded =
        jsonDecode(fixtureBlocks.readAsStringSync()) as Map<String, dynamic>;
    final List<RecognizedTextBlock> blocks = (decoded['blocks'] as List<dynamic>)
        .map(
          (dynamic item) => RecognizedTextBlock.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);

    // Simulate the reported failure: OCR only kept 2 bubbles, but CTD found
    // masks for every text region on the page.
    final List<RecognizedTextBlock> sparseTranslated = blocks.take(2).toList();
    final List<PolygonMask> ctdMasks = <PolygonMask>[
      for (final RecognizedTextBlock block in blocks)
        PolygonMask(
          points: <EnginePoint>[
            EnginePoint(x: block.left, y: block.top),
            EnginePoint(x: block.left + block.width, y: block.top),
            EnginePoint(
              x: block.left + block.width,
              y: block.top + block.height,
            ),
            EnginePoint(x: block.left, y: block.top + block.height),
          ],
          confidence: 0.9,
        ),
    ];
    expect(ctdMasks.length, greaterThanOrEqualTo(10));

    final List<PolygonMask> eraseMasks = filterPolygonMasksToTranslatedBlocks(
      masks: ctdMasks,
      translatedBlocks: sparseTranslated,
    );
    expect(eraseMasks.length, lessThanOrEqualTo(sparseTranslated.length + 1));
    expect(eraseMasks.length, lessThan(ctdMasks.length));

    final ImageTranslationResult sparseResult = ImageTranslationResult(
      status: ImageTranslationStatus.success,
      translatedText: List<String>.generate(
        blocks.length,
        (int i) => i < 2 ? '译$i' : '',
      ).join('\n'),
      blocks: blocks,
    );
    final List<RecognizedTextBlock> eligible =
        translatedBlocksEligibleForErase(sparseResult);
    expect(eligible.length, 2);
  });

  test('grouping the fixture OCR yields many utterance groups', () {
    final Map<String, dynamic> decoded =
        jsonDecode(fixtureBlocks.readAsStringSync()) as Map<String, dynamic>;
    final List<RecognizedTextBlock> blocks = (decoded['blocks'] as List<dynamic>)
        .map(
          (dynamic item) => RecognizedTextBlock.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
    final List<RecognizedTextGroup> groups = groupRecognizedTextBlocks(blocks);
    expect(groups.length, greaterThanOrEqualTo(5));
  });
}
