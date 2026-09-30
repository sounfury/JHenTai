import 'dart:convert';
import 'dart:math' as math;

import '../model/image_translation.dart';
import 'ocr_layout_protocol.dart';

/// A cluster of recognized text lines that together form one utterance —
/// typically the lines inside a single speech bubble or caption box. Built by
/// [groupRecognizedTextBlocks] so translation can treat a multi-line utterance
/// as a coherent whole instead of translating each line in isolation (which
/// produces fragmentary, out-of-context translations for manga bubbles).
class RecognizedTextGroup {
  const RecognizedTextGroup({
    required this.blockIndices,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// Indices into the source [RecognizedTextBlock] list, in reading order.
  final List<int> blockIndices;

  /// Combined bounding box (top-left origin, upright image pixel space).
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  /// The member blocks in reading order.
  List<RecognizedTextBlock> blocksOf(List<RecognizedTextBlock> all) => [
    for (final int index in blockIndices) all[index],
  ];

  /// The group's text with its lines joined by newlines — the unit a
  /// translator should translate as one utterance.
  String textOf(List<RecognizedTextBlock> all) =>
      blockIndices.map((int index) => all[index].text.trim()).join('\n');
}

/// Returns the text units used by translation and rendering. When automatic
/// merging is disabled, every OCR block remains an independent unit so the
/// translation and embedding mapping stays strictly one-to-one.
List<RecognizedTextGroup> translationTextGroups(
  List<RecognizedTextBlock> blocks, {
  bool merge = true,
  List<RecognizedTextContainer> containers = const <RecognizedTextContainer>[],
}) {
  if (merge && containers.isNotEmpty) {
    final Set<int> assigned = <int>{};
    final List<RecognizedTextGroup> result = <RecognizedTextGroup>[];
    for (final RecognizedTextContainer container in containers) {
      final List<int> indices = container.blockIndices
          .where((int index) => index >= 0 && index < blocks.length)
          .toList(growable: false);
      if (indices.isEmpty || indices.any(assigned.contains)) continue;
      assigned.addAll(indices);
      result.add(
        RecognizedTextGroup(
          blockIndices: indices,
          left: container.left,
          top: container.top,
          right: container.left + container.width,
          bottom: container.top + container.height,
        ),
      );
    }
    final List<int> remaining = <int>[];
    for (int index = 0; index < blocks.length; index++) {
      if (!assigned.contains(index)) remaining.add(index);
    }
    if (remaining.isNotEmpty) {
      result.addAll(
        groupRecognizedTextBlocks(
          remaining.map((int index) => blocks[index]).toList(growable: false),
        ).map(
          (RecognizedTextGroup group) => RecognizedTextGroup(
            blockIndices: group.blockIndices
                .map((int local) => remaining[local])
                .toList(growable: false),
            left: group.left,
            top: group.top,
            right: group.right,
            bottom: group.bottom,
          ),
        ),
      );
    }
    return result;
  }
  if (merge) {
    return groupRecognizedTextBlocks(blocks);
  }
  return <RecognizedTextGroup>[
    for (int index = 0; index < blocks.length; index++)
      RecognizedTextGroup(
        blockIndices: <int>[index],
        left: blocks[index].left,
        top: blocks[index].top,
        right: blocks[index].left + blocks[index].width,
        bottom: blocks[index].top + blocks[index].height,
      ),
  ];
}

/// The rectangle used when painting one translated utterance.
///
/// OCR boxes are glyph/line boxes, not the whole speech bubble.  Keeping this
/// small value object next to the grouping code makes the same conservative
/// expansion available to the live overlay and exported PNG renderer.
class RecognizedTextGroupRenderBounds {
  const RecognizedTextGroupRenderBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => math.max(0.0, right - left);
  double get height => math.max(0.0, bottom - top);
}

/// Whether [group] has the stable geometry of a multi-line text container.
///
/// This is deliberately a geometry-only heuristic.  CTD's current output is
/// a text-pixel mask rather than a speech-bubble boundary, so a single line
/// cannot be safely classified as a bubble without looking at the source
/// pixels.  Multi-line groups with consistent stacking/column spacing are the
/// safe subset; everything else keeps the OCR-box fallback.
bool isRecognizedTextContainerCandidate(
  RecognizedTextGroup group,
  List<RecognizedTextBlock> blocks,
) {
  if (group.blockIndices.length < 2) {
    return false;
  }
  final List<RecognizedTextBlock> members = group.blocksOf(blocks);
  if (members.any(
    (RecognizedTextBlock block) => block.width <= 0 || block.height <= 0,
  )) {
    return false;
  }
  final bool vertical = _isMostlyVertical(members);
  if (vertical) {
    // Vertical columns of one container overlap in y and sit at a regular
    // horizontal distance.  groupRecognizedTextBlocks already enforces this;
    // the explicit check keeps this helper safe for callers with hand-built
    // groups as well.
    final List<RecognizedTextBlock> ordered = [...members]
      ..sort((a, b) => b.left.compareTo(a.left));
    for (int index = 1; index < ordered.length; index++) {
      final RecognizedTextBlock previous = ordered[index - 1];
      final RecognizedTextBlock current = ordered[index];
      final double overlap =
          math.min(
            previous.top + previous.height,
            current.top + current.height,
          ) -
          math.max(previous.top, current.top);
      if (overlap < 0.45 * math.min(previous.height, current.height)) {
        return false;
      }
    }
    return true;
  }

  final List<RecognizedTextBlock> ordered = [...members]
    ..sort((a, b) => a.top.compareTo(b.top));
  final double medianHeight = _median(
    ordered.map((RecognizedTextBlock block) => block.height).toList(),
  );
  if (medianHeight <= 0) {
    return false;
  }
  for (int index = 1; index < ordered.length; index++) {
    final RecognizedTextBlock previous = ordered[index - 1];
    final RecognizedTextBlock current = ordered[index];
    final double gap = current.top - (previous.top + previous.height);
    if (gap > 1.8 * medianHeight) {
      return false;
    }
    final double previousCenter = previous.left + previous.width / 2;
    final double currentCenter = current.left + current.width / 2;
    if ((currentCenter - previousCenter).abs() >
        math.max(group.width * 0.55, medianHeight * 3)) {
      return false;
    }
  }
  return true;
}

/// Returns the explicit container bounds when OCR has a matching detector
/// result, otherwise null.  We intentionally do not manufacture a bubble from
/// an OCR union: the union describes text, not the enclosing artwork.
RecognizedTextGroupRenderBounds? explicitRenderBoundsForRecognizedTextGroup(
  RecognizedTextGroup group,
  List<RecognizedTextContainer> containers,
) {
  for (final RecognizedTextContainer container in containers) {
    if (container.blockIndices.length != group.blockIndices.length ||
        !container.blockIndices.toSet().containsAll(group.blockIndices)) {
      continue;
    }
    return RecognizedTextGroupRenderBounds(
      left: container.left,
      top: container.top,
      right: container.left + container.width,
      bottom: container.top + container.height,
    );
  }
  return null;
}

List<TranslationLayoutRegion> layoutRegionsForRecognizedTextGroup(
  RecognizedTextGroup group,
  List<RecognizedTextContainer> containers, {
  List<RecognizedTextBlock> blocks = const [],
}) {
  for (final container in containers) {
    if (container.blockIndices.length == group.blockIndices.length &&
        container.blockIndices.toSet().containsAll(group.blockIndices)) {
      final regions =
          container.layoutRegions.where((region) => region.isValid).toList();
      // Model-mask rectangles already lie inside the actual balloon. A
      // concave/transparent balloon need not fill 60% of its enclosing box.
      // Interior regions recover the balloon around the text. When the
      // container is only the text's own bounding box, the analysis can lock
      // onto the white gap between two columns: a strip narrower than the
      // source text, which would shrink the translation into one tiny column.
      final double regionArea = regions.fold(
        0.0,
        (sum, region) => sum + region.width * region.height,
      );
      // Shaded/transparent lobes may disappear from the dominant colour mask.
      // Keep their dialogue where the source columns were instead of moving
      // everything into the one white lobe that survived segmentation.
      final sourceRegions = _sourceColumnRegions(group, blocks);
      final missesSource = sourceRegions.any((source) {
        final covered = regions.fold(0.0, (double sum, region) {
          final width = math.max(
            0.0,
            math.min(source.left + source.width, region.left + region.width) -
                math.max(source.left, region.left),
          );
          final height = math.max(
            0.0,
            math.min(source.top + source.height, region.top + region.height) -
                math.max(source.top, region.top),
          );
          return sum + width * height;
        });
        return covered < source.width * source.height * .8;
      });
      if (sourceRegions.length > 1 && missesSource) {
        return sourceRegions;
      }
      if (container.layoutAnalysisVersion >= 2 && regions.isNotEmpty) {
        return regions;
      }
      // Multiple regions are the detector's concave-balloon partition. Their
      // inset rectangles naturally cover much less of the bounding box (which
      // includes the exterior between lobes). Rejecting them by total coverage
      // collapses all text back into the bounding box's central neck.
      // Keep the strip safeguard for a single recovered region only.
      return regions.length <= 1 &&
              regionArea < group.width * group.height * 0.6
          ? const []
          : regions;
    }
  }
  final sourceRegions = _sourceColumnRegions(group, blocks);
  return sourceRegions.length > 1 ? sourceRegions : const [];
}

/// Conservative fallback for staggered vertical columns. Aligned columns
/// remain one paragraph; a substantial change of starting height starts a lobe.
List<TranslationLayoutRegion> _sourceColumnRegions(
  RecognizedTextGroup group,
  List<RecognizedTextBlock> blocks,
) {
  if (group.blockIndices.any((i) => i < 0 || i >= blocks.length)) {
    return [];
  }
  final members = group.blocksOf(blocks);
  if (members.length < 2 || !_isMostlyVertical(members)) {
    return [];
  }
  members.sort((a, b) => b.left.compareTo(a.left));
  final columnWidth = _median(members.map((b) => b.width).toList());
  final runs = <List<RecognizedTextBlock>>[];
  for (final block in members) {
    final previous = runs.isEmpty ? null : runs.last.last;
    // Connected balloons can start at nearly the same y: a short call in a
    // small lobe sits across a wide gap from the longer paragraph. A top-only
    // split misses that lobe and moves its translation into the large one.
    final separateShortColumn =
        previous != null &&
        previous.left - (block.left + block.width) > columnWidth * .6 &&
        math.min(previous.height, block.height) <
            math.max(previous.height, block.height) * .65;
    if (runs.isEmpty ||
        (block.top - runs.last.first.top).abs() > columnWidth * 1.5 ||
        separateShortColumn) {
      runs.add([block]);
    } else {
      runs.last.add(block);
    }
  }
  final regions =
      runs.map((run) {
        final left = run.map((b) => b.left).reduce(math.min);
        final top = run.map((b) => b.top).reduce(math.min);
        return TranslationLayoutRegion(
          left,
          top,
          run.map((b) => b.left + b.width).reduce(math.max) - left,
          run.map((b) => b.top + b.height).reduce(math.max) - top,
        );
      }).toList();
  // Bad OCR geometry must not create overlapping rendered paragraphs.
  for (int i = 0; i < regions.length; i++) {
    for (int j = i + 1; j < regions.length; j++) {
      final a = regions[i], b = regions[j];
      if (a.left < b.left + b.width &&
          b.left < a.left + a.width &&
          a.top < b.top + b.height &&
          b.top < a.top + a.height) {
        return [];
      }
    }
  }
  return regions;
}

/// Keep line translations attached to their source lobes when the recovered
/// regions each contain complete OCR columns. If the interior partition cuts
/// across columns, retain the ordinary area-based paragraph layout instead.
List<String>? translationTextsForLayoutRegions(
  String translation,
  RecognizedTextGroup group,
  List<RecognizedTextBlock> blocks,
  List<TranslationLayoutRegion> regions,
) {
  if (regions.length < 2) {
    return null;
  }
  final assignments = <int>[];
  for (final block in group.blocksOf(blocks)) {
    if (block.width <= 0 || block.height <= 0) {
      return null;
    }
    int best = -1;
    double bestCoverage = .55;
    for (int i = 0; i < regions.length; i++) {
      final r = regions[i];
      final width = math.max(
        0.0,
        math.min(block.left + block.width, r.left + r.width) -
            math.max(block.left, r.left),
      );
      final height = math.max(
        0.0,
        math.min(block.top + block.height, r.top + r.height) -
            math.max(block.top, r.top),
      );
      final coverage = width * height / (block.width * block.height);
      if (coverage > bestCoverage) {
        bestCoverage = coverage;
        best = i;
      }
    }
    if (best < 0) {
      return null;
    }
    assignments.add(best);
  }
  final lines = splitGroupTranslationIntoLines(
    translation: translation,
    sourceLines: group.blocksOf(blocks).map((b) => b.text).toList(),
  );
  final texts = List.generate(regions.length, (_) => <String>[]);
  for (int i = 0; i < assignments.length; i++) {
    if (lines[i].trim().isNotEmpty) {
      texts[assignments[i]].add(lines[i]);
    }
  }
  if (texts.any((text) => text.isEmpty)) {
    return null;
  }
  return texts.map((text) => text.join('\n')).toList();
}

/// Returns one conservative render rectangle for [group].
///
/// Use a detected container when available, otherwise retain the OCR union.
/// The renderer preserves the source writing direction inside these bounds;
/// vertical columns do not need to be widened for horizontal text.
RecognizedTextGroupRenderBounds renderBoundsForRecognizedTextGroup(
  RecognizedTextGroup group,
  List<RecognizedTextBlock> blocks, {
  RecognizedTextContainer? container,
}) {
  if (container != null && container.width > 0 && container.height > 0) {
    return RecognizedTextGroupRenderBounds(
      left: container.left,
      top: container.top,
      right: container.left + container.width,
      bottom: container.top + container.height,
    );
  }
  return RecognizedTextGroupRenderBounds(
    left: group.left,
    top: group.top,
    right: group.right,
    bottom: group.bottom,
  );
}

double _median(List<double> values) {
  if (values.isEmpty) {
    return 0;
  }
  final List<double> sorted = [...values]..sort();
  final int middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

/// Builds the compact, group-level source used by translation engines. A
/// group is one visual utterance, so its source lines remain together instead
/// of teaching the model to translate detector fragments independently.
String buildGroupedTranslationSource(
  List<RecognizedTextBlock> blocks,
  List<RecognizedTextGroup> groups,
) {
  final StringBuffer source = StringBuffer();
  for (int groupIndex = 0; groupIndex < groups.length; groupIndex++) {
    source.writeln('Group ${groupIndex + 1}:');
    source.writeln(groups[groupIndex].textOf(blocks));
  }
  return source.toString();
}

/// Parses the numbered group format requested by the API/local engines.
///
/// Older cached/local runtimes may still return one number per OCR line. When
/// [legacyCount] is supplied and the response contains a number outside the
/// group range, the same text is parsed using that legacy line count so a
/// model upgrade does not silently shift translations onto the wrong bubble.
List<String> parseNumberedTranslations(
  String text,
  int count, {
  int? legacyCount,
}) {
  final List<int> numbers =
      RegExp(
        r'^\s*(?:group\s*)?(\d+)\s*[:：.)-]?',
        caseSensitive: false,
        multiLine: true,
      ).allMatches(text).map((match) => int.parse(match.group(1)!)).toList();
  final int largest = numbers.isEmpty ? 0 : numbers.reduce(math.max);
  if (legacyCount != null && largest > count) {
    return _parseNumberedTranslations(text, legacyCount);
  }
  return _parseNumberedTranslations(text, count);
}

List<String> _parseNumberedTranslations(String text, int count) {
  final List<String?> result = List<String?>.filled(count, null);
  int fallbackIndex = 0;
  int? currentGroupIndex;
  for (final String rawLine in text.split('\n')) {
    final String line = rawLine.replaceFirst(RegExp(r'^\s*[-*]\s+'), '').trim();
    if (line.isEmpty) continue;
    final RegExpMatch? match = RegExp(
      r'^\s*(?:group\s*)?(\d+)\s*[:：.)-]?\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(line);
    final int? index = match == null ? null : int.tryParse(match.group(1)!);
    if (index != null && index >= 1 && index <= count) {
      currentGroupIndex = index - 1;
      final String content = match!.group(2)!.trim();
      if (content.isNotEmpty) {
        result[currentGroupIndex] = content;
      }
      fallbackIndex = math.max(fallbackIndex, index);
      continue;
    }
    // Models sometimes wrap a numbered bubble's translation across several
    // lines. Keep those lines with the current bubble; otherwise they occupy
    // the next slot and are overwritten by its actual numbered translation.
    if (currentGroupIndex != null) {
      final String? previous = result[currentGroupIndex];
      result[currentGroupIndex] =
          previous == null || previous.isEmpty ? line : '$previous\n$line';
      continue;
    }
    while (fallbackIndex < count && result[fallbackIndex] != null) {
      fallbackIndex++;
    }
    if (fallbackIndex < count) {
      result[fallbackIndex++] = line;
    }
  }
  return result.map((String? line) => line ?? '').toList(growable: false);
}

/// Expands one translated utterance per group back to the detector's blocks.
/// The renderer can then keep a stable 1:1 block mapping while displaying the
/// group as a single coherent text layout.
List<String> expandGroupTranslationsToLines({
  required List<RecognizedTextBlock> blocks,
  required List<RecognizedTextGroup> groups,
  required List<String> groupTranslations,
}) {
  final List<String> lines = List<String>.filled(blocks.length, '');
  for (int groupIndex = 0; groupIndex < groups.length; groupIndex++) {
    final RecognizedTextGroup group = groups[groupIndex];
    final String translation =
        groupIndex < groupTranslations.length
            ? groupTranslations[groupIndex]
            : '';
    final List<String> sourceLines = group.blockIndices
        .map((int index) => blocks[index].text)
        .toList(growable: false);
    final List<String> split = splitGroupTranslationIntoLines(
      translation: translation,
      sourceLines: sourceLines,
    );
    for (
      int lineIndex = 0;
      lineIndex < group.blockIndices.length;
      lineIndex++
    ) {
      lines[group.blockIndices[lineIndex]] =
          lineIndex < split.length ? split[lineIndex] : '';
    }
  }
  return lines;
}

/// Punctuation characters that make a natural end for a bubble line, used when
/// re-splitting a group's translation back into its original line count.
const String _lineBreakPunctuation = '。！？!?．.、，,…⋯';

/// Characters that naturally follow a cut (closing quotes/brackets); a cut
/// after one of these keeps the closer attached to the preceding line.
const String _cutAfterPunctuation = '。！？!?．.、，,…⋯」』）)」』」『』';

/// Splits one group's translated text back into `sourceLines.length` lines so
/// the overlay keeps a 1:1 mapping between recognized blocks and translated
/// text.
///
/// Apple's on-device translation does not reliably preserve the newlines of
/// multi-line input (soft line breaks tend to collapse to spaces), so the
/// group's translated output is re-split here. Prefers preserved line breaks
/// when they already match the line count; otherwise splits at punctuation
/// boundaries proportionally to the source lines' lengths, which fits CJK→CJK
/// manga bubbles well.
List<String> splitGroupTranslationIntoLines({
  required String translation,
  required List<String> sourceLines,
}) {
  final int lineCount = sourceLines.length;
  if (lineCount <= 1) {
    return <String>[translation.trim()];
  }
  // Fast path: the translator happened to preserve the line breaks.
  final List<String> byNewline =
      const LineSplitter()
          .convert(translation)
          .map((String line) => line.trim())
          .where((String line) => line.isNotEmpty)
          .toList();
  if (byNewline.length == lineCount) {
    return byNewline;
  }
  final String text = translation.trim();
  final List<String> result = List<String>.filled(lineCount, '');
  if (text.length < 2) {
    // Nothing to split (e.g. "…" or a one-glyph reply for a two-line bubble).
    result[0] = text;
    return result;
  }
  // Weight each target line by its source length, so a long source line
  // receives a proportionally long share of the translated text.
  final List<int> weights =
      sourceLines
          .map((String line) => math.max(1, line.trim().length))
          .toList();
  final int totalWeight = weights.fold<int>(
    0,
    (int sum, int weight) => sum + weight,
  );
  final List<int> cuts = <int>[];
  int accumulated = 0;
  for (int i = 0; i < lineCount - 1; i++) {
    accumulated += weights[i];
    final int ideal = (text.length * accumulated / totalWeight).round().clamp(
      1,
      text.length - 1,
    );
    cuts.add(_nearestLineBreak(text, ideal));
  }
  int start = 0;
  for (int i = 0; i < lineCount; i++) {
    // Punctuation snapping can move a cut before the previous one.
    final int end = i < cuts.length ? math.max(start, cuts[i]) : text.length;
    result[i] = text.substring(start, end).trim();
    start = end;
  }
  return result;
}

/// Snaps [index] to the nearest character that makes a natural line end,
/// within a couple of characters on either side, so a bubble line does not cut
/// mid-word when a punctuation mark is right there.
int _nearestLineBreak(String text, int index) {
  for (int offset = 0; offset <= 2; offset++) {
    for (final int direction in const <int>[1, -1]) {
      final int candidate = index + direction * offset;
      if (candidate > 0 && candidate < text.length) {
        final String char = text[candidate];
        // A cut after a closing punctuation mark keeps it with the preceding
        // line; a cut at an opening/connecting mark keeps it with the next.
        if (_cutAfterPunctuation.contains(char)) {
          return candidate + 1;
        }
        if (_lineBreakPunctuation.contains(char)) {
          return candidate;
        }
      }
    }
  }
  return index;
}

/// Maximum vertical gap between consecutive lines (as a multiple of the
/// smaller line's height) that still counts as "inside one bubble". Manga line
/// spacing is typically 0.1-0.5x the line height; the white margin between
/// bubbles is usually much larger, so 1.4x separates them.
const double _maxLineGapRatio = 1.4;

/// Maximum horizontal gap between adjacent vertical-text columns (as a
/// multiple of the narrower column) that still counts as "inside one bubble".
/// Mirrors [_maxLineGapRatio] for tategaki (vertical Japanese) text.
const double _maxColumnGapRatio = 1.4;

/// Minimum horizontal overlap of two lines' x-ranges (as a fraction of the
/// narrower line) required to merge. Keeps same-band side-by-side bubbles from
/// merging even when the reading order interleaves their lines.
const double _minOverlapRatio = 0.25;

/// If the x-ranges barely overlap (e.g. a short line centered under a long
/// one), the lines may still be one utterance when their centers align.
const double _maxCenterOffsetRatio = 0.4;

/// When two boxes overlap vertically by more than this fraction of the shorter
/// box they are treated as fragments of the SAME visual row, not as stacked
/// lines of one utterance. The tolerance must be generous: the ONNX detector
/// inflates every box (its `expand` adds roughly 10-15px per side), so two
/// genuinely stacked lines of one bubble routinely overlap by ~40% of the
/// shorter box. A threshold at 0.6 separates those (≤~0.5) from true
/// same-row fragments of a split line (≥~0.8).
const double _maxVerticalOverlapRatio = 0.6;

/// Clusters reading-order-sorted [RecognizedTextBlock]s into utterance groups.
///
/// OCR engines report one block per visual text line, so a single manga speech
/// bubble that spans several lines arrives as several adjacent blocks. This
/// clusters blocks that sit close together vertically AND overlap horizontally
/// (the signature of stacked lines inside one bubble), while keeping blocks
/// from distinct bubbles separate.
///
/// Blocks are processed in reading order but several groups stay "open" at
/// once, so two bubbles side by side whose lines interleave in the
/// top-then-left sort still end up as two groups (each line joins the bubble
/// that is horizontally close to it), rather than a consecutive-window scan
/// which would see A1,B1,A2,B2 and group them wrongly.
///
/// Blocks without usable geometry (e.g. some Paddle outputs that carry text but
/// no box) cannot be placed spatially and always form their own group, so they
/// still translate but never merge neighbors.
List<RecognizedTextGroup> groupRecognizedTextBlocks(
  List<RecognizedTextBlock> blocks,
) {
  if (blocks.isEmpty) {
    return const [];
  }

  // Tategaki (vertical Japanese) pages have tall, narrow columns of text read
  // right-to-left instead of stacked horizontal lines. Grouping uses a
  // different proximity rule for those pages (side-by-side columns instead of
  // stacked lines), so pick the dominant orientation up front — the same
  // heuristic the ONNX detector uses to choose its reading order.
  final bool mostlyVertical = _isMostlyVertical(blocks);

  final List<List<int>> groupIndices = <List<int>>[];
  final List<double> groupLeft = <double>[];
  final List<double> groupTop = <double>[];
  final List<double> groupRight = <double>[];
  final List<double> groupBottom = <double>[];
  // Geometry of the most recently added member per group; null for groups that
  // can no longer accept lines (their last member has no box).
  final List<RecognizedTextBlock?> groupLast = <RecognizedTextBlock?>[];

  void addToGroup(int group, int blockIndex, RecognizedTextBlock block) {
    groupIndices[group].add(blockIndex);
    groupLeft[group] = math.min(groupLeft[group], block.left);
    groupTop[group] = math.min(groupTop[group], block.top);
    groupRight[group] = math.max(groupRight[group], block.left + block.width);
    groupBottom[group] = math.max(groupBottom[group], block.top + block.height);
    groupLast[group] = block;
  }

  void startGroup(int blockIndex, RecognizedTextBlock block) {
    groupIndices.add(<int>[blockIndex]);
    groupLeft.add(block.left);
    groupTop.add(block.top);
    groupRight.add(block.left + block.width);
    groupBottom.add(block.top + block.height);
    groupLast.add(block);
  }

  for (int index = 0; index < blocks.length; index++) {
    final RecognizedTextBlock block = blocks[index];
    if (block.width <= 0 || block.height <= 0) {
      // No usable geometry: its own group, never merged.
      startGroup(index, block);
      continue;
    }

    int? bestGroup;
    double bestScore = 0;
    for (int group = 0; group < groupIndices.length; group++) {
      final RecognizedTextBlock? last = groupLast[group];
      if (last == null || last.width <= 0 || last.height <= 0) {
        continue;
      }
      final double? score =
          mostlyVertical
              ? _verticalGroupMatchScore(last, block)
              : _horizontalGroupMatchScore(last, block);
      if (score != null && score > bestScore) {
        bestScore = score;
        bestGroup = group;
      }
    }

    if (bestGroup != null) {
      addToGroup(bestGroup, index, block);
    } else {
      startGroup(index, block);
    }
  }

  return List<RecognizedTextGroup>.generate(
    groupIndices.length,
    (int group) => RecognizedTextGroup(
      blockIndices: groupIndices[group],
      left: groupLeft[group],
      top: groupTop[group],
      right: groupRight[group],
      bottom: groupBottom[group],
    ),
  );
}

/// Rejoins OCR fragments that touch inside one detected balloon. Short glyph
/// fragments can make a vertical page look horizontal to the grouping
/// heuristic, splitting a phrase such as "週末、楽しみに待ってます" into several
/// translation units. Distant clusters in an oversized detector region stay
/// separate.
List<RecognizedTextGroup> mergeTouchingRecognizedTextGroups(
  List<RecognizedTextGroup> groups,
) {
  if (groups.length < 2) {
    return groups;
  }
  final List<int> parents = List<int>.generate(groups.length, (i) => i);

  int root(int index) {
    while (parents[index] != index) {
      parents[index] = parents[parents[index]];
      index = parents[index];
    }
    return index;
  }

  for (int i = 0; i < groups.length; i++) {
    for (int j = i + 1; j < groups.length; j++) {
      final RecognizedTextGroup a = groups[i];
      final RecognizedTextGroup b = groups[j];
      if (a.width <= 0 || a.height <= 0 || b.width <= 0 || b.height <= 0) {
        continue;
      }
      final double horizontalGap = math.max(
        math.max(a.left - b.right, b.left - a.right),
        0,
      );
      final double verticalOverlap =
          math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
      if (horizontalGap <= 0.1 * math.min(a.width, b.width) &&
          verticalOverlap >= 0.25 * math.min(a.height, b.height)) {
        parents[root(j)] = root(i);
      }
    }
  }

  final Map<int, List<RecognizedTextGroup>> components = {};
  for (int i = 0; i < groups.length; i++) {
    components.putIfAbsent(root(i), () => []).add(groups[i]);
  }
  return <RecognizedTextGroup>[
    for (final List<RecognizedTextGroup> component in components.values)
      RecognizedTextGroup(
        blockIndices: <int>[
          for (final RecognizedTextGroup group in component)
            ...group.blockIndices,
        ]..sort(),
        left: component.map((g) => g.left).reduce(math.min),
        top: component.map((g) => g.top).reduce(math.min),
        right: component.map((g) => g.right).reduce(math.max),
        bottom: component.map((g) => g.bottom).reduce(math.max),
      ),
  ];
}

/// Whether the page is dominated by tall, narrow blocks — the signature of
/// tategaki (vertical Japanese) text columns. Uses the same threshold the ONNX
/// detector applies when choosing its right-to-left reading order.
bool _isMostlyVertical(List<RecognizedTextBlock> blocks) {
  int total = 0;
  int vertical = 0;
  for (final RecognizedTextBlock block in blocks) {
    if (block.width <= 0 || block.height <= 0) {
      continue;
    }
    total++;
    if (block.height > block.width * OcrScoringProtocol.verticalAspectRatio) {
      vertical++;
    }
  }
  return total > 0 && vertical * 2 > total;
}

/// Returns a non-null merge score when [candidate] should join a group whose
/// most recent member is [last], or null when they must stay separate. Higher
/// score = stronger match, so when a line could plausibly join several open
/// groups the best one wins.
double? _horizontalGroupMatchScore(
  RecognizedTextBlock last,
  RecognizedTextBlock candidate,
) {
  final double lastBottom = last.top + last.height;
  final double candidateBottom = candidate.top + candidate.height;

  // Same visual row (boxes overlap vertically by a large fraction): the
  // detector split one line into pieces, not a stacked utterance.
  final double verticalOverlap =
      math.min(lastBottom, candidateBottom) - math.max(last.top, candidate.top);
  if (verticalOverlap >
      _maxVerticalOverlapRatio * math.min(last.height, candidate.height)) {
    return null;
  }

  // Vertically close enough to be stacked lines of one bubble.
  final double gap = candidate.top - lastBottom;
  final double maxGap =
      _maxLineGapRatio * math.min(last.height, candidate.height);
  if (gap > maxGap) {
    return null;
  }

  // Horizontally close: overlapping x-ranges, or centered under each other.
  final double lastLeft = last.left;
  final double lastRight = last.left + last.width;
  final double candidateLeft = candidate.left;
  final double candidateRight = candidate.left + candidate.width;
  final double overlap =
      math.min(lastRight, candidateRight) - math.max(lastLeft, candidateLeft);
  final double overlapRatio = overlap / math.min(last.width, candidate.width);
  if (overlapRatio >= _minOverlapRatio) {
    // A small edge overlap is not enough to prove that two lines belong to
    // one bubble. In 00.33.31, for example, the last line of the left bubble
    // overlaps the first line of the right bubble by ~25%, which previously
    // merged two separate utterances and destroyed translation context.
    final double lastCenter = last.left + last.width / 2;
    final double candidateCenter = candidate.left + candidate.width / 2;
    final double centerDistance = (candidateCenter - lastCenter).abs();
    if (overlapRatio >= 0.55 ||
        centerDistance <=
            _maxCenterOffsetRatio * math.max(last.width, candidate.width)) {
      return overlapRatio;
    }
    return null;
  }
  final double lastCenter = last.left + last.width / 2;
  final double candidateCenter = candidate.left + candidate.width / 2;
  final double centerDistance = (candidateCenter - lastCenter).abs();
  if (centerDistance <=
      _maxCenterOffsetRatio * math.max(last.width, candidate.width)) {
    final double fit =
        1 - centerDistance / math.max(last.width, candidate.width);
    return 0.1 + 0.5 * fit;
  }
  return null;
}

/// Merge score for tategaki (vertical text) pages: columns of one bubble sit
/// side by side — a small horizontal gap between their x-extents and a large
/// vertical overlap — unlike horizontal lines, which stack vertically.
double? _verticalGroupMatchScore(
  RecognizedTextBlock last,
  RecognizedTextBlock candidate,
) {
  final double lastBottom = last.top + last.height;
  final double lastRight = last.left + last.width;
  final double candidateBottom = candidate.top + candidate.height;
  final double candidateRight = candidate.left + candidate.width;

  // Must overlap vertically (side-by-side columns, not stacked bubbles).
  final double verticalOverlap =
      math.min(lastBottom, candidateBottom) - math.max(last.top, candidate.top);
  if (verticalOverlap < 0.5 * math.min(last.height, candidate.height)) {
    return null;
  }

  // Horizontally close: the gap between the two x-extents must be small
  // relative to the narrower column. Symmetric, so it works whether the next
  // column is to the left (RTL reading order) or right.
  final double horizontalGap = math.max(
    math.max(last.left - candidateRight, candidate.left - lastRight),
    0,
  );
  final double maxGap =
      _maxColumnGapRatio * math.min(last.width, candidate.width);
  if (horizontalGap > maxGap) {
    return null;
  }
  return 1 - horizontalGap / maxGap;
}

/// Unchanged text needs neither a backing plate nor erasure. Ignore whitespace
/// because grouped translations may flatten the OCR's visual line breaks.
bool translationPreservesSource(String source, String translation) {
  String compact(String value) => value.replaceAll(RegExp(r'\s+'), '');
  final String original = compact(source);
  return original.isNotEmpty && original == compact(translation);
}
