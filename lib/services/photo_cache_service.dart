import 'dart:collection';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class PhotoCacheService {
  static final PhotoCacheService _instance = PhotoCacheService._internal();
  factory PhotoCacheService() => _instance;
  PhotoCacheService._internal();

  // Memory cache (LRU)
  final LinkedHashMap<String, PhotoCacheEntry> _memoryCache = LinkedHashMap();
  static const int _maxMemoryCacheSize = 100;

  // Disk cache key prefix
  static const String _diskCachePrefix = 'photo_url_';
  static const Duration _cacheExpiration = Duration(hours: 12);

  // Get photo URL (checks memory → disk → null)
  Future<String?> getPhotoUrl(String photoReference) async {
    // Check memory cache
    if (_memoryCache.containsKey(photoReference)) {
      final entry = _memoryCache[photoReference]!;
      if (!entry.isExpired) {
        _moveToEnd(photoReference);
        return entry.url;
      } else {
        _memoryCache.remove(photoReference);
      }
    }

    // Check disk cache
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('$_diskCachePrefix$photoReference');
    if (cached != null) {
      try {
        final json = jsonDecode(cached);
        final entry = PhotoCacheEntry.fromJson(json);
        if (!entry.isExpired) {
          // Promote to memory cache
          _addToMemoryCache(photoReference, entry);
          return entry.url;
        } else {
          // Remove expired entry
          await prefs.remove('$_diskCachePrefix$photoReference');
        }
      } catch (e) {
        print('Error reading photo cache: $e');
      }
    }

    return null;
  }

  // Cache a photo URL
  Future<void> cachePhotoUrl(String photoReference, String url) async {
    final entry = PhotoCacheEntry(url: url, cachedAt: DateTime.now());

    // Add to memory
    _addToMemoryCache(photoReference, entry);

    // Add to disk
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_diskCachePrefix$photoReference',
      jsonEncode(entry.toJson()),
    );
  }

  void _addToMemoryCache(String key, PhotoCacheEntry entry) {
    if (_memoryCache.length >= _maxMemoryCacheSize) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[key] = entry;
  }

  void _moveToEnd(String key) {
    final value = _memoryCache.remove(key);
    if (value != null) {
      _memoryCache[key] = value;
    }
  }

  // Clear expired entries from disk
  Future<void> cleanupExpiredCache() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs
        .getKeys()
        .where((k) => k.startsWith(_diskCachePrefix))
        .toList();

    for (final key in keys) {
      final cached = prefs.getString(key);
      if (cached != null) {
        try {
          final entry = PhotoCacheEntry.fromJson(jsonDecode(cached));
          if (entry.isExpired) {
            await prefs.remove(key);
          }
        } catch (e) {
          // Remove corrupted entries
          await prefs.remove(key);
        }
      }
    }
  }
}

class PhotoCacheEntry {
  final String url;
  final DateTime cachedAt;

  PhotoCacheEntry({required this.url, required this.cachedAt});

  bool get isExpired {
    return DateTime.now().difference(cachedAt) >
        PhotoCacheService._cacheExpiration;
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'cachedAt': cachedAt.toIso8601String(),
      };

  factory PhotoCacheEntry.fromJson(Map<String, dynamic> json) {
    return PhotoCacheEntry(
      url: json['url'],
      cachedAt: DateTime.parse(json['cachedAt']),
    );
  }
}
