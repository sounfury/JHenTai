// 验证黑白／彩色页面策略：色彩判定、彩色页擦除掩码、译文区域去重叠及缓存字段。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/utils/image_translation_renderer.dart';
import 'package:jhentai/src/utils/inpainting_pixels.dart';
import 'package:jhentai/src/utils/page_processing_strategy.dart';

/// 粉色纵向渐变背景上的两行"白字黑边"笔画，模拟彩色页横排对白。
({img.Image image, List<math.Point<double>> polygon, Uint8List glyphs})
_outlinedTextOnGradient() {
  const w = 400, h = 240;
  final image = img.Image(width: w, height: h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      image.setPixelRgb(x, y, 230 - y ~/ 6, 150 - y ~/ 8, 170 - y ~/ 10);
    }
  }
  final glyphs = Uint8List(w * h);
  void stroke(int x0, int y0, int x1, int y1) {
    for (int y = y0 - 3; y <= y1 + 3; y++) {
      for (int x = x0 - 3; x <= x1 + 3; x++) {
        final inside = x >= x0 && x <= x1 && y >= y0 && y <= y1;
        image.setPixelRgb(
          x,
          y,
          inside ? 252 : 20,
          inside ? 252 : 20,
          inside ? 252 : 30,
        );
        glyphs[y * w + x] = 1;
      }
    }
  }

  for (final top in [80, 130]) {
    for (int x = 90; x < 300; x += 26) {
      stroke(x, top, x + 6, top + 24);
      stroke(x, top + 9, x + 16, top + 13);
    }
  }
  return (
    image: image,
    polygon: const [
      math.Point(80, 70),
      math.Point(320, 70),
      math.Point(320, 170),
      math.Point(80, 170),
    ],
    glyphs: glyphs,
  );
}

Uint8List _rgba(img.Image image) =>
    image.convert(numChannels: 4, alpha: 255).toUint8List();

void main() {
  test('灰度页和泛黄扫描判为黑白，饱和画面判为彩色', () {
    final gray = img.Image(width: 200, height: 200);
    final sepia = img.Image(width: 200, height: 200);
    final colored = img.Image(width: 200, height: 200);
    for (int y = 0; y < 200; y++) {
      for (int x = 0; x < 200; x++) {
        final v = (x + y) % 256;
        gray.setPixelRgb(x, y, v, v, v);
        sepia.setPixelRgb(x, y, 240 - x ~/ 4, 228 - x ~/ 4, 205 - x ~/ 4);
        colored.setPixelRgb(x, y, 220, 120 + y ~/ 4, 140);
      }
    }
    expect(
      classifyPageColorMode(_rgba(gray), 200, 200),
      PageColorMode.monochrome,
    );
    expect(
      classifyPageColorMode(_rgba(sepia), 200, 200),
      PageColorMode.monochrome,
    );
    expect(
      classifyPageColorMode(_rgba(colored), 200, 200),
      PageColorMode.color,
    );
    expect(classifyImageColorMode(colored), PageColorMode.color);
  });

  test('设置覆盖优先于自动判定，旧缓存缺省按黑白处理', () {
    expect(
      resolvePageColorMode(PageColorPreference.auto, null),
      PageColorMode.monochrome,
    );
    expect(
      resolvePageColorMode(PageColorPreference.auto, PageColorMode.color),
      PageColorMode.color,
    );
    expect(
      resolvePageColorMode(PageColorPreference.monochrome, PageColorMode.color),
      PageColorMode.monochrome,
    );
    expect(
      PageProcessingStrategy.monochrome.id,
      isNot(PageProcessingStrategy.color.id),
    );
    expect(PageProcessingStrategy.monochrome.useContainerLayoutRegions, isTrue);
    expect(PageProcessingStrategy.color.separateOverlappingTexts, isTrue);
  });

  test('彩色策略擦除渐变背景上的白字黑边，且不越出检测区域', () {
    final page = _outlinedTextOnGradient();
    final w = page.image.width, h = page.image.height;
    final coarse = rasterizeInpaintingMask(w, h, [page.polygon]);
    final colorMask = PageProcessingStrategy.color.refineEraseMask(
      page.image,
      coarse,
    );
    final monoMask = PageProcessingStrategy.monochrome.refineEraseMask(
      page.image,
      coarse,
    );
    int glyphs = 0, colorMissed = 0, monoMissed = 0;
    int insideBackground = 0, insideErased = 0;
    for (int i = 0; i < w * h; i++) {
      if (page.glyphs[i] != 0) {
        glyphs++;
        if (colorMask[i] != 0) colorMissed++;
        if (monoMask[i] != 0) monoMissed++;
      } else if (coarse[i] == 0) {
        insideBackground++;
        if (colorMask[i] == 0) insideErased++;
      }
    }
    expect(colorMissed / glyphs, lessThan(.01));
    // 记录黑白策略在彩色背景上的漏擦，说明两套策略分离的必要性。
    expect(monoMissed / glyphs, greaterThan(.3));
    // 行间与字间的背景不应整片擦除。
    expect(insideErased / insideBackground, lessThan(.5));
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (x < 74 || x > 326 || y < 64 || y > 176) {
          expect(colorMask[y * w + x], 255, reason: '($x,$y) 在检测区域外');
        }
      }
    }
  });

  test('彩色策略在复杂背景下退化为擦除整个检测区域', () {
    final image = img.Image(width: 120, height: 120);
    final random = math.Random(7);
    for (int y = 0; y < 120; y++) {
      for (int x = 0; x < 120; x++) {
        image.setPixelRgb(
          x,
          y,
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        );
      }
    }
    final coarse = rasterizeInpaintingMask(120, 120, const [
      [
        math.Point(30, 30),
        math.Point(90, 30),
        math.Point(90, 90),
        math.Point(30, 90),
      ],
    ]);
    final mask = refineColorInpaintingMask(image, coarse);
    for (int i = 0; i < coarse.length; i++) {
      if (coarse[i] == 0) expect(mask[i], 0);
    }
  });

  test('不同对白的排字区域重叠时被切开且各自保留原有一侧', () {
    final areas = <List<Rect>>[
      [const Rect.fromLTWH(10, 10, 200, 60)],
      [const Rect.fromLTWH(30, 50, 200, 60)],
      [const Rect.fromLTWH(400, 10, 50, 50)],
    ];
    separateOverlappingTranslationAreas(areas);
    final upper = areas[0].single, lower = areas[1].single;
    expect(upper.overlaps(lower), isFalse);
    expect(upper.top, 10);
    expect(lower.bottom, 110);
    expect(upper.bottom, lessThan(lower.top));
    expect(areas[2].single, const Rect.fromLTWH(400, 10, 50, 50));

    final sideBySide = <List<Rect>>[
      [const Rect.fromLTWH(0, 0, 60, 300)],
      [const Rect.fromLTWH(40, 0, 60, 300)],
    ];
    separateOverlappingTranslationAreas(sideBySide);
    expect(sideBySide[0].single.overlaps(sideBySide[1].single), isFalse);
    expect(sideBySide[0].single.left, 0);
    expect(sideBySide[1].single.right, 100);
  });

  test('页面色彩类型随翻译缓存保存，旧缓存读取为空', () {
    const result = ImageTranslationResult(
      status: ImageTranslationStatus.success,
      translatedText: 'a',
      pageColorMode: PageColorMode.color,
    );
    expect(
      ImageTranslationResult.fromCacheJson(result.toJson()).pageColorMode,
      PageColorMode.color,
    );
    expect(
      ImageTranslationResult.fromCacheJson({'translatedText': 'a'})
          .pageColorMode,
      isNull,
    );
  });
}
