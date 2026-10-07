import '../model/gallery_page.dart';
import '../model/search_config.dart';

typedef FavoritePageLoader =
    Future<GalleryPageInfo> Function({
      String? prevGid,
      String? nextGid,
      DateTime? seek,
      required SearchConfig searchConfig,
      required bool useCacheIfAvailable,
    });

/// Filters the site's all-favorites search while retaining its ordering/cursors.
/// Empty filtered pages are traversed until a match or the end is reached.
Future<GalleryPageInfo> searchFavoriteCategories({
  required SearchConfig searchConfig,
  required FavoritePageLoader loadPage,
  String? prevGid,
  String? nextGid,
  DateTime? seek,
  bool useCacheIfAvailable = true,
}) async {
  final config = searchConfig.copyWith();
  if (!config.aggregatesFavoriteCategories) {
    return loadPage(
      prevGid: prevGid,
      nextGid: nextGid,
      seek: seek,
      searchConfig: config,
      useCacheIfAvailable: useCacheIfAvailable,
    );
  }

  final selected = config.effectiveFavoriteCategoryIndices.toSet();
  config.selectFavoriteCategories([]);
  // A date jump starts a new forward search, even if it has both old cursors.
  final backwards = prevGid != null && nextGid == null && seek == null;
  final visited = <String>{};
  String? firstPrevGid;
  String? firstNextGid;
  bool firstPage = true;

  while (true) {
    final page = await loadPage(
      prevGid: prevGid,
      nextGid: nextGid,
      seek: seek,
      searchConfig: config,
      useCacheIfAvailable: useCacheIfAvailable,
    );
    if (firstPage) {
      firstPrevGid = page.prevGid;
      firstNextGid = page.nextGid;
      firstPage = false;
    }
    final seenGids = <int>{};
    final galleries =
        page.galleries
            .where(
              (gallery) =>
                  selected.contains(gallery.favoriteTagIndex) &&
                  seenGids.add(gallery.gid),
            )
            .toList();
    final cursor = backwards ? page.prevGid : page.nextGid;
    if (galleries.isNotEmpty || cursor == null) {
      return GalleryPageInfo(
        galleries: galleries,
        favoriteSortOrder: page.favoriteSortOrder,
        // The site's total includes unselected categories and is misleading.
        prevGid: backwards ? page.prevGid : firstPrevGid,
        nextGid: backwards ? firstNextGid : page.nextGid,
      );
    }
    if (!visited.add(cursor)) {
      throw StateError('Favorite search pagination repeated cursor: $cursor');
    }
    prevGid = backwards ? cursor : null;
    nextGid = backwards ? null : cursor;
    seek = null;
  }
}
