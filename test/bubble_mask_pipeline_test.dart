import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/bubble_interior_mask.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/utils/bubble_mask_decoder.dart';
import 'package:jhentai/src/utils/bubble_mask_layout.dart';
import 'package:jhentai/src/utils/bubble_detection_refinement.dart';
import 'package:jhentai/src/utils/image_text_grouping.dart';
import 'package:jhentai/src/utils/rgba_raster.dart';

BubbleInteriorMask mask(
  Rect bounds,
  int w,
  int h,
  bool Function(int, int) inside,
) => BubbleInteriorMask(
  bounds: bounds,
  width: w,
  height: h,
  pixels: Uint8List.fromList([
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++) inside(x, y) ? 1 : 0,
  ]),
);
DetectedTextRegion region(BubbleInteriorMask m) => DetectedTextRegion(
  left: m.bounds.left,
  top: m.bounds.top,
  width: m.bounds.width,
  height: m.bounds.height,
  confidence: .9,
  bubbleInterior: m,
);
RecognizedTextBlock block(Rect r, [String text = 'これは文章です']) =>
    RecognizedTextBlock(
      text: text,
      confidence: .99,
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('mask coefficients, padding and source crop are decoded together', () {
    // 8x8 input, 4x2 source scaled by 2; two rows of padding in input.
    final p = Float32List(2 * 8 * 8);
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        p[y * 8 + x] = x < 4 ? 2 : -2;
        p[64 + y * 8 + x] = .5;
      }
    }
    final m =
        decodeBubbleInteriorMask(
          coefficients: [1, -1],
          prototypes: p,
          prototypeWidth: 8,
          prototypeHeight: 8,
          inputSize: 8,
          sourceBox: const Rect.fromLTWH(0, 0, 4, 2),
          scale: 2,
          padX: 0,
          padY: 2,
        )!;
    expect(m.bounds, const Rect.fromLTWH(0, 0, 4, 2));
    expect(m.width, 8);
    expect(m.height, 4);
    expect(m.coverage(const Rect.fromLTWH(0, 0, 2, 2)), 1);
    expect(m.coverage(const Rect.fromLTWH(2, 0, 2, 2)), 0);
    expect(m.coverage(const Rect.fromLTWH(-2, 0, 4, 2)), .5);
    final crop =
        decodeBubbleInteriorMask(
          coefficients: [1, -1],
          prototypes: p,
          prototypeWidth: 8,
          prototypeHeight: 8,
          inputSize: 8,
          sourceBox: const Rect.fromLTWH(.5, .5, 1, 1),
          scale: 2,
          padX: 0,
          padY: 2,
        )!;
    expect(crop.bounds, const Rect.fromLTWH(.5, .5, 1, 1));
    expect(crop.coverage(crop.bounds), 1);
  });
  test('empty or malformed masks fall back without outside-text evidence', () {
    for (final p in [
      Float32List(16),
      Float32List(15),
      Float32List.fromList(List.filled(16, double.nan)),
    ]) {
      expect(
        decodeBubbleInteriorMask(
          coefficients: [1],
          prototypes: p,
          prototypeWidth: 4,
          prototypeHeight: 4,
          inputSize: 4,
          sourceBox: const Rect.fromLTWH(0, 0, 4, 4),
          scale: 1,
          padX: 0,
          padY: 0,
        ),
        isNull,
      );
    }
  });
  test('concave masks exclude effects that lie inside the enclosing box', () {
    final m = mask(
      const Rect.fromLTWH(20, 20, 160, 160),
      40,
      40,
      (x, y) => x >= 22 || y >= 22,
    );
    final effect = block(const Rect.fromLTWH(30, 30, 20, 40), 'ドキ');
    final dialogue = block(const Rect.fromLTWH(130, 30, 20, 100));
    expect(isBlockInsideAnyRegion(effect, [region(m)]), isFalse);
    expect(isBlockInsideAnyRegion(dialogue, [region(m)]), isTrue);
    final containers = containersFromBubbleDetection(
      [effect, dialogue],
      DetectionResult(regions: [region(m)]),
      imageWidth: 400,
      imageHeight: 400,
    );
    expect(containers.single.blockIndices, [1]);
    expect(containers.single.layoutAnalysisVersion, 2);
    final restored = RecognizedTextContainer.fromJson(
      containers.single.toJson(),
    );
    final g =
        translationTextGroups([effect, dialogue], containers: [restored]).first;
    final areas = layoutRegionsForRecognizedTextGroup(
      g,
      [restored],
      blocks: [effect, dialogue],
    );
    expect(areas, isNotEmpty);
    for (final r in areas) {
      expect(
        m.coverage(Rect.fromLTWH(r.left, r.top, r.width, r.height)),
        closeTo(1, 1e-6),
      );
    }
  });
  test('disconnected lobes and narrow masks retain safe layout areas', () {
    for (final m in [
      mask(
        const Rect.fromLTWH(0, 0, 300, 180),
        60,
        36,
        (x, y) => (x < 25 || x > 35) && y > 2 && y < 33,
      ),
      mask(const Rect.fromLTWH(0, 0, 24, 200), 6, 50, (x, y) => true),
    ]) {
      final areas = layoutBubbleInterior(m);
      expect(areas.length, m.width == 60 ? 2 : 1);
      for (final a in areas) {
        expect(
          m.coverage(Rect.fromLTWH(a.left, a.top, a.width, a.height)),
          closeTo(1, 1e-6),
        );
      }
    }
  });
  test(
    'overlapping instances assign each OCR block once without losing others',
    () {
      final a = region(
        mask(const Rect.fromLTWH(20, 20, 140, 120), 28, 24, (x, y) => true),
      );
      final b = region(
        mask(const Rect.fromLTWH(120, 20, 140, 120), 28, 24, (x, y) => true),
      );
      final blocks = [
        block(const Rect.fromLTWH(40, 40, 20, 60)),
        block(const Rect.fromLTWH(130, 40, 20, 60)),
        block(const Rect.fromLTWH(210, 40, 20, 60)),
      ];
      final cs = containersFromBubbleDetection(
        blocks,
        DetectionResult(regions: [a, b]),
        imageWidth: 400,
        imageHeight: 400,
      );
      final assigned = cs.expand((c) => c.blockIndices).toList()..sort();
      expect(assigned, [0, 1, 2]);
    },
  );
  test(
    'local retry restores a missing lobe and maps crop masks to the page',
    () async {
      final source = RgbaRaster(800, 800, Uint8List(800 * 800 * 4));
      final old = region(
        mask(const Rect.fromLTWH(100, 100, 200, 200), 40, 40, (x, y) => x < 20),
      );
      final blocks = [
        block(const Rect.fromLTWH(120, 130, 30, 120)),
        block(const Rect.fromLTWH(230, 130, 30, 120)),
      ];
      int calls = 0;
      final result = await refineBubbleDetection(
        source: source,
        initial: DetectionResult(regions: [old]),
        blocks: blocks,
        isCanceled: () => false,
        detect: (crop) async {
          calls++;
          expect(crop.width, 300);
          expect(crop.height, 300);
          return DetectionResult(
            regions: [
              region(
                mask(
                  const Rect.fromLTWH(50, 50, 200, 200),
                  80,
                  80,
                  (x, y) => true,
                ),
              ),
            ],
          );
        },
      );
      expect(calls, 1);
      expect(result.regions.single.left, 100);
      expect(result.regions.single.bubbleInterior!.bounds.left, 100);
      for (final b in blocks) {
        expect(bubbleRegionCoverage(b, result.regions.single), 1);
      }
    },
  );
  test(
    'failed, clipped, or worse retries preserve the initial result',
    () async {
      final source = RgbaRaster(800, 800, Uint8List(800 * 800 * 4));
      final old = region(
        mask(const Rect.fromLTWH(100, 100, 200, 200), 40, 40, (x, y) => x < 20),
      );
      final blocks = [
        block(const Rect.fromLTWH(120, 130, 30, 120)),
        block(const Rect.fromLTWH(230, 130, 30, 120)),
      ];
      for (final candidate in <DetectionResult?>[
        null,
        DetectionResult(
          regions: [
            region(
              mask(
                const Rect.fromLTWH(50, 50, 200, 200),
                80,
                80,
                (x, y) => x > 40,
              ),
            ),
          ],
        ),
        DetectionResult(
          regions: [
            region(
              mask(const Rect.fromLTWH(0, 0, 300, 300), 80, 80, (x, y) => true),
            ),
          ],
        ),
      ]) {
        final result = await refineBubbleDetection(
          source: source,
          initial: DetectionResult(regions: [old]),
          blocks: blocks,
          isCanceled: () => false,
          detect: (_) async => candidate,
        );
        expect(result.regions, [old]);
      }
    },
  );
  test('retry budget and cancellation are bounded', () async {
    final source = RgbaRaster(1000, 1000, Uint8List(1000 * 1000 * 4));
    final blocks = [
      for (final x in [100.0, 400.0, 700.0])
        block(Rect.fromLTWH(x, 100, 30, 100)),
    ];
    for (final canceled in [true, false]) {
      int calls = 0;
      await refineBubbleDetection(
        source: source,
        initial: const DetectionResult(regions: []),
        blocks: blocks,
        isCanceled: () => canceled,
        detect: (_) async {
          calls++;
          return null;
        },
      );
      expect(calls, canceled ? 0 : 2);
    }
  });
}
