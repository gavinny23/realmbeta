import 'dart:io';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Resolves a media URL to a local, disk-cached [File] using the same
/// cache manager `cached_network_image` uses under the hood — so a
/// video that's already been watched once plays back instantly (and
/// works with no connection) instead of re-downloading the whole file
/// every time its screen is opened.
///
/// Falls back to `null` if the file isn't cached yet and can't be
/// fetched right now (e.g. genuinely offline on first view) — callers
/// should fall back to streaming the network URL directly in that case.
class CachedMedia {
  CachedMedia._();

  static Future<File?> resolve(String url) async {
    try {
      final fileInfo = await DefaultCacheManager().getSingleFile(url);
      return fileInfo;
    } catch (_) {
      return null;
    }
  }

  /// Non-blocking check for whether [url] is already sitting in the
  /// disk cache, without triggering a download if it isn't.
  static Future<File?> getIfCached(String url) async {
    try {
      final info = await DefaultCacheManager().getFileFromCache(url);
      return info?.file;
    } catch (_) {
      return null;
    }
  }
}
