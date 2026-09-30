import 'dart:convert';

import 'package:jhentai/src/utils/image_text_grouping.dart';

import 'context_translation_contract.dart';
import 'engine_contract.dart';

class TranslationPrompt {
  const TranslationPrompt({
    required this.instruction,
    required this.prompt,
    this.groups = const <RecognizedTextGroup>[],
  });

  final String instruction;
  final String prompt;
  final List<RecognizedTextGroup> groups;
}

TranslationPrompt buildContextTranslationPrompt(
  ContextTranslationEngineRequest request,
) {
  const String instruction =
      'Translate comic dialogue using neighboring pages as context. '
      'Translate every supplied item, including onomatopoeia, cries, and sound effects inside speech bubbles, into natural target-language words. '
      'Sound effects outside speech bubbles have already been excluded. '
      'Return only one JSON object with a translations array. Every item must contain the exact input pageId and lineId plus translated text. '
      'Return items only for targetPageIds, preserve every target line exactly once, and never add markdown, commentary, or reasoning.';
  return TranslationPrompt(
    instruction: instruction,
    prompt: jsonEncode(<String, dynamic>{
      'targetLanguage': request.targetLanguage,
      'sourceLanguage': request.sourceLanguage,
      'targetPageIds': request.targetPageIds,
      'pages': request.pages
          .map((ContextTranslationPageRequest page) => page.toJson())
          .toList(growable: false),
      'responseSchema': <String, dynamic>{
        'translations': <Map<String, String>>[
          <String, String>{
            'pageId': 'exact input pageId',
            'lineId': 'exact input lineId',
            'text': 'translated text',
          },
        ],
      },
    }),
  );
}

ContextTranslationResult parseContextTranslationResponse(dynamic value) {
  if (value is Map && value['translations'] is List) {
    return ContextTranslationResult.fromJson(value);
  }
  final String? text =
      value is String
          ? value
          : value is Map
          ? (value['translatedText'] ?? value['text'])?.toString()
          : null;
  if (text == null || text.trim().isEmpty) {
    throw const FormatException(
      'The translation response contained no context translation.',
    );
  }
  final String cleaned =
      stripTranslationReasoning(text)
          .replaceFirst(
            RegExp(r'^\s*```(?:json)?\s*', caseSensitive: false),
            '',
          )
          .replaceFirst(RegExp(r'\s*```\s*$'), '')
          .trim();
  final int start = cleaned.indexOf('{');
  final int end = cleaned.lastIndexOf('}');
  if (start < 0 || end < start) {
    throw const FormatException(
      'Context translation response did not contain a JSON object.',
    );
  }
  return ContextTranslationResult.fromJson(
    jsonDecode(cleaned.substring(start, end + 1)),
  );
}

TranslationPrompt buildTranslationPrompt(TranslationEngineRequest request) {
  final List<RecognizedTextGroup> groups = translationTextGroups(
    request.blocks,
    merge: request.mergeTextBlocks,
    containers: request.containers,
  );
  final String numberedSource = buildGroupedTranslationSource(
    request.blocks,
    groups,
  );
  const String instruction =
      'You translate comic dialogue accurately. Each numbered group is one speech bubble or utterance. '
      'Translate the whole group as one natural, context-aware utterance. Keep names, tone, hesitation, '
      'and profanity faithful to the source. Translate every supplied group, including onomatopoeia, cries, and sound effects inside speech bubbles, into natural target-language words. '
      'Sound effects outside speech bubbles have already been excluded. Return exactly one translated line per group, '
      'using the same group number (for example "1: ..."). Do not split a group into extra lines, '
      'add headings or commentary, or include reasoning/think blocks.';
  return TranslationPrompt(
    instruction: instruction,
    prompt:
        'Translate the following comic text into ${request.targetLanguage}. Keep the same group numbers:\n\n$numberedSource',
    groups: groups,
  );
}

TranslationResult parseTranslationResponse(
  String text,
  TranslationEngineRequest request,
  TranslationPrompt prompt,
) {
  final List<String> groupTranslations = parseNumberedTranslations(
    stripTranslationReasoning(text),
    prompt.groups.length,
    legacyCount: request.blocks.length,
  );
  final List<String> lines = expandGroupTranslationsToLines(
    blocks: request.blocks,
    groups: prompt.groups,
    groupTranslations: groupTranslations,
  );
  return TranslationResult(
    translatedText: lines.join('\n'),
    lines: lines,
    groupTranslations: groupTranslations,
  );
}

String stripTranslationReasoning(String text) =>
    text
        .replaceAllMapped(
          RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
          (_) => '',
        )
        .replaceAllMapped(
          RegExp(r'<thinking>[\s\S]*?</thinking>', caseSensitive: false),
          (_) => '',
        )
        .replaceAllMapped(
          RegExp(r'\[/?reasoning\]', caseSensitive: false),
          (_) => '',
        )
        .replaceAll(RegExp(r'\n\s*\n+'), '\n')
        .trim();
