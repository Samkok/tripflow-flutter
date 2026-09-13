import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Disk cache for Google Places photos.
///
/// CachedNetworkImage's default cache keeps 200 files and trusts the CDN's
/// `max-age` (about a day). On a photo-heavy trip that meant thumbnails
/// were evicted constantly and every day on screen re-requested the photo
/// endpoint — each request billed as a Place Photo, and each one a chance
/// to discover that the stored photo reference had expired (blank tile).
///
/// This manager keeps a photo for [keepFor] from its last use — Google's
/// caching window — sizes the cap for trips with hundreds of photos, and
/// pins every download's validity to the same window, so a cached photo is
/// served from disk with no network at all until it ages out.
class PlacePhotoCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'voyzaPlacePhotos';
  static const keepFor = Duration(days: 30);

  static final PlacePhotoCacheManager _instance = PlacePhotoCacheManager._();
  factory PlacePhotoCacheManager() => _instance;

  PlacePhotoCacheManager._()
      : super(Config(
          key,
          stalePeriod: keepFor,
          maxNrOfCacheObjects: 1500,
          fileService: _PinnedValidityFileService(),
        ));
}

/// [HttpFileService] whose responses report a fixed validity instead of the
/// CDN's short `max-age`. Bytes, status and ETag pass through untouched.
class _PinnedValidityFileService extends HttpFileService {
  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    return _PinnedValidityResponse(await super.get(url, headers: headers));
  }
}

class _PinnedValidityResponse implements FileServiceResponse {
  _PinnedValidityResponse(this._inner)
      : validTill = DateTime.now().add(PlacePhotoCacheManager.keepFor);

  final FileServiceResponse _inner;

  @override
  final DateTime validTill;

  @override
  Stream<List<int>> get content => _inner.content;

  @override
  int? get contentLength => _inner.contentLength;

  @override
  int get statusCode => _inner.statusCode;

  @override
  String? get eTag => _inner.eTag;

  @override
  String get fileExtension => _inner.fileExtension;
}
