/// 漫画拟声词、拟态词的文本启发式判定。
///
/// 去掉长音、促音、标点、爱心等装饰后，只剩装饰符号的文本视为拟声词；
/// 非空文本必须是纯假名，并满足以下任一条件：
/// - 纯片假名且长度不超过 8，例如 ドキドキ、ズン、バッ；
/// - 同一单元重复出现，例如 どきどき、ぱんぱん；
/// - 末尾元音或「ん」重复且长度不超过 5，例如 わああ、ひいい；
/// - 原文末尾带促音、长音、小元音或爱心，去装饰后长度不超过 4；
/// - 位于气泡外（[insideBubble] == false），去装饰后长度不超过 6。
/// 这里只判定文本特征；是否保留原图由 [shouldPreserveSoundEffect] 决定。
bool isOnomatopoeia(String text, {bool? insideBubble}) {
  final String trimmed = text
      .replaceAll(RegExp(r'\s'), '')
      // OCR 经常把手绘爱心识别成假名末尾的「v」。
      .replaceAll(_heartAsV, '♡');
  if (trimmed.isEmpty) {
    return false;
  }
  final String core = trimmed.replaceAll(_decoration, '');
  if (core.isEmpty) {
    // 文本只有装饰符号，例如「ーーッ！！」或「♡♡」。
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

/// 主入口：根据气泡位置决定是否保留原图文字：
/// 气泡内始终翻译；气泡外使用完整规则；位置不确定时，
/// 在排除对白例外后，只有描边证据或明确拟声词词表可以支持保留。
bool shouldPreserveSoundEffect(
  String text, {
  required bool? insideBubble,
  double? confidence,
  double? width,
  double? height,
  bool matchesSoundEffectStyle = false,
  bool matchesSoundEffectOutline = false,
}) {
  if (insideBubble == true) {
    return false;
  }
  if (insideBubble == false) {
    return _shouldPreserveOutsideBubble(
      text,
      confidence: confidence,
      width: width,
      height: height,
      matchesSoundEffectStyle: matchesSoundEffectStyle,
      matchesSoundEffectOutline: matchesSoundEffectOutline,
    );
  }
  return _shouldPreserveUnknownLocation(
    text,
    matchesSoundEffectOutline: matchesSoundEffectOutline,
  );
}

/// 位置不确定：先保护对白，再检查描边和明确拟声词词表。
/// 不使用宽泛的短假名规则，也不使用 OCR 误识别兜底规则。
bool _shouldPreserveUnknownLocation(
  String text, {
  required bool matchesSoundEffectOutline,
}) {
  if (_isDialogueFragment(text)) {
    return false;
  }
  if (matchesSoundEffectOutline) {
    return true;
  }
  final core = text.replaceAll(RegExp(r'\s'), '').replaceAll(_decoration, '');
  return _standaloneEffects.contains(core);
}

/// 气泡外：先保护对白，再检查视觉证据、文本拟声词特征，
/// 最后检查低置信度的竖排 OCR 误识别。
bool _shouldPreserveOutsideBubble(
  String text, {
  required double? confidence,
  required double? width,
  required double? height,
  required bool matchesSoundEffectStyle,
  required bool matchesSoundEffectOutline,
}) {
  // 透明气泡可能漏检，不能据此把单独一列「って」等短对白当作拟声词。
  if (_isDialogueFragment(text)) {
    return false;
  }
  if (matchesSoundEffectOutline) {
    return true;
  }
  final plain = text.replaceAll(RegExp(r'\s'), '').replaceAll(_decoration, '');
  if (matchesSoundEffectStyle &&
      confidence != null &&
      confidence < .8 &&
      plain.runes.length <= 2) {
    return true;
  }
  if (isOnomatopoeia(text, insideBubble: false)) {
    return true;
  }
  return _isLikelySoundEffectOcrError(
    plain,
    confidence: confidence,
    width: width,
    height: height,
  );
}

bool _isDialogueFragment(String text) =>
    _dialogueFragments.contains(text.replaceAll(_dialoguePunctuation, ''));

/// 花体拟声词可能被 OCR 读成数字加片假名（把「ムチッ」读成「4チ」），
/// 或短英文字母（如「VH」「n」）。仅对低置信度且竖长的字块使用此兜底。
bool _isLikelySoundEffectOcrError(
  String core, {
  required double? confidence,
  required double? width,
  required double? height,
}) {
  if (confidence == null ||
      width == null ||
      height == null ||
      height < width * 1.3) {
    return false;
  }
  final bool vertical = height >= width * 1.4;
  // 数字混片假名维持原门槛；短纯数字的置信度门槛放宽到 0.85，
  // 避免略高于 0.8 的竖排花体误识别直接进入翻译。
  final bool digitKatakanaError =
      vertical &&
      confidence < 0.8 &&
      _digitKatakana.hasMatch(core) &&
      _digit.hasMatch(core);
  final bool digitError =
      vertical && confidence < 0.85 && _shortDigits.hasMatch(core);
  // 短英文字母同时涵盖大小写，并允许高度为宽度 1.3 倍的略竖长字块；
  // 仍要求置信度低于 0.7，避免保留正常、高置信度的英文。
  final bool latinError = confidence < 0.7 && _shortLatinLetters.hasMatch(core);
  return digitKatakanaError || digitError || latinError;
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
final RegExp _shortDigits = RegExp(r'^[0-9０-９]{2,4}$');
final RegExp _shortLatinLetters = RegExp(r'^[A-Za-z]{1,2}$');
// 通过重复元音或「ん」拉长的叫声，例如 わああ、ひいい、んんん。
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
