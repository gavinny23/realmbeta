import 'dart:convert';
import 'package:http/http.dart' as http;

/// Turns a lat/lng into a short, human-readable place label (e.g.
/// "Westlands, Nairobi") for display on top of a drop card. Uses the
/// same Nominatim reverse-geocoding API and User-Agent convention as
/// [LocationAutocompleteField]'s forward search, so no new backend or
/// API key is required.
///
/// Results are cached in memory (rounded to ~11m precision) since the
/// feed re-fetches drops on every location update, and reverse-geocoding
/// the same handful of nearby drops repeatedly would otherwise hammer
/// Nominatim's free tier and violate its 1 request/sec usage policy.
class GeocodingService {
  GeocodingService._();
  static final GeocodingService instance = GeocodingService._();

  final Map<String, String?> _cache = {};
  final Map<String, Future<String?>> _inFlight = {};

  String _keyFor(double lat, double lng) =>
      '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';

  /// Returns a short place label, or null if it can't be resolved
  /// (offline, rate-limited, or genuinely no address data).
  Future<String?> reverseGeocode(double lat, double lng) async {
    final key = _keyFor(lat, lng);
    if (_cache.containsKey(key)) return _cache[key];
    final pending = _inFlight[key];
    if (pending != null) return pending;

    final future = _fetch(lat, lng, key);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<String?> _fetch(double lat, double lng, String key) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=$lat&lon=$lng&format=json&zoom=16&addressdetails=1',
      );
      final response = await http.get(uri, headers: {
        'User-Agent': 'RealityMerge/1.0',
      }).timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) {
        _cache[key] = null;
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final address = json['address'] as Map<String, dynamic>? ?? {};

      final place = address['neighbourhood'] ??
          address['suburb'] ??
          address['quarter'] ??
          address['road'];
      final city = address['city'] ??
          address['town'] ??
          address['municipality'] ??
          address['village'];

      String? label;
      if (place != null && city != null && place != city) {
        label = '$place, $city';
      } else {
        label = (place ?? city) as String?;
      }
      label ??= (json['display_name'] as String?)?.split(',').first.trim();

      _cache[key] = label;
      return label;
    } catch (_) {
      // Offline, timed out, or rate-limited — caller falls back to
      // the distance label instead.
      _cache[key] = null;
      return null;
    }
  }
}
