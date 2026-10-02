import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/engine/translation_protocol.dart';
import 'package:jhentai/src/service/image_translation/onomatopoeia_filter.dart';

const _root = 'test/acceptance/image_translation/monochrome_sound_effects';

void main() {
  final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());
  for (final sample in annotation['cases'] as List) {
    final snapshot = jsonDecode(
      File('$_root/${sample['snapshot']}').readAsStringSync(),
    );
    final decisions = snapshot['decisions'] as List;
    final target = sample['misrecognizedText'] as String;
    final recorded = decisions.singleWhere((d) => d['block']['text'] == target);
    final targetBlock = RecognizedTextBlock.fromJson(
      Map<String, dynamic>.from(recorded['block']),
    );

    test('${sample['id']}：重放生产记录，误识别字符不进入翻译且对白完整', () {
      final source = File('$_root/${sample['source']}').readAsBytesSync();
      expect(sha256.convert(source).toString(), sample['sourceSha256']);
      expect(recorded['insideBubble'], isFalse);
      expect(recorded['wasPreserved'], isFalse);
      final retained = <RecognizedTextBlock>[];
      for (final decision in decisions) {
        final block = RecognizedTextBlock.fromJson(
          Map<String, dynamic>.from(decision['block']),
        );
        final preserve = shouldPreserveSoundEffect(
          block.text,
          insideBubble: decision['insideBubble'],
          confidence: block.confidence,
          width: block.width,
          height: block.height,
          matchesSoundEffectStyle: decision['matchesSoundEffectStyle'],
          matchesSoundEffectOutline: decision['matchesSoundEffectOutline'],
        );
        if (block.text == target) {
          expect(
            preserve,
            isTrue,
            reason: '${sample['originalText']} → $target',
          );
        } else {
          expect(preserve, decision['wasPreserved'], reason: block.text);
        }
        if (!preserve) {
          retained.add(block);
        }
      }
      final prompt = buildTranslationPrompt(
        TranslationEngineRequest(
          blocks: retained,
          targetLanguage: '简体中文',
          mergeTextBlocks: false,
        ),
      );
      expect(
        prompt.groups.map((g) => g.textOf(retained)),
        isNot(contains(target)),
      );
      for (final decision in decisions.where(
        (d) => d['insideBubble'] == true,
      )) {
        expect(prompt.prompt, contains(decision['block']['text']));
      }
    });

    test('${sample['id']}：同一字块在气泡内、位置未知或可靠识别时仍翻译', () {
      bool preserve({
        bool? insideBubble = false,
        double? confidence,
        double? width,
        double? height,
      }) => shouldPreserveSoundEffect(
        targetBlock.text,
        insideBubble: insideBubble,
        confidence: confidence ?? targetBlock.confidence,
        width: width ?? targetBlock.width,
        height: height ?? targetBlock.height,
      );

      expect(preserve(insideBubble: true), isFalse);
      expect(preserve(insideBubble: null), isFalse);
      expect(preserve(confidence: .99), isFalse);
      expect(
        preserve(width: targetBlock.height, height: targetBlock.width),
        isFalse,
      );
    });
  }
}
