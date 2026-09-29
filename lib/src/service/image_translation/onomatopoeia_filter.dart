/// Heuristic detector for manga sound effects (擬音/擬態語).
///
/// A block is treated as onomatopoeia when, after stripping decoration
/// (long-vowel marks, small tsu, punctuation, hearts), it is pure kana with
/// no kanji and either:
/// - is katakana-only and short (ドキドキ, ズン, バッ), or
/// - repeats a unit (どきどき, ぱんぱん), or
/// - ends in a drawn-out vowel (わああ, ひいい), or
/// - ends in a small tsu / long mark / cries like "ぁぁ" (あっ, んんっ), or
/// - sits outside every detected speech bubble ([insideBubble] == false) and
///   is short: hand-lettered SFX and moans (わああ♥, ひゃあん) live between
///   balloons, while dialogue such as ちょっと stays inside them.
bool isOnomatopoeia(String text, {bool? insideBubble}) {
  final String trimmed = text
      .replaceAll(RegExp(r'\s'), '')
      // OCR often reads a hand-drawn heart as a trailing "v".
      .replaceAll(_heartAsV, '♡');
  if (trimmed.isEmpty) {
    return false;
  }
  final String core = trimmed.replaceAll(_decoration, '');
  if (core.isEmpty) {
    // Only marks such as "ーーッ！！" or "♡♡".
    return true;
  }
  if (!_kanaOnly.hasMatch(core)) {
    return false;
  }
  final int length = core.runes.length;
  if (insideBubble == false && length <= _outsideBubbleMaxLength) {
    return true;
  }
  if (_katakanaOnly.hasMatch(core) && length <= 8) {
    return true;
  }
  if (_isRepeated(core)) {
    return true;
  }
  if (_drawnOutVowel.hasMatch(core) && length <= 5) {
    return true;
  }
  final bool decoratedTail = _decoratedTail.hasMatch(trimmed);
  return decoratedTail && length <= 4;
}

/// Keep effects outside speech bubbles in the artwork. Hand-lettered effects
/// may be OCR'd as a digit plus katakana
/// ("4チ" for "ムチッ") or a couple of Latin capitals ("VH"). Limit those
/// fallback cases to low-confidence, vertically drawn blocks so ordinary
/// captions are still translated. Without bubble detection, preserve only a
/// small vocabulary of unambiguous effects, not arbitrary short kana/dialogue.
bool shouldPreserveSoundEffect(
  String text, {
  required bool? insideBubble,
  double? confidence,
  double? width,
  double? height,
  bool matchesSoundEffectStyle = false,
}) {
  final plain = text.replaceAll(RegExp(r'\s'), '').replaceAll(_decoration, '');
  // Missing transparent balloons are not proof that short grammatical
  // dialogue (e.g. a separate vertical 「って」 column) is a sound effect.
  if (_dialogueFragments.contains(text.replaceAll(_dialoguePunctuation, ''))) {
    return false;
  }
  if (insideBubble == null) {
    final core = text.replaceAll(RegExp(r'\s'), '').replaceAll(_decoration, '');
    return _standaloneEffects.contains(core);
  }
  if (insideBubble) {
    return false;
  }
  if (matchesSoundEffectStyle &&
      confidence != null &&
      confidence < .8 &&
      plain.runes.length <= 2) {
    return true;
  }
  if (isOnomatopoeia(text, insideBubble: false)) {
    return true;
  }
  if (confidence == null ||
      confidence >= 0.8 ||
      width == null ||
      height == null ||
      height < width * 1.4) {
    return false;
  }
  final String core = text
      .replaceAll(RegExp(r'\s'), '')
      .replaceAll(_decoration, '');
  return (_digitKatakana.hasMatch(core) && _digit.hasMatch(core)) ||
      (confidence < 0.7 && _shortLatinCapitals.hasMatch(core));
}

final RegExp _decoration = RegExp(r'[ーｰ〜～~っッ・…‥、。，．,.!！?？♡♥❤☆★♪「」『』（）()]');
const _standaloneEffects = {
  'ドキ',
  'ドキドキ',
  'どきどき',
  'ソワ',
  'ソワソワ',
  'そわそわ',
  'ビク',
  'ビクビク',
  'びくびく',
  'ガタガタ',
  'ガタン',
  'バタン',
  'ズキ',
  'ズキズキ',
  'ワクワク',
  'わくわく',
  'キラキラ',
};
const _dialogueFragments = {
  'って',
  'から',
  'ので',
  'けど',
  'でも',
  'だって',
  'です',
  'ます',
  'はい',
  'いいえ',
  'そう',
  'なに',
  'なんで',
  'どうして',
  'ちょっと',
};
final _dialoguePunctuation = RegExp(r'[\s…‥、。，．,.!！?？「」『』（）()]');
const int _outsideBubbleMaxLength = 6;
final RegExp _heartAsV = RegExp(r'(?<=[ぁ-ゟ゠-ヿ])[vVｖＶ]+$');
final RegExp _kanaOnly = RegExp(r'^[ぁ-ゟ゠-ヿ]+$');
final RegExp _katakanaOnly = RegExp(r'^[゠-ヿ]+$');
final RegExp _digitKatakana = RegExp(r'^[0-9０-９゠-ヿ]{2,4}$');
final RegExp _digit = RegExp(r'[0-9０-９]');
final RegExp _shortLatinCapitals = RegExp(r'^[A-Z]{1,2}$');
// Cries stretched with a repeated vowel: わああ, ひいい, んんん.
final RegExp _drawnOutVowel = RegExp(r'([あいうえおぁぃぅぇぉん])\1+$');
final RegExp _decoratedTail = RegExp(r'[ーｰ〜～~っッぁぃぅぇぉァィゥェォ♡♥❤]+[!！?？…‥]*$');

bool _isRepeated(String core) {
  final List<int> runes = core.runes.toList();
  for (int unit = 1; unit <= runes.length ~/ 2; unit++) {
    if (runes.length % unit != 0) {
      continue;
    }
    bool repeated = true;
    for (int i = unit; i < runes.length && repeated; i++) {
      repeated = runes[i] == runes[i % unit];
    }
    if (repeated) {
      return true;
    }
  }
  return false;
}
