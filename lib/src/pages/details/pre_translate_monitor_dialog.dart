import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/gallery_pre_translate_preference.dart';
import 'package:jhentai/src/service/gallery_pre_translate_runner.dart';
import 'package:jhentai/src/service/image_translation_service.dart';

import 'details_page_logic.dart';

/// The detail page's live, per-page view of pre-translation and cache hits.
class PreTranslateMonitorDialog extends StatefulWidget {
  const PreTranslateMonitorDialog({
    super.key,
    required this.logic,
    required this.gid,
    required this.initialEnabled,
    required this.initialOptions,
    required this.pageCount,
  });

  final DetailsPageLogic logic;
  final int gid;
  final bool initialEnabled;
  final GalleryPreTranslateOptions initialOptions;
  final int pageCount;

  @override
  State<PreTranslateMonitorDialog> createState() =>
      _PreTranslateMonitorDialogState();
}

class _PreTranslateMonitorDialogState extends State<PreTranslateMonitorDialog> {
  static const Color _ink = Color(0xFF17172D);
  static const Color _muted = Color(0xFF77788F);
  static const Color _purple = Color(0xFF6952C7);
  static const Color _line = Color(0xFFE8E6F5);

  late bool _enabled = widget.initialEnabled;
  late int _pageCount = widget.initialOptions.pageCount.clamp(
    1,
    math.max(1, widget.pageCount),
  );
  late int _concurrency = widget.initialOptions.concurrency.clamp(1, 20);
  late int _savedPageCount = _pageCount;
  late int _savedConcurrency = _concurrency;
  final ScrollController _scrollController = ScrollController();
  bool _busy = false;

  bool get _optionsChanged =>
      _pageCount != _savedPageCount || _concurrency != _savedConcurrency;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _saveOptions() async {
    if (!_optionsChanged) {
      return;
    }
    final GalleryPreTranslateOptions options = GalleryPreTranslateOptions(
      pageCount: _pageCount,
      concurrency: _concurrency,
    );
    await GalleryPreTranslatePreference.saveOptions(widget.gid, options);
    _savedPageCount = options.pageCount;
    _savedConcurrency = options.concurrency;
  }

  Future<void> _applyOptions() async {
    if (_busy) {
      return;
    }
    final bool resume = galleryPreTranslateRunner.isRunningFor(widget.gid);
    setState(() => _busy = true);
    try {
      await _saveOptions();
      if (resume) {
        await widget.logic.restartPreTranslate();
      } else {
        await widget.logic.inspectPreTranslate();
      }
      _enabled = await widget.logic.isPreTranslateEnabled();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _runAction(bool running) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      if (running) {
        await widget.logic.togglePreTranslate();
      } else {
        await _saveOptions();
        if (_enabled) {
          await widget.logic.restartPreTranslate();
        } else {
          await widget.logic.togglePreTranslate();
        }
      }
      _enabled = await widget.logic.isPreTranslateEnabled();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          width: math.min(screen.width - 32, 1040),
          height: math.min(screen.height - 32, 800),
          decoration: const BoxDecoration(color: Color(0xFFFDFDFF)),
          child: GetBuilder<GalleryPreTranslateRunner>(
            id: galleryPreTranslateRunner.progressIdFor(widget.gid),
            builder:
                (_) => GetBuilder<ImageTranslationService>(
                  id: ImageTranslationService.readerStateId,
                  builder: (_) => _buildContent(context),
                ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final PreTranslateJobProgress? job = galleryPreTranslateRunner.progressFor(
      widget.gid,
    );
    final bool running = galleryPreTranslateRunner.isRunningFor(widget.gid);
    final bool inspecting = job?.status == PreTranslateJobStatus.inspecting;
    final bool alreadyTarget = widget.logic.isGalleryAlreadyInTargetLanguage();
    final int total =
        job?.total ??
        (widget.pageCount <= 0
            ? 0
            : math.min(_savedPageCount, widget.pageCount));
    final int completed = job?.completed ?? 0;
    final int active =
        job?.pages
            .where(
              (page) =>
                  page.phase == PreTranslatePagePhase.preparing ||
                  page.phase == PreTranslatePagePhase.processing ||
                  page.phase == PreTranslatePagePhase.repairing,
            )
            .length ??
        0;
    final int success =
        job?.pages
            .where(
              (page) => page.terminalStatus == ImageTranslationStatus.success,
            )
            .length ??
        0;
    final int failed =
        job?.pages
            .where(
              (page) =>
                  page.terminalStatus == ImageTranslationStatus.downloadError ||
                  page.terminalStatus == ImageTranslationStatus.ocrError ||
                  page.terminalStatus == ImageTranslationStatus.failed,
            )
            .length ??
        0;
    final int percent = total == 0 ? 0 : (completed * 100 / total).round();
    final bool allCached = total > 0 && completed == total && failed == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Scrollbar(
            controller: _scrollController,
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverToBoxAdapter(
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFFFBFAFF), Color(0xFFF8F7FD)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(30, 26, 30, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _header(context, job),
                        const SizedBox(height: 18),
                        _settingsControls(),
                        const SizedBox(height: 18),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final double width = constraints.maxWidth;
                            final int columns =
                                width >= 780 ? 5 : (width >= 480 ? 3 : 2);
                            final double cardWidth =
                                (width - (columns - 1) * 12) / columns;
                            return Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                _statCard(
                                  cardWidth,
                                  Icons.layers_outlined,
                                  'preTranslateConcurrency'.tr,
                                  '${job?.concurrency ?? math.min(_savedConcurrency, total)}',
                                  _purple,
                                  const Color(0xFFF0ECFE),
                                ),
                                _statCard(
                                  cardWidth,
                                  Icons.article_outlined,
                                  'preTranslateMonitorCompleted'.tr,
                                  '$completed / $total',
                                  const Color(0xFF5879D9),
                                  const Color(0xFFEDF2FF),
                                ),
                                _statCard(
                                  cardWidth,
                                  Icons.sync,
                                  'preTranslateMonitorActive'.tr,
                                  '$active',
                                  const Color(0xFF5579DB),
                                  const Color(0xFFEDF2FF),
                                ),
                                _statCard(
                                  cardWidth,
                                  Icons.check,
                                  'preTranslateMonitorSuccess'.tr,
                                  '$success',
                                  const Color(0xFF269A6D),
                                  const Color(0xFFE9F8F0),
                                ),
                                _statCard(
                                  cardWidth,
                                  Icons.close,
                                  'preTranslateMonitorFailed'.tr,
                                  '$failed',
                                  const Color(0xFFD14E58),
                                  const Color(0xFFFDECEE),
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 26),
                        Row(
                          children: [
                            Text(
                              'preTranslateMonitorProgress'.tr,
                              style: const TextStyle(
                                color: _ink,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(9),
                                child: LinearProgressIndicator(
                                  value: total == 0 ? 0 : completed / total,
                                  minHeight: 12,
                                  color: _purple,
                                  backgroundColor: const Color(0xFFE8E7F6),
                                ),
                              ),
                            ),
                            const SizedBox(width: 20),
                            Text(
                              '$percent%',
                              style: const TextStyle(
                                color: _purple,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(
                  child: Divider(height: 1, color: _line),
                ),
                _body(
                  context,
                  job: job,
                  inspecting: inspecting,
                  alreadyTarget: alreadyTarget,
                  completed: completed,
                  total: total,
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: _line),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.info_outline, color: _muted, size: 20),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'preTranslateMonitorCloseHint'.tr,
                      style: const TextStyle(color: _muted, fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (_optionsChanged)
                    OutlinedButton.icon(
                      onPressed:
                          _busy || alreadyTarget || widget.pageCount <= 0
                              ? null
                              : _applyOptions,
                      icon: const Icon(Icons.check_rounded),
                      label: Text(
                        running
                            ? 'preTranslateMonitorApplyAndContinue'.tr
                            : 'preTranslateMonitorApply'.tr,
                      ),
                    ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _purple,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFE8E6F1),
                      disabledForegroundColor: _muted,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 17,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed:
                        _busy ||
                                (inspecting && !running) ||
                                (!running &&
                                    ((allCached && !_optionsChanged) ||
                                        alreadyTarget ||
                                        total == 0))
                            ? null
                            : () => _runAction(running),
                    icon: Icon(
                      running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    ),
                    label: Text(
                      running
                          ? 'preTranslateMonitorStop'.tr
                          : allCached && !_optionsChanged
                          ? 'preTranslateMonitorAllDone'.tr
                          : completed > 0
                          ? 'preTranslateMonitorContinue'.tr
                          : 'preTranslateMonitorStart'.tr,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _settingsControls() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final List<Widget> controls = [
          _settingSlider(
            label: 'preTranslatePageCount'.tr,
            valueLabel:
                _pageCount == widget.pageCount
                    ? 'preTranslateMonitorWholeGallery'.trParams({
                      'count': '$_pageCount',
                    })
                    : 'imageTranslationContextPagesValue'.trParams({
                      'count': '$_pageCount',
                    }),
            value: _pageCount,
            max: math.max(1, widget.pageCount),
            onChanged:
                widget.pageCount <= 1 || _busy
                    ? null
                    : (value) => setState(() => _pageCount = value),
          ),
          _settingSlider(
            label: 'preTranslateConcurrency'.tr,
            valueLabel: '$_concurrency',
            value: _concurrency,
            max: 20,
            onChanged:
                _busy ? null : (value) => setState(() => _concurrency = value),
          ),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (constraints.maxWidth >= 600)
              Row(
                children: [
                  Expanded(child: controls[0]),
                  const SizedBox(width: 20),
                  Expanded(child: controls[1]),
                ],
              )
            else
              ...controls,
            Text(
              'preTranslateMonitorSettingsHint'.tr,
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        );
      },
    );
  }

  Widget _settingSlider({
    required String label,
    required String valueLabel,
    required int value,
    required int max,
    required ValueChanged<int>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: _ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              valueLabel,
              style: const TextStyle(
                color: _purple,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: _purple,
            inactiveTrackColor: _line,
            thumbColor: _purple,
            showValueIndicator: ShowValueIndicator.onDrag,
          ),
          child: Slider(
            min: 1,
            max: math.max(2, max).toDouble(),
            divisions: max > 1 ? max - 1 : 1,
            value: value.toDouble(),
            label: valueLabel,
            semanticFormatterCallback: (_) => valueLabel,
            onChanged:
                onChanged == null ? null : (value) => onChanged(value.round()),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, PreTranslateJobProgress? job) {
    final String status =
        job == null
            ? 'preTranslateMonitorNotStarted'.tr
            : switch (job.status) {
              PreTranslateJobStatus.inspecting =>
                'preTranslateMonitorCheckingCache'.tr,
              PreTranslateJobStatus.ready => 'preTranslateMonitorReady'.tr,
              PreTranslateJobStatus.waiting => 'preTranslateMonitorWaiting'.tr,
              PreTranslateJobStatus.preparing =>
                'preTranslateMonitorPreparing'.tr,
              PreTranslateJobStatus.running => 'preTranslateMonitorRunning'.tr,
              PreTranslateJobStatus.completed => 'preTranslateMonitorDone'.tr,
              PreTranslateJobStatus.canceled =>
                'preTranslateMonitorCanceled'.tr,
              PreTranslateJobStatus.failed => 'preTranslateMonitorFailed'.tr,
            };
    return Row(
      children: [
        Container(
          width: 66,
          height: 66,
          decoration: BoxDecoration(
            color: const Color(0xFFF0ECFF),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(Icons.translate_rounded, color: _purple, size: 33),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'preTranslate'.tr,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color:
                          job?.status == PreTranslateJobStatus.completed
                              ? const Color(0xFF2CA378)
                              : job?.status == PreTranslateJobStatus.running
                              ? _purple
                              : const Color(0xFFBEC0CE),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      status,
                      style: const TextStyle(color: _muted, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, color: Color(0xFF595C72), size: 28),
        ),
      ],
    );
  }

  Widget _statCard(
    double width,
    IconData icon,
    String label,
    String value,
    Color accent,
    Color iconBackground,
  ) => Container(
    width: width,
    height: 105,
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.75),
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(13),
    ),
    child: Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: iconBackground,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: accent, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
              const SizedBox(height: 3),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 23,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _body(
    BuildContext context, {
    required PreTranslateJobProgress? job,
    required bool inspecting,
    required bool alreadyTarget,
    required int completed,
    required int total,
  }) {
    if (total == 0) {
      return _emptyState('preTranslateMonitorNoPages'.tr, '');
    }
    if (alreadyTarget) {
      return _emptyState('preTranslateAlreadyTargetLanguageToast'.tr, '');
    }
    if (inspecting && completed == 0) {
      return _emptyState(
        'preTranslateMonitorCheckingCache'.tr,
        '',
        loading: true,
      );
    }
    if (job == null ||
        (job.status == PreTranslateJobStatus.ready && completed == 0)) {
      return _emptyState(
        'preTranslateMonitorNotStarted'.tr,
        'preTranslateMonitorStartHint'.tr,
      );
    }
    return SliverLayoutBuilder(
      builder:
          (context, constraints) => SliverPadding(
            padding: const EdgeInsets.all(24),
            sliver: SliverGrid.builder(
              itemCount: job.total,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: constraints.crossAxisExtent >= 680 ? 2 : 1,
                mainAxisExtent: 67,
                crossAxisSpacing: 12,
                mainAxisSpacing: 10,
              ),
              itemBuilder:
                  (context, index) => _pageTile(index, job.pages[index]),
            ),
          ),
    );
  }

  Widget _emptyState(String title, String subtitle, {bool loading = false}) {
    return SliverLayoutBuilder(
      builder:
          (context, sliverConstraints) => SliverToBoxAdapter(
            child: SizedBox(
              height: math.max(
                220,
                sliverConstraints.viewportMainAxisExtent -
                    sliverConstraints.precedingScrollExtent,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final bool compact = constraints.maxHeight < 340;
                  return Center(
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: EdgeInsets.all(compact ? 12 : 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Stack(
                              alignment: Alignment.center,
                              children: [
                                Container(
                                  width: compact ? 104 : 148,
                                  height: compact ? 104 : 148,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFF4F1FF),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                Container(
                                  width: compact ? 68 : 94,
                                  height: compact ? 84 : 116,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0xFF8D78DB),
                                        Color(0xFFB3A7E8),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x33755AC5),
                                        blurRadius: 20,
                                        offset: Offset(0, 10),
                                      ),
                                    ],
                                  ),
                                  child: const Center(
                                    child: Icon(
                                      Icons.translate_rounded,
                                      color: Colors.white,
                                      size: 42,
                                    ),
                                  ),
                                ),
                                if (loading)
                                  const Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        color: _purple,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            SizedBox(height: compact ? 12 : 24),
                            Text(
                              title,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _ink,
                                fontSize: compact ? 20 : 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (subtitle.isNotEmpty) ...[
                              SizedBox(height: compact ? 6 : 10),
                              Text(
                                subtitle,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: _muted,
                                  fontSize: compact ? 13 : 15,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
    );
  }

  Widget _pageTile(int index, PreTranslatePageProgress page) {
    final ImageTranslationResult result =
        page.cacheKey == null
            ? const ImageTranslationResult.idle()
            : imageTranslationService.resultFor(page.cacheKey!);
    final ImageTranslationStatus status = page.terminalStatus ?? result.status;
    final bool active =
        page.phase == PreTranslatePagePhase.preparing ||
        page.phase == PreTranslatePagePhase.processing ||
        page.phase == PreTranslatePagePhase.repairing ||
        page.phase == PreTranslatePagePhase.inspecting;
    final Color color = switch (status) {
      ImageTranslationStatus.success => const Color(0xFF2A9B71),
      ImageTranslationStatus.downloadError ||
      ImageTranslationStatus.ocrError ||
      ImageTranslationStatus.failed => const Color(0xFFD14E58),
      ImageTranslationStatus.canceled => _muted,
      _ => _purple,
    };
    final String label = _pageStatusLabel(page, status);
    final String? error = page.errorMessage ?? result.errorMessage;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child:
                active
                    ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color,
                      ),
                    )
                    : Icon(
                      status == ImageTranslationStatus.success
                          ? Icons.check_rounded
                          : status == ImageTranslationStatus.failed ||
                              status == ImageTranslationStatus.ocrError ||
                              status == ImageTranslationStatus.downloadError
                          ? Icons.close_rounded
                          : Icons.schedule_rounded,
                      color: color,
                      size: 19,
                    ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'preTranslateMonitorPage'.trParams({'page': '${index + 1}'}),
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (error != null &&
                    page.phase == PreTranslatePagePhase.finished &&
                    status != ImageTranslationStatus.canceled &&
                    status != ImageTranslationStatus.noText)
                  Text(
                    error,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 11),
                  ),
              ],
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _pageStatusLabel(
    PreTranslatePageProgress page,
    ImageTranslationStatus status,
  ) {
    if (page.phase == PreTranslatePagePhase.waiting) {
      return 'preTranslateMonitorWaiting'.tr;
    }
    if (page.phase == PreTranslatePagePhase.inspecting) {
      return 'preTranslateMonitorCheckingCache'.tr;
    }
    if (page.phase == PreTranslatePagePhase.preparing) {
      return 'preTranslateMonitorPreparing'.tr;
    }
    if (page.phase == PreTranslatePagePhase.repairing) {
      return 'translationStageMasking'.tr;
    }
    return switch (status) {
      ImageTranslationStatus.idle ||
      ImageTranslationStatus.queued => 'preTranslateMonitorPreparing'.tr,
      ImageTranslationStatus.downloading => 'preTranslateMonitorDownloading'.tr,
      ImageTranslationStatus.recognizing => 'translationStageRecognizing'.tr,
      ImageTranslationStatus.translating => 'translationStageTranslating'.tr,
      ImageTranslationStatus.success =>
        page.fromCache
            ? 'preTranslateMonitorCached'.tr
            : 'preTranslateMonitorSuccess'.tr,
      ImageTranslationStatus.noText => 'preTranslateMonitorSkipped'.tr,
      ImageTranslationStatus.canceled => 'preTranslateMonitorCanceled'.tr,
      ImageTranslationStatus.downloadError ||
      ImageTranslationStatus.ocrError ||
      ImageTranslationStatus.failed => 'preTranslateMonitorFailed'.tr,
    };
  }
}
