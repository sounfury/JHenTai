import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/image_translation/onomatopoeia_filter.dart';
import 'package:jhentai/src/utils/image_text_grouping.dart';
import 'package:jhentai/src/utils/image_translation_typography.dart';

const _root = 'test/acceptance/image_translation/senpai_background_loss';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final snapshot = jsonDecode(
    File('$_root/pipeline_snapshot.json').readAsStringSync(),
  );
  final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());
  final blocks =
      (snapshot['blocks'] as List)
          .map(
            (b) => RecognizedTextBlock.fromJson(Map<String, dynamic>.from(b)),
          )
          .toList();
  final containers =
      (snapshot['containers'] as List)
          .map(
            (c) =>
                RecognizedTextContainer.fromJson(Map<String, dynamic>.from(c)),
          )
          .toList();
  final groups = translationTextGroups(blocks, containers: containers);
  final group = groups.singleWhere(
    (g) => g.textOf(blocks).contains(annotation['targetSourceText']),
  );
  final target = blocks.singleWhere(
    (b) => b.text == annotation['targetSourceText'],
  );

  test('真实图片与 OCR 快照匹配，先輩～属于对白', () {
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
        reason: '案例材料需要人工审核后更新：${entry.key}',
      );
    }
    final source =
        image.decodeImage(File('$_root/source.png').readAsBytesSync())!;
    expect(source.width, annotation['sourceWidth']);
    expect(source.height, annotation['sourceHeight']);
    expect(target.confidence, greaterThan(.9));
    expect(shouldPreserveSoundEffect(target.text, insideBubble: true), isFalse);
    expect(File('$_root/observed.png').existsSync(), isTrue);
    expect(File('$_root/observed_detail.png').existsSync(), isTrue);
  });

  test('相连气泡必须为右侧短对白保留独立绘制区域', () {
    final regions = layoutRegionsForRecognizedTextGroup(
      group,
      containers,
      blocks: blocks,
    );
    final targetRect = Rect.fromLTWH(
      target.left,
      target.top,
      target.width,
      target.height,
    );
    expect(regions.length, greaterThanOrEqualTo(2), reason: '只返回大气泡的区域会让小气泡空白');
    expect(
      regions.any((r) {
        final overlap = Rect.fromLTWH(
          r.left,
          r.top,
          r.width,
          r.height,
        ).intersect(targetRect);
        return !overlap.isEmpty &&
            overlap.width * overlap.height >=
                targetRect.width * targetRect.height * .8;
      }),
      isTrue,
      reason: '小气泡的先輩～位置必须被绘制区域覆盖',
    );
  });

  test('小气泡绘制前辈～，整组译文保持完整', () {
    final regions = layoutRegionsForRecognizedTextGroup(
      group,
      containers,
      blocks: blocks,
    );
    final translation = group.blockIndices
        .map((i) => annotation['translations'][blocks[i].text] as String)
        .join('\n');
    final entries = layoutTranslationInRegions(
      translation,
      regions
          .map((r) => Rect.fromLTWH(r.left, r.top, r.width, r.height))
          .toList(),
      TextDirection.ltr,
      maxFontSize: 17,
      vertical: true,
      regionTexts: translationTextsForLayoutRegions(
        translation,
        group,
        blocks,
        regions,
      ),
    );
    final small = entries.where(
      (e) => e.$1.contains(
        Offset(target.left + target.width / 2, target.top + target.height / 2),
      ),
    );
    expect(small, hasLength(1), reason: '小气泡必须实际获得文字');
    expect(
      small.single.$2.trim(),
      annotation['targetTranslation'],
      reason: '前辈～必须留在小气泡，不能混入大气泡',
    );
    expect(
      entries.map((e) => e.$2).join().replaceAll(RegExp(r'\s'), ''),
      translation.replaceAll(RegExp(r'\s'), ''),
    );
    expect(entries.every((e) => e.$3 > 0), isTrue);
  });
}
