import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  /// Requests permission explicitly via permission_handler,
  /// then gets a fresh GPS fix. Never returns a stale location.
  Future<Position> getCurrentPosition() async {
    // Step 1 — check if location services are on
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception(
          'Location services are off. Enable them in device Settings.');
    }

    // Step 2 — request permission via permission_handler
    // (more reliable than geolocator's built-in request on some Android versions)
    var status = await Permission.locationWhenInUse.status;
    if (status.isDenied) {
      status = await Permission.locationWhenInUse.request();
    }
    if (status.isPermanentlyDenied) {
      await openAppSettings();
      throw Exception(
          'Location permission permanently denied. Enabled it in Settings.');
    }
    if (!status.isGranted) {
      throw Exception('Location permission denied.');
    }

    // Step 3 — get fresh fix with timeout fallback
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: Duration(seconds: 10),
      );
    } on TimeoutException {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );
    }
  }

  Stream<Position> watchPosition() {
    return Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
        intervalDuration: Duration(seconds: 3),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationText: 'Reality Merge is using your location',
          notificationTitle: 'Reality Merge',
          enableWakeLock: true,
        ),
      ),
    );
  }
}
