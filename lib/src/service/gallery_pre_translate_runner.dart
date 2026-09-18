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

class GalleryPreTranslateRunner extends GetxController
    with JHLifeCircleBeanErrorCatch, GalleryImagesRetainer
    implements JHLifeCircleBean {
  int? _activeGid;
  int _jobEpoch = 0;
  final Set<int> _finishedGids = <int>{};

  /// Gid currently owned by an in-flight detail-page pre-translate job.
  int? get activeGid => _activeGid;

  bool isRunningFor(int gid) =>
      _activeGid == gid && imageTranslationService.isBatchTranslating;

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
    if (previous != null) {
      cancelForGallery(previous);
    }
    cancelForGallery(gid);
    _finishedGids.remove(gid);
    final int epoch = ++_jobEpoch;
    _activeGid = gid;
    unawaited(
      _runJob(
        epoch: epoch,
        galleryUrl: galleryUrl,
        pageCount: pageCount,
        seedThumbnails: seedThumbnails,
      ),
    );
  }

  /// Cancels an in-flight job for [gid] if this runner owns it.
  void cancelForGallery(int gid) {
    _finishedGids.remove(gid);
    if (_activeGid != gid) {
      return;
    }
    _jobEpoch++;
    imageTranslationService.cancelBatch();
    _activeGid = null;
    releaseGalleryImages(gid);
  }

  Future<void> _runJob({
    required int epoch,
    required GalleryUrl galleryUrl,
    required int pageCount,
    List<GalleryThumbnail>? seedThumbnails,
  }) async {
    final int gid = galleryUrl.gid;
    final int n = imageTranslationSetting.preTranslatePageCount.value
        .clamp(1, pageCount);
    final int generation = imageTranslationService.beginBatch(n);
    bool completedCleanly = false;
    try {
      final _ResolvedSources sources = await _resolveSources(
        galleryUrl: galleryUrl,
        pageCount: pageCount,
        count: n,
        seedThumbnails: seedThumbnails,
        epoch: epoch,
      );
      if (!_isCurrent(epoch, gid)) {
        return;
      }
      for (int i = 0; i < n; i++) {
        if (!_isCurrent(epoch, gid) ||
            imageTranslationService.isCancelRequested) {
          _cancelRemaining(sources.requests, i, generation);
          return;
        }
        await _translateOne(
          index: i,
          image: sources.images[i],
          mode: sources.mode,
          generation: generation,
          requests: sources.requests,
        );
      }
      completedCleanly =
          _isCurrent(epoch, gid) &&
          !imageTranslationService.isCancelRequested;
    } catch (e, stack) {
      log.warning('Gallery pre-translate failed for gid=$gid: $e');
      log.trace(stack);
    } finally {
      imageTranslationService.endBatch(generation);
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

  void _cancelRemaining(
    Map<int, ImageTranslationRequest> requests,
    int from,
    int generation,
  ) {
    if (!imageTranslationService.isCurrentBatch(generation)) {
      return;
    }
    for (int i = from; i < imageTranslationService.batchTotal; i++) {
      final String cacheKey =
          requests[i]?.cacheKey ?? 'pretranslate-page:$i';
      imageTranslationService.markCanceled(cacheKey);
      imageTranslationService.recordBatchResult(
        cacheKey,
        generation: generation,
      );
    }
  }

  Future<_ResolvedSources> _resolveSources({
    required GalleryUrl galleryUrl,
    required int pageCount,
    required int count,
    required List<GalleryThumbnail>? seedThumbnails,
    required int epoch,
  }) async {
    final int gid = galleryUrl.gid;
    final GalleryDownloadInfo? downloadInfo =
        galleryDownloadService.galleryDownloadInfos[gid];
    if (downloadInfo?.downloadProgress != null) {
      await retainGalleryImages(gid);
      if (!_isCurrent(epoch, gid)) {
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
      final List<GalleryImage> images =
          await archiveDownloadService.getUnpackedImages(gid);
      if (!_isCurrent(epoch, gid)) {
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
    final List<GalleryThumbnail?> thumbnails =
        List<GalleryThumbnail?>.filled(pageCount, null);
    if (seedThumbnails != null) {
      for (int i = 0; i < seedThumbnails.length && i < pageCount; i++) {
        thumbnails[i] = seedThumbnails[i];
      }
    }
    int thumbnailsCountPerPage = SiteSetting.thumbnailsCountPerPage.value;
    for (int index = 0; index < count; index++) {
      if (!_isCurrent(epoch, gid)) {
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
        log.warning(
          'Pre-translate thumbnail fetch failed at index $index: $e',
        );
        log.trace(stack);
      }
    }

    final List<GalleryImage?> images =
        List<GalleryImage?>.filled(count, null);
    for (int index = 0; index < count; index++) {
      if (!_isCurrent(epoch, gid)) {
        break;
      }
      final GalleryThumbnail? thumb = thumbnails[index];
      if (thumb == null) {
        continue;
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
    }

    return _ResolvedSources(
      mode: ReadMode.online,
      images: images,
      requests: <int, ImageTranslationRequest>{},
    );
  }

  Future<void> _translateOne({
    required int index,
    required GalleryImage? image,
    required ReadMode mode,
    required int generation,
    required Map<int, ImageTranslationRequest> requests,
  }) async {
    final String fallbackKey = 'pretranslate-page:$index';
    if (image == null) {
      imageTranslationService.markDownloadError(
        fallbackKey,
        'IMAGE_SOURCE_UNAVAILABLE',
      );
      imageTranslationService.recordBatchResult(
        fallbackKey,
        generation: generation,
      );
      return;
    }

    final ImageTranslationRequest? request = await _buildRequest(
      index: index,
      image: image,
      mode: mode,
    );
    if (request == null) {
      imageTranslationService.markDownloadError(
        fallbackKey,
        'IMAGE_SOURCE_UNAVAILABLE',
      );
      imageTranslationService.recordBatchResult(
        fallbackKey,
        generation: generation,
      );
      return;
    }
    requests[index] = request;
    imageTranslationService.queue(request.cacheKey);

    try {
      final RecognizedImage? recognized =
          await imageTranslationService.recognizeImage(request);
      if (recognized != null) {
        await imageTranslationService.translateRecognizedText(
          request,
          recognized,
        );
      }
      await _maybeRepair(request);
    } catch (e, stack) {
      log.warning('Pre-translate page $index failed: $e');
      log.trace(stack);
      final ImageTranslationResult result =
          imageTranslationService.resultFor(request.cacheKey);
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
  }

  Future<ImageTranslationRequest?> _buildRequest({
    required int index,
    required GalleryImage image,
    required ReadMode mode,
  }) async {
    if (mode == ReadMode.online) {
      final String url = effectiveEHImageUrl(image.url);
      final String cacheKey = normalizedImageCacheKey(url);
      final String taskKey = 'online:$cacheKey';
      imageTranslationService.markDownloading(taskKey);
      try {
        final File? file = await _ensureOnlineImageFile(url, cacheKey)
            .timeout(const Duration(seconds: 30));
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
      imageTranslationService.markDownloadError(
        taskKey,
        'IMAGE_DOWNLOAD_TIMEOUT',
      );
      return ImageTranslationRequest(cacheKey: taskKey, sourceUrl: url);
    }
    if (mode == ReadMode.downloaded && image.path != null) {
      return ImageTranslationRequest(
        cacheKey: 'downloaded:${image.path}',
        imagePath:
            DownloadPathResolver
                .computeImageDownloadAbsolutePathFromRelativePath(image.path!),
      );
    }
    if (mode == ReadMode.archive && image.path != null) {
      return ImageTranslationRequest(
        cacheKey: 'archive:${image.path}',
        imagePath: p.join(pathService.getVisibleDir().path, image.path!),
      );
    }
    return null;
  }

  Future<File?> _ensureOnlineImageFile(String url, String cacheKey) async {
    final String directoryPath = await getExtendedImageDiskCacheDirectory();
    final File? compatible = await findCompatibleImageCacheFile(
      directory: directoryPath,
      url: url,
    );
    if (compatible != null && await compatible.exists()) {
      return compatible;
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
    final ImageProcessingDisplayMode mode =
        imageTranslationSetting.imageProcessingDisplayMode.value;
    if (mode == ImageProcessingDisplayMode.overlay) {
      return;
    }
    final String? sourcePath = request.imagePath;
    if (sourcePath == null) {
      return;
    }
    if (imageTranslationService.resultFor(request.cacheKey).status !=
        ImageTranslationStatus.success) {
      return;
    }
    imageInpaintingService.setDisplayMode(mode);
    final ImageTranslationResult translation =
        imageTranslationService.resultFor(request.cacheKey);
    final List<RecognizedTextBlock> eraseBlocks =
        translatedBlocksEligibleForErase(translation);
    if (eraseBlocks.isEmpty) {
      return;
    }
    await imageInpaintingService.detectAndRepair(
      requestKey: request.cacheKey,
      sourcePath: sourcePath,
      eraseOnlyBlocks: eraseBlocks,
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
