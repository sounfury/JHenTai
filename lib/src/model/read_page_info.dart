import 'gallery_image.dart';

enum ReadMode { downloaded, online, archive, local }

class ReadPageInfo {
  ReadMode mode;

  /// null for local gallery
  int? gid;

  /// null for local gallery
  String? token;

  String galleryTitle;

  String? galleryUrl;

  /// The trusted LAN device that supplied this remote gallery, when applicable.
  String? sourceDeviceId;

  int initialIndex;

  int currentImageIndex;

  int pageCount;

  /// used for archive
  bool isOriginal;

  String readProgressRecordStorageKey;

  /// used for archive&local
  List<GalleryImage>? images;

  /// used for initialize
  bool useSuperResolution;

  /// Optional EH language label/key when known at navigation time
  /// (e.g. `chinese` / `Chinese`). Used to skip same-language auto/pre-translate.
  String? galleryLanguage;

  /// Optional CSV of `namespace:key` tags when known; `language:` entries help
  /// detect already-translated galleries.
  String? galleryTags;

  ReadPageInfo({
    required this.mode,
    this.gid,
    this.token,
    required this.galleryTitle,
    this.galleryUrl,
    this.sourceDeviceId,
    required this.initialIndex,
    required this.pageCount,
    this.isOriginal = false,
    required this.readProgressRecordStorageKey,
    this.images,
    required this.useSuperResolution,
    this.galleryLanguage,
    this.galleryTags,
  }) : currentImageIndex = initialIndex;
}
