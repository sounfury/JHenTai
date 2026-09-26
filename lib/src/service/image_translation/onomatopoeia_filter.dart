/// Heuristic detector for manga sound effects (擬音/擬態語) so they can be
/// left untouched instead of being sent to the translator.
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

final RegExp _decoration = RegExp(
  r'[ーｰ〜～~っッ・…‥、。，．,.!！?？♡♥❤☆★♪「」『』（）()]',
);
const int _outsideBubbleMaxLength = 6;
final RegExp _heartAsV = RegExp(r'(?<=[ぁ-ゟ゠-ヿ])[vVｖＶ]+$');
final RegExp _kanaOnly = RegExp(r'^[ぁ-ゟ゠-ヿ]+$');
final RegExp _katakanaOnly = RegExp(r'^[゠-ヿ]+$');
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
