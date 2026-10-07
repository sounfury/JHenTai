import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/extension/get_logic_extension.dart';
import 'package:jhentai/src/model/gallery_image_page_url.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/search_history.dart';
import 'package:jhentai/src/pages/base/base_page_logic.dart';
import 'package:jhentai/src/pages/search/mixin/search_page_state_mixin.dart';
import 'package:jhentai/src/service/search_history_service.dart';
import 'package:jhentai/src/utils/check_util.dart';
import 'package:jhentai/src/utils/string_uril.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:throttling/throttling.dart';

import '../../../exception/eh_site_exception.dart';
import '../../../model/eh_raw_tag.dart';
import '../../../model/gallery.dart';
import '../../../model/gallery_page.dart';
import '../../../model/search_config.dart';
import '../../../network/eh_request.dart';
import '../../../service/local_config_service.dart';
import '../../../service/quick_search_service.dart';
import '../../../service/tag_translation_service.dart';
import '../../../utils/eh_spider_parser.dart';
import '../../../service/log.dart';
import '../../../utils/snack_util.dart';
import '../../../utils/translated_gallery_filter.dart';
import '../../../widget/eh_alert_dialog.dart';
import '../../../widget/loading_state_indicator.dart';

mixin SearchPageLogicMixin on BasePageLogic {
  @override
  SearchPageStateMixin get state;

  @override
  bool get autoLoadForFirstTime => false;

  @override
  bool get useSearchConfig => true;

  @override
  String get searchConfigKey => searchPageConfigKey;
  static const searchPageConfigKey = 'search';

  final String suggestionBodyId = 'suggestionBodyId';
  final String galleryBodyId = 'galleryBodyId';
  final String searchFieldId = 'searchFieldId';

  final Debouncing suggestDebouncing = Debouncing(duration: const Duration(milliseconds: 300));
  final Debouncing recordDebouncing = Debouncing(duration: const Duration(milliseconds: 1000));

  @override
  Future<void> onInit() async {
    await super.onInit();

    String? configString = await localConfigService.read(configKey: ConfigEnum.enableSearchHistoryTranslation);
    if (configString != null) {
      state.enableSearchHistoryTranslation = configString == 'true';
    }
    state.enableSearchHistoryTranslationCompleter.complete();
  }

  @override
  void onClose() {
    state.searchFieldFocusNode.dispose();
    suggestDebouncing.close();
    recordDebouncing.close();
  }

  @override
  Future<void> handleClearAndRefresh() async {
    state.searchFieldFocusNode.unfocus();

    state.hasSearched = true;

    if (state.bodyType == SearchPageBodyType.suggestionAndHistory) {
      toggleBodyType();
    }
    state.redirectUrl = null;

    writeHistory();

    /// reset scroll offset
    state.pageStorageKey = PageStorageKey('$runtimeType::${Random().nextInt(9999999)}');

    return super.handleClearAndRefresh();
  }

  Future<void> handleFileSearch() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowCompression: false,
        compressionQuality: 0,
      );
    } on Exception catch (e) {
      log.error('Pick file failed', e);
      return;
    }

    if (result == null) {
      return;
    }

    log.info('File search');

    state.hasSearched = true;

    if (state.bodyType == SearchPageBodyType.suggestionAndHistory) {
      toggleBodyType();
    }

    state.galleries.clear();
    state.prevGid = null;
    state.nextGid = null;
    state.totalCount = null;
    state.favoriteSortOrder = null;

    state.loadingState = LoadingState.loading;
    await state.searchConfigInitCompleter.future;
    state.searchConfig.keyword = null;
    updateSafely();

    try {
      state.redirectUrl = await ehRequest.requestLookup(
        imagePath: result.files.first.path!,
        imageName: result.files.first.name,
        parser: EHSpiderParser.imageLookup2RedirectUrl,
      );
    } on DioException catch (e) {
      log.error('fileSearchFailed'.tr, e.errorMsg);
      snack('fileSearchFailed'.tr, e.errorMsg ?? '');
      state.hasSearched = false;
      state.loadingState = LoadingState.idle;
      updateSafely();
      return;
    } on EHSiteException catch (e) {
      log.error('fileSearchFailed'.tr, e.message);
      snack('fileSearchFailed'.tr, e.message);
      state.hasSearched = false;
      state.loadingState = LoadingState.idle;
      updateSafely();
      return;
    } on CheckException catch (_) {
      state.hasSearched = false;
      state.loadingState = LoadingState.idle;
      updateSafely();
      rethrow;
    }

    log.info('Get redirect url success:${state.redirectUrl}');
    loadMore(checkLoadingState: false);
  }

  Future<void> onInputChanged(String text) async {
    await state.searchConfigInitCompleter.future;
    state.searchConfig.keyword = text;

    GalleryUrl? galleryUrl = GalleryUrl.tryParse(text);
    if (galleryUrl != null) {
      state.inputGalleryUrl = galleryUrl;
      state.inputGalleryImagePageUrl = null;
      updateSafely([suggestionBodyId]);
      return;
    }

    GalleryImagePageUrl? galleryImagePageUrl = GalleryImagePageUrl.tryParse(text);
    if (galleryImagePageUrl != null) {
      state.inputGalleryUrl = null;
      state.inputGalleryImagePageUrl = galleryImagePageUrl;
      updateSafely([suggestionBodyId]);
      return;
    }

    state.inputGalleryUrl = null;
    state.inputGalleryImagePageUrl = null;
    waitAndSearchTags();
  }

  /// search only if there's no timer active (300ms)
  Future<void> waitAndSearchTags() async {
    if (state.searchConfig.keyword?.trim().isEmpty ?? true) {
      return;
    }

    /// only search after 300ms
    suggestDebouncing.debounce(searchTags);
  }

  Future<void> searchTags() async {
    String keyword = state.searchConfig.keyword!;
    if (keyword.isEmpty) {
      return;
    }

    log.info('search for ${state.searchConfig.keyword}');

    /// chinese => database; other => EH api
    if (tagTranslationService.isReady) {
      state.suggestions = await tagTranslationService.searchTags(keyword, limit: 100);
    } else {
      String lastPart = keyword.split(' ').last;
      String effectivePart = lastPart;
      String? operator;
      if (lastPart.startsWith('-') || lastPart.startsWith('~')) {
        operator = lastPart[0];
        effectivePart = lastPart.substring(1);
      }
      try {
        if (effectivePart.isEmpty) {
          state.suggestions = [];
        } else {
          List<EHRawTag> tags = await ehRequest.requestTagSuggestion(effectivePart, EHSpiderParser.tagSuggestion2TagList);
          state.suggestions = tags
              .map((t) => (
                    searchText: keyword,
                    matchStart: keyword.length - lastPart.length,
                    matchEnd: keyword.length,
                    tagData: TagData(namespace: t.namespace, key: t.key),
                    operator: operator,
                    score: 0.0,
                    namespaceMatch: t.namespace.contains(effectivePart)
                        ? (start: t.namespace.indexOf(effectivePart), end: t.namespace.indexOf(effectivePart) + effectivePart.length)
                        : null,
                    translatedNamespaceMatch: null,
                    keyMatch: t.key.contains(effectivePart)
                        ? (start: t.key.indexOf(effectivePart), end: t.key.indexOf(effectivePart) + effectivePart.length)
                        : null,
                    tagNameMatch: null,
                  ))
              .toList();
        }
      } on DioException catch (e) {
        log.error('Request tag suggestion failed', e);
        state.suggestions = [];
      }
    }

    if (state.bodyType == SearchPageBodyType.suggestionAndHistory) {
      updateSafely([suggestionBodyId]);
    }

    if (state.suggestions.isNotEmpty && !state.hideSearchHistory) {
      state.hideSearchHistory = true;
      updateSafely([suggestionBodyId]);
    }
  }

  @override
  Future<void> jumpPage(DateTime dateTime) async {
    if (state.bodyType == SearchPageBodyType.suggestionAndHistory) {
      toggleBodyType();
    }
    state.hasSearched = true;
    super.jumpPage(dateTime);
  }

  @override
  Future<GalleryPageInfo> getGalleryPage({String? prevGid, String? nextGid, DateTime? seek, bool useCacheIfAvailable = true}) {
    if (state.redirectUrl == null && state.hideTranslatedGalleries && state.searchConfig.searchType == SearchType.gallery) {
      return _getUntranslatedGalleryPage(prevGid: prevGid, nextGid: nextGid, seek: seek, useCacheIfAvailable: useCacheIfAvailable);
    }

    if (state.redirectUrl == null) {
      return super.getGalleryPage(prevGid: prevGid, nextGid: nextGid, seek: seek, useCacheIfAvailable: useCacheIfAvailable);
    }

    log.info('Get galleries data with file search, prevGid:$prevGid, nextGid:$nextGid');
    return ehRequest.requestGalleryPage(
      prevGid: prevGid,
      nextGid: nextGid,
      seek: seek,
      url: state.redirectUrl,
      useCacheIfAvailable: useCacheIfAvailable,
      parser: EHSpiderParser.galleryPage2GalleryPageInfo,
    );
  }

  Future<void> toggleHideTranslatedGalleries() async {
    await state.searchConfigInitCompleter.future;

    state.hideTranslatedGalleries = !state.hideTranslatedGalleries;
    toast((state.hideTranslatedGalleries ? 'hideTranslatedGalleriesOn' : 'hideTranslatedGalleriesOff').tr);

    if (state.hasSearched) {
      handleClearAndRefresh();
    } else {
      updateSafely();
    }
  }

  Future<GalleryPageInfo> _getUntranslatedGalleryPage({String? prevGid, String? nextGid, DateTime? seek, required bool useCacheIfAvailable}) async {
    await state.searchConfigInitCompleter.future;

    Set<String> translatedTitleKeys = await _loadTranslatedTitleKeys(
      state.searchConfig,
      forceReload: !useCacheIfAvailable && prevGid == null && nextGid == null,
    );
    SearchConfig searchConfig = untranslatedSearchConfig(state.searchConfig);

    Future<GalleryPageInfo> request({String? prevGid, String? nextGid, DateTime? seek}) => ehRequest.requestGalleryPage(
          prevGid: prevGid,
          nextGid: nextGid,
          seek: seek,
          searchConfig: searchConfig,
          useCacheIfAvailable: useCacheIfAvailable,
          parser: EHSpiderParser.galleryPage2GalleryPageInfo,
        );

    bool backward = prevGid != null;
    GalleryPageInfo firstPage = await request(prevGid: prevGid, nextGid: nextGid, seek: seek);
    GalleryPageInfo lastPage = firstPage;
    List<Gallery> galleries = filterUntranslatedGalleries(firstPage.galleries, translatedTitleKeys);

    /// a page filtered to empty never builds its last card, which is what triggers loading more, so skip ahead
    for (int i = 0; galleries.isEmpty && i < 10; i++) {
      String? cursor = backward ? lastPage.prevGid : lastPage.nextGid;
      if (cursor == null) {
        break;
      }
      lastPage = backward ? await request(prevGid: cursor) : await request(nextGid: cursor);
      galleries = filterUntranslatedGalleries(lastPage.galleries, translatedTitleKeys);
    }

    return GalleryPageInfo(
      galleries: galleries,
      totalCount: lastPage.totalCount,
      favoriteSortOrder: lastPage.favoriteSortOrder,
      prevGid: backward ? lastPage.prevGid : firstPage.prevGid,
      nextGid: backward ? firstPage.nextGid : lastPage.nextGid,
    );
  }

  /// collect the titles of every Chinese gallery of the current search (up to 20 pages)
  Future<Set<String>> _loadTranslatedTitleKeys(SearchConfig searchConfig, {required bool forceReload}) async {
    SearchConfig chineseConfig = chineseTranslationSearchConfig(searchConfig);
    String query = chineseConfig.toQueryParameters().toString();
    if (!forceReload && state.translatedTitleKeysQuery == query) {
      return state.translatedTitleKeys;
    }

    Set<String> keys = {};
    String? nextGid;
    int pageCount = 0;
    do {
      GalleryPageInfo page = await ehRequest.requestGalleryPage(
        nextGid: nextGid,
        searchConfig: chineseConfig,
        useCacheIfAvailable: !forceReload,
        parser: EHSpiderParser.galleryPage2GalleryPageInfo,
      );
      for (Gallery gallery in page.galleries) {
        keys.addAll(galleryTitleMatchKeys(gallery.title));
      }
      nextGid = page.nextGid;
      pageCount++;
    } while (nextGid != null && pageCount < 20);

    log.info('Loaded ${keys.length} translated title keys from $pageCount pages${nextGid == null ? '' : ' (truncated)'} for $query');

    state.translatedTitleKeys = keys;
    state.translatedTitleKeysQuery = query;
    return keys;
  }

  @override
  void handleTapGalleryCard(Gallery gallery) async {
    state.searchFieldFocusNode.unfocus();
    super.handleTapGalleryCard(gallery);
  }

  Future<void> handleTapClearButton() async {
    await state.searchConfigInitCompleter.future;

    if (isEmptyOrNull(state.searchConfig.keyword)) {
      state.searchConfig.tags?.clear();
    } else {
      state.searchConfig.keyword = '';
    }
    update([searchFieldId]);
  }

  void toggleDeleteSearchHistoryMode() {
    state.inDeleteSearchHistoryMode = !state.inDeleteSearchHistoryMode;
    update([suggestionBodyId]);

    if (state.inDeleteSearchHistoryMode) {
      toast('tapChip2Delete'.tr);
    }
  }

  Future<void> handleClearAllSearchHistories() async {
    bool? result = await Get.dialog(EHDialog(title: 'deleteAll'.tr + '?'));

    if (result == true) {
      await searchHistoryService.clearHistory();
      update([suggestionBodyId]);
    }
  }

  Future<void> handleDeleteSearchHistory(SearchHistory history) async {
    await searchHistoryService.deleteHistory(history);

    /// exit delete mode if there's no history
    if (searchHistoryService.histories.isEmpty) {
      state.inDeleteSearchHistoryMode = false;
    }
    update([suggestionBodyId]);
  }

  void writeHistory() {
    /// do not record file search
    if (state.redirectUrl != null) {
      return;
    }

    String searchPhrase = state.searchConfig.computeFullKeywords();
    if (searchPhrase.isEmpty) {
      return;
    }

    searchHistoryService.writeHistory(searchPhrase);
  }

  void toggleBodyType() {
    state.bodyType = (state.bodyType == SearchPageBodyType.galleries ? SearchPageBodyType.suggestionAndHistory : SearchPageBodyType.galleries);
    update();
  }

  void toggleHideSearchHistory() {
    state.hideSearchHistory = !state.hideSearchHistory;
    update([suggestionBodyId]);
  }

  Future<void> toggleEnableSearchHistoryTranslation() async {
    await state.enableSearchHistoryTranslationCompleter.future;
    
    state.enableSearchHistoryTranslation = !state.enableSearchHistoryTranslation;
    await localConfigService.write(configKey: ConfigEnum.enableSearchHistoryTranslation, value: state.enableSearchHistoryTranslation.toString());
    update([suggestionBodyId]);
  }
}
