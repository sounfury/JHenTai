import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:extended_image/extended_image.dart';
import 'package:get/get.dart' hide Response;
import 'package:jhentai/src/model/detail_page_info.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/archive_download_service.dart';
import 'package:jhentai/src/service/gallery_download/download_path_resolver.dart';
import 'package:jhentai/src/service/gallery_download/gallery_download_service.dart';
import 'package:jhentai/src/service/gallery_download/gallery_images_retainer.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/image_inpainting_service.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/service/jh_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/setting/image_translation_setting.dart';
import 'package:jhentai/src/utils/gallery_image_translation_language.dart';
import 'package:jhentai/src/utils/bounded_page_jobs.dart';
import 'package:jhentai/src/setting/site_setting.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';
import 'package:jhentai/src/utils/image_cache_util.dart';
import 'package:path/path.dart' as p;
import 'package:retry/retry.dart';

/// Ahead-of-time translation of a gallery's first N pages, started from the
/// detail page so the reader can hydrate from the persistent cache.
///
/// Reuses [ImageTranslationService] batch progress / cancel so the existing
/// mini-window and per-page terminal statuses keep working without the read
/// page being open.
GalleryPreTranslateRunner galleryPreTranslateRunner =
    GalleryPreTranslateRunner();

enum PreTranslateJobStatus {
  inspecting,
  ready,
  waiting,
  preparing,
  running,
  completed,
  canceled,
  failed,
}

enum PreTranslatePagePhase {
  waiting,
  inspecting,
  preparing,
  processing,
  repairing,
  finished,
}

class PreTranslatePageProgress {
  PreTranslatePagePhase phase = PreTranslatePagePhase.waiting;
  String? cacheKey;
  ImageTranslationStatus? terminalStatus;
  String? errorMessage;
  bool fromCache = false;
}

class PreTranslateJobProgress {
  PreTranslateJobProgress({
    required this.gid,
    required this.total,
    required this.concurrency,
  }) : pages = List<PreTranslatePageProgress>.generate(
         total,
         (_) => PreTranslatePageProgress(),
       );

  final int gid;
  final int total;
  final int concurrency;
  final List<PreTranslatePageProgress> pages;
  PreTranslateJobStatus status = PreTranslateJobStatus.inspecting;
  _ResolvedSources? _sources;
  final Map<int, ImageTranslationRequest> _preparedRequests = {};

  int get completed =>
      pages
          .where(
            (PreTranslatePageProgress page) =>
                page.phase == PreTranslatePagePhase.finished,
          )
          .length;
}

class GalleryPreTranslateRunner extends GetxController
    with JHLifeCircleBeanErrorCatch, GalleryImagesRetainer
    implements JHLifeCircleBean {
  int? _activeGid;
  int _jobEpoch = 0;
  Future<void>? _jobFuture;
  final Map<int, Future<void>> _inspections = {};
  final Set<int> _finishedGids = <int>{};
  final Map<int, PreTranslateJobProgress> _jobs =
      <int, PreTranslateJobProgress>{};

  String progressIdFor(int gid) => 'preTranslateProgress::$gid';

  PreTranslateJobProgress? progressFor(int gid) => _jobs[gid];

  /// Gid currently owned by an in-flight detail-page pre-translate job.
  int? get activeGid => _activeGid;

  bool isRunningFor(int gid) => _activeGid == gid;

  /// True when a detail-page job is running for [gid], or finished this session
  /// (so the reader should not kick off a second full batch).
  bool isActiveOrFinished(int gid) =>
      isRunningFor(gid) || _finishedGids.contains(gid);

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies
        ..add(imageTranslationService)
        ..add(imageInpaintingService)
        ..add(imageTranslationSetting)
        ..add(galleryDownloadService)
        ..add(archiveDownloadService);

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
  }

  @override
  Future<void> doAfterBeanReady() async {}

  /// Reads existing page translations without starting OCR or translation.
  /// The dialog uses this to show cache hits before the user starts a job.
  void inspectForGallery({
    required GalleryUrl galleryUrl,
    required int pageCount,
    List<GalleryThumbnail>? seedThumbnails,
  }) {
    if (pageCount <= 0 || isRunningFor(galleryUrl.gid)) {
      return;
    }
    final int gid = galleryUrl.gid;
    if (_inspections.containsKey(gid)) {
      return;
    }
    final int total = imageTranslationSetting.preTranslatePageCount.value.clamp(
      1,
      pageCount,
    );
    final PreTranslateJobProgress job = PreTranslateJobProgress(
      gid: gid,
      total: total,
      concurrency: imageTranslationSetting.preTranslateConcurrency.value.clamp(
        1,
        total,
      ),
    );
    _jobs[gid] = job;
    update([progressIdFor(gid)]);
    final Future<void> inspection = _inspectJob(
      job: job,
      galleryUrl: galleryUrl,
      pageCount: pageCount,
      seedThumbnails: seedThumbnails,
    );
    _inspections[gid] = inspection;
    unawaited(
      inspection.whenComplete(() {
        if (identical(_inspections[gid], inspection)) {
          _inspections.remove(gid);
        }
      }),
    );
  }

  Future<void> _inspectJob({
    required PreTranslateJobProgress job,
    required GalleryUrl galleryUrl,
    required int pageCount,
    List<GalleryThumbnail>? seedThumbnails,
  }) async {
    final int gid = job.gid;
    bool current() => identical(_jobs[gid], job);
    try {
      final _ResolvedSources sources = await _resolveSources(
        galleryUrl: galleryUrl,
        pageCount: pageCount,
        count: job.total,
        seedThumbnails: seedThumbnails,
        isCurrent: current,
      );
      if (!current()) return;
      job._sources = sources;
      await runBoundedPageJobs(
        total: job.total,
        concurrency: job.concurrency,
        shouldStop: () => !current(),
        runPage: (int index) async {
          final GalleryImage? image = sources.images[index];
          if (image == null) return;
          _setPage(job, index, PreTranslatePagePhase.inspecting);
          try {
            final ImageTranslationRequest? request = await _buildRequest(
              index: index,
              image: image,
              mode: sources.mode,
              reportProgress: false,
            );
            if (request == null || !current()) return;
            job._preparedRequests[index] = request;
            final ImageTranslationStatus? cachedStatus =
                await imageTranslationService.cachedStatusForRequest(request);
            if (!current()) {
              return;
            }
            if (cachedStatus == ImageTranslationStatus.success ||
                cachedStatus == ImageTranslationStatus.noText) {
              job.pages[index].fromCache = true;
              _setPage(
                job,
                index,
                PreTranslatePagePhase.finished,
                cacheKey: request.cacheKey,
                terminalStatus: cachedStatus,
              );
            }
          } catch (error, stack) {
            log.warning('Pre-translate cache check failed at $index: $error');
            log.trace(stack);
          } finally {
            if (current() &&
                job.pages[index].phase == PreTranslatePagePhase.inspecting) {
              _setPage(job, index, PreTranslatePagePhase.waiting);
            }
          }
        },
      );
      if (current()) {
        final bool allCached = job.completed == job.total;
        if (allCached) _finishedGids.add(gid);
        _setJobStatus(
          job,
          allCached
              ? PreTranslateJobStatus.completed
              : PreTranslateJobStatus.ready,
        );
      }
    } catch (error, stack) {
      log.warning('Pre-translate cache inspection failed for gid=$gid: $error');
      log.trace(stack);
      if (current()) _setJobStatus(job, PreTranslateJobStatus.ready);
    } finally {
      releaseGalleryImages(gid);
    }
  }

  /// Starts (or restarts) pre-translate for [galleryUrl]'s first N pages.
  /// Non-blocking: returns after scheduling the background job.
  ///
  /// When [galleryLanguage] / [galleryTagsCsv] indicate the gallery is already
  /// in [imageTranslationSetting.targetLanguage], the job is not started.
  void startForGallery({
    required GalleryUrl galleryUrl,
    required int pageCount,
    List<GalleryThumbnail>? seedThumbnails,
    String? galleryLanguage,
    String? galleryTagsCsv,
  }) {
    final int gid = galleryUrl.gid;
    if (pageCount <= 0) {
      return;
    }
    if (GalleryImageTranslationLanguage.matchesCurrentTarget(
      language: galleryLanguage,
      tagsCsv: galleryTagsCsv,
    )) {
      log.info(
        'Skip pre-translate for gid=$gid: gallery already in target language '
        '(${imageTranslationSetting.targetLanguage.value})',
      );
      return;
    }
    // Single shared translation pipeline — stop any other gallery's job first.
    final int? previous = _activeGid;
    final PreTranslateJobProgress? inspected = _jobs[gid];
    if (previous != null) {
      cancelForGallery(previous);
    }
    cancelForGallery(gid);
    _finishedGids.remove(gid);
    final int total = imageTranslationSetting.preTranslatePageCount.value.clamp(
      1,
      pageCount,
    );
    final int concurrency = imageTranslationSetting
        .preTranslateConcurrency
        .value
        .clamp(1, total);
    final PreTranslateJobProgress job =
        previous != gid &&
                inspected != null &&
                inspected.total == total &&
                inspected.concurrency == concurrency
            ? inspected
            : PreTranslateJobProgress(
              gid: gid,
              total: total,
              concurrency: concurrency,
            );
    _jobs[gid] = job;
    update([progressIdFor(gid)]);
    final int epoch = ++_jobEpoch;
    final Future<void>? previousJob = _jobFuture;
    final Future<void>? inspection = _inspections[gid];
    _activeGid = gid;
    _jobFuture = () async {
      if (previousJob != null) {
        await previousJob;
      }
      if (inspection != null) {
        await inspection;
      }
      if (!_isCurrent(epoch, gid)) {
        return;
      }
      if (job.completed == job.total) {
        _setJobStatus(job, PreTranslateJobStatus.completed);
        _finishedGids.add(gid);
        _activeGid = null;
        return;
      }
      await _runJob(
        job: job,
        epoch: epoch,
        galleryUrl: galleryUrl,
        pageCount: pageCount,
        seedThumbnails: seedThumbnails,
      );
    }();
    unawaited(_jobFuture);
  }

  /// Cancels an in-flight job for [gid] if this runner owns it.
  void cancelForGallery(int gid) {
    _finishedGids.remove(gid);
    if (_activeGid != gid) {
      return;
    }
    _jobEpoch++;
    imageTranslationService.cancelBatch();
    final PreTranslateJobProgress? job = _jobs[gid];
    if (job != null) {
      job.status = PreTranslateJobStatus.canceled;
      update([progressIdFor(gid)]);
    }
    _activeGid = null;
    releaseGalleryImages(gid);
  }

  Future<void> _runJob({
    required PreTranslateJobProgress job,
    required int epoch,
    required GalleryUrl galleryUrl,
    required int pageCount,
    List<GalleryThumbnail>? seedThumbnails,
  }) async {
    final int gid = galleryUrl.gid;
    final int n = job.total;
    final int generation = imageTranslationService.beginBatch(n);
    final int concurrency = job.concurrency;
    bool completedCleanly = false;
    try {
      _setJobStatus(job, PreTranslateJobStatus.preparing);
      final _ResolvedSources sources =
          job._sources ??
          await _resolveSources(
            galleryUrl: galleryUrl,
            pageCount: pageCount,
            count: n,
            seedThumbnails: seedThumbnails,
            isCurrent: () => _isCurrent(epoch, gid),
          );
      if (!_isCurrent(epoch, gid)) {
        _cancelRemaining(sources.requests, 0, generation, job);
        return;
      }
      _setJobStatus(job, PreTranslateJobStatus.running);
      final int nextIndex = await runBoundedPageJobs(
        total: n,
        concurrency: concurrency,
        shouldStop:
            () =>
                !_isCurrent(epoch, gid) ||
                imageTranslationService.isCancelRequested,
        runPage: (int index) async {
          final PreTranslatePageProgress page = job.pages[index];
          if (page.terminalStatus == ImageTranslationStatus.success ||
              page.terminalStatus == ImageTranslationStatus.noText) {
            final ImageTranslationRequest? prepared =
                job._preparedRequests[index];
            if (prepared != null &&
                await imageTranslationService.hydrateResult(prepared)) {
              imageTranslationService.recordBatchResult(
                prepared.cacheKey,
                generation: generation,
              );
              _setPage(job, index, PreTranslatePagePhase.finished);
              return;
            }
            // The source or cache may have changed since inspection.
            _setPage(job, index, PreTranslatePagePhase.waiting);
          }
          await _translateOne(
            job: job,
            index: index,
            image: sources.images[index],
            mode: sources.mode,
            generation: generation,
            requests: sources.requests,
          );
        },
      );
      if (!_isCurrent(epoch, gid) ||
          imageTranslationService.isCancelRequested) {
        _cancelRemaining(sources.requests, nextIndex, generation, job);
      }
      completedCleanly =
          _isCurrent(epoch, gid) && !imageTranslationService.isCancelRequested;
    } catch (e, stack) {
      log.warning('Gallery pre-translate failed for gid=$gid: $e');
      log.trace(stack);
    } finally {
      imageTranslationService.endBatch(generation);
      _setJobStatus(
        job,
        job.status == PreTranslateJobStatus.canceled
            ? PreTranslateJobStatus.canceled
            : completedCleanly
            ? PreTranslateJobStatus.completed
            : PreTranslateJobStatus.failed,
      );
      if (_activeGid == gid && epoch == _jobEpoch) {
        _activeGid = null;
        if (completedCleanly) {
          _finishedGids.add(gid);
        }
      }
      releaseGalleryImages(gid);
    }
  }

  bool _isCurrent(int epoch, int gid) =>
      epoch == _jobEpoch && _activeGid == gid;

  void _setJobStatus(
    PreTranslateJobProgress job,
    PreTranslateJobStatus status,
  ) {
    if (!identical(_jobs[job.gid], job)) {
      return;
    }
    job.status = status;
    update([progressIdFor(job.gid)]);
  }

  void _setPage(
    PreTranslateJobProgress job,
    int index,
    PreTranslatePagePhase phase, {
    String? cacheKey,
    ImageTranslationStatus? terminalStatus,
  }) {
    if (!identical(_jobs[job.gid], job)) {
      return;
    }
    final PreTranslatePageProgress page = job.pages[index];
    page.phase = phase;
    if (phase == PreTranslatePagePhase.waiting) {
      page.terminalStatus = null;
      page.errorMessage = null;
      page.fromCache = false;
    }
    if (cacheKey != null) {
      page.cacheKey = cacheKey;
    }
    if (terminalStatus != null) {
      page.terminalStatus = terminalStatus;
      page.errorMessage = null;
    } else if (phase == PreTranslatePagePhase.finished &&
        page.cacheKey != null) {
      final ImageTranslationResult result = imageTranslationService.resultFor(
        page.cacheKey!,
      );
      page.terminalStatus = result.status;
      page.errorMessage = result.errorMessage;
      page.fromCache = page.fromCache || result.fromCache;
    }
    update([progressIdFor(job.gid)]);
  }

  void _cancelRemaining(
    Map<int, ImageTranslationRequest> requests,
    int from,
    int generation,
    PreTranslateJobProgress job,
  ) {
    if (!imageTranslationService.isCurrentBatch(generation)) {
      return;
    }
    for (int i = from; i < imageTranslationService.batchTotal; i++) {
      final String cacheKey = requests[i]?.cacheKey ?? 'pretranslate-page:$i';
      imageTranslationService.markCanceled(cacheKey);
      imageTranslationService.recordBatchResult(
        cacheKey,
        generation: generation,
      );
      _setPage(job, i, PreTranslatePagePhase.finished, cacheKey: cacheKey);
    }
  }

  Future<_ResolvedSources> _resolveSources({
    required GalleryUrl galleryUrl,
    required int pageCount,
    required int count,
    required List<GalleryThumbnail>? seedThumbnails,
    required bool Function() isCurrent,
  }) async {
    final int gid = galleryUrl.gid;
    final GalleryDownloadInfo? downloadInfo =
        galleryDownloadService.galleryDownloadInfos[gid];
    if (downloadInfo?.downloadProgress != null) {
      await retainGalleryImages(gid);
      if (!isCurrent()) {
        return _ResolvedSources.empty(ReadMode.downloaded, count);
      }
      final List<GalleryImage?>? images = downloadInfo!.images;
      if (images != null && images.isNotEmpty) {
        return _ResolvedSources(
          mode: ReadMode.downloaded,
          images: List<GalleryImage?>.generate(
            count,
            (int i) => i < images.length ? images[i] : null,
          ),
          requests: <int, ImageTranslationRequest>{},
        );
      }
    }

    final ArchiveDownloadInfo? archiveInfo =
        archiveDownloadService.archiveDownloadInfos[gid];
    if (archiveInfo?.archiveStatus == ArchiveStatus.completed) {
      final List<GalleryImage> images = await archiveDownloadService
          .getUnpackedImages(gid);
      if (!isCurrent()) {
        return _ResolvedSources.empty(ReadMode.archive, count);
      }
      return _ResolvedSources(
        mode: ReadMode.archive,
        images: List<GalleryImage?>.generate(
          count,
          (int i) => i < images.length ? images[i] : null,
        ),
        requests: <int, ImageTranslationRequest>{},
      );
    }

    // Online: resolve thumbnail hrefs then image page URLs for the first N.
    final List<GalleryThumbnail?> thumbnails = List<GalleryThumbnail?>.filled(
      pageCount,
      null,
    );
    if (seedThumbnails != null) {
      for (int i = 0; i < seedThumbnails.length && i < pageCount; i++) {
        thumbnails[i] = seedThumbnails[i];
      }
    }
    int thumbnailsCountPerPage = SiteSetting.thumbnailsCountPerPage.value;
    for (int index = 0; index < count; index++) {
      if (!isCurrent()) {
        break;
      }
      if (thumbnails[index] != null) {
        continue;
      }
      final int requestPageIndex = index ~/ thumbnailsCountPerPage;
      try {
        final DetailPageInfo detailPageInfo = await retry(
          () => ehRequest.requestDetailPage(
            galleryUrl: galleryUrl.url,
            thumbnailsPageIndex: requestPageIndex,
            parser: EHSpiderParser.detailPage2RangeAndThumbnails,
          ),
          maxAttempts: 3,
          retryIf: (e) => e is DioException,
        );
        thumbnailsCountPerPage = detailPageInfo.thumbnailsCountPerPage;
        for (
          int i = detailPageInfo.imageNoFrom;
          i <= detailPageInfo.imageNoTo && i < pageCount;
          i++
        ) {
          thumbnails[i] =
              detailPageInfo.thumbnails[i - detailPageInfo.imageNoFrom];
        }
      } catch (e, stack) {
        log.warning('Pre-translate thumbnail fetch failed at index $index: $e');
        log.trace(stack);
      }
    }

    final List<GalleryImage?> images = List<GalleryImage?>.filled(count, null);
    await runBoundedPageJobs(
      total: count,
      concurrency: 3,
      shouldStop: () => !isCurrent(),
      runPage: (int index) async {
        final GalleryThumbnail? thumb = thumbnails[index];
        if (thumb == null) {
          return;
        }
        try {
          images[index] = await retry(
            () => ehRequest.requestImagePage(
              thumb.replacedMPVHref(index + 1),
              parser: EHSpiderParser.imagePage2GalleryImage,
              useCacheIfAvailable: true,
            ),
            maxAttempts: 3,
            retryIf: (e) => e is DioException,
          );
        } catch (e, stack) {
          log.warning('Pre-translate image URL parse failed at $index: $e');
          log.trace(stack);
        }
      },
    );

    return _ResolvedSources(
      mode: ReadMode.online,
      images: images,
      requests: <int, ImageTranslationRequest>{},
    );
  }

  Future<void> _translateOne({
    required PreTranslateJobProgress job,
    required int index,
    required GalleryImage? image,
    required ReadMode mode,
    required int generation,
    required Map<int, ImageTranslationRequest> requests,
  }) async {
    final String fallbackKey = 'pretranslate-page:$index';
    _setPage(job, index, PreTranslatePagePhase.preparing);
    if (image == null) {
      imageTranslationService.markDownloadError(
        fallbackKey,
        'IMAGE_SOURCE_UNAVAILABLE',
      );
      imageTranslationService.recordBatchResult(
        fallbackKey,
        generation: generation,
      );
      _setPage(
        job,
        index,
        PreTranslatePagePhase.finished,
        cacheKey: fallbackKey,
      );
      return;
    }

    ImageTranslationRequest? request;
    try {
      final ImageTranslationRequest? prepared = job._preparedRequests[index];
      request =
          prepared?.imagePath != null &&
                  await File(prepared!.imagePath!).exists()
              ? prepared
              : await _buildRequest(
                index: index,
                image: image,
                mode: mode,
                onKey:
                    (String key) => _setPage(
                      job,
                      index,
                      PreTranslatePagePhase.processing,
                      cacheKey: key,
                    ),
              );
    } catch (e, stack) {
      log.warning(
        'Pre-translate source preparation failed for page $index: $e',
      );
      log.trace(stack);
    }
    if (request == null) {
      imageTranslationService.markDownloadError(
        fallbackKey,
        'IMAGE_SOURCE_UNAVAILABLE',
      );
      imageTranslationService.recordBatchResult(
        fallbackKey,
        generation: generation,
      );
      _setPage(
        job,
        index,
        PreTranslatePagePhase.finished,
        cacheKey: fallbackKey,
      );
      return;
    }
    requests[index] = request;
    _setPage(
      job,
      index,
      PreTranslatePagePhase.processing,
      cacheKey: request.cacheKey,
    );
    imageTranslationService.queue(request.cacheKey);

    try {
      await imageTranslationService.translate(request, preprocessNoText: true);
      if (imageTranslationSetting.imageProcessingDisplayMode.value !=
              ImageProcessingDisplayMode.overlay &&
          imageTranslationService.resultFor(request.cacheKey).status ==
              ImageTranslationStatus.success) {
        _setPage(job, index, PreTranslatePagePhase.repairing);
      }
      await _maybeRepair(request);
    } catch (e, stack) {
      log.warning('Pre-translate page $index failed: $e');
      log.trace(stack);
      final ImageTranslationResult result = imageTranslationService.resultFor(
        request.cacheKey,
      );
      if (!result.isTerminal) {
        imageTranslationService.markOcrError(
          request.cacheKey,
          'TRANSLATION_TASK_FAILED',
        );
      }
    }
    imageTranslationService.recordBatchResult(
      request.cacheKey,
      generation: generation,
    );
    _setPage(job, index, PreTranslatePagePhase.finished);
  }

  Future<ImageTranslationRequest?> _buildRequest({
    required int index,
    required GalleryImage image,
    required ReadMode mode,
    void Function(String cacheKey)? onKey,
    bool reportProgress = true,
  }) async {
    if (mode == ReadMode.online) {
      final String url = effectiveEHImageUrl(image.url);
      final String cacheKey = normalizedImageCacheKey(url);
      final String taskKey = 'online:$cacheKey';
      onKey?.call(taskKey);
      if (!reportProgress &&
          imageTranslationService.resultFor(taskKey).status ==
              ImageTranslationStatus.success &&
          !imageTranslationService.needsCachedArtifactCheck(taskKey)) {
        return ImageTranslationRequest(cacheKey: taskKey, sourceUrl: url);
      }
      if (reportProgress) {
        imageTranslationService.markDownloading(taskKey);
      }
      try {
        final File? file = await _ensureOnlineImageFile(
          url,
          cacheKey,
          fetchOnline: reportProgress,
        ).timeout(const Duration(seconds: 30));
        if (file != null && await file.exists()) {
          return ImageTranslationRequest(
            cacheKey: taskKey,
            sourceUrl: url,
            imagePath: file.path,
          );
        }
      } catch (e, stack) {
        log.warning('Pre-translate download failed for page $index: $e');
        log.trace(stack);
      }
      if (reportProgress) {
        imageTranslationService.markDownloadError(
          taskKey,
          'IMAGE_DOWNLOAD_TIMEOUT',
        );
      }
      return ImageTranslationRequest(cacheKey: taskKey, sourceUrl: url);
    }
    if (mode == ReadMode.downloaded && image.path != null) {
      onKey?.call('downloaded:${image.path}');
      return ImageTranslationRequest(
        cacheKey: 'downloaded:${image.path}',
        imagePath:
            DownloadPathResolver.computeImageDownloadAbsolutePathFromRelativePath(
              image.path!,
            ),
      );
    }
    if (mode == ReadMode.archive && image.path != null) {
      onKey?.call('archive:${image.path}');
      return ImageTranslationRequest(
        cacheKey: 'archive:${image.path}',
        imagePath: p.join(pathService.getVisibleDir().path, image.path!),
      );
    }
    return null;
  }

  Future<File?> _ensureOnlineImageFile(
    String url,
    String cacheKey, {
    bool fetchOnline = true,
  }) async {
    final String directoryPath = await getExtendedImageDiskCacheDirectory();
    final File? compatible = await findCompatibleImageCacheFile(
      directory: directoryPath,
      url: url,
    );
    if (compatible != null && await compatible.exists()) {
      return compatible;
    }
    if (!fetchOnline) {
      return null;
    }
    final File cacheFile = File(p.join(directoryPath, cacheKey));
    final ExtendedNetworkImageProvider provider = ExtendedNetworkImageProvider(
      url,
      cache: true,
      cacheKey: cacheKey,
      retries: 1,
      printError: false,
    );
    Uint8List? bytes = await provider.getNetworkImageData();
    try {
      if (bytes == null) {
        return null;
      }
      if (!await cacheFile.exists()) {
        await Directory(directoryPath).create(recursive: true);
        await cacheFile.writeAsBytes(bytes, flush: true);
      }
      return await cacheFile.exists() ? cacheFile : null;
    } finally {
      bytes = null;
    }
  }

  Future<void> _maybeRepair(ImageTranslationRequest request) async {
    await imageInpaintingService.repairTranslation(
      requestKey: request.cacheKey,
      sourcePath: request.imagePath,
      translation: imageTranslationService.resultFor(request.cacheKey),
      mode: imageTranslationSetting.imageProcessingDisplayMode.value,
    );
  }

}

class _ResolvedSources {
  const _ResolvedSources({
    required this.mode,
    required this.images,
    required this.requests,
  });

  factory _ResolvedSources.empty(ReadMode mode, int count) {
    return _ResolvedSources(
      mode: mode,
      images: List<GalleryImage?>.filled(count, null),
      requests: <int, ImageTranslationRequest>{},
    );
  }

  final ReadMode mode;
  final List<GalleryImage?> images;
  final Map<int, ImageTranslationRequest> requests;
}
