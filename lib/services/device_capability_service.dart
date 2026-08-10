import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

/// ar_flutter_plugin_2's Android library (it wraps Sceneview/ARCore)
/// declares minSdk 28 in its own manifest. The app's overall minSdk is
/// lowered below that via `tools:overrideLibrary` in AndroidManifest.xml
/// so the app still installs on older devices — but that override only
/// silences the *build-time* manifest merge check. It does nothing to
/// stop the plugin's native code from being called at runtime, which
/// would crash on a device that's actually below API 28.
///
/// This service is the runtime half of that story: it checks the real
/// OS version once at startup so the UI can hide/disable AR entirely on
/// devices that can't safely run it, instead of ever invoking the
/// plugin there.
class DeviceCapabilityService {
  DeviceCapabilityService._();
  static final DeviceCapabilityService instance = DeviceCapabilityService._();

  static const int _minArSdkInt = 28;

  bool _arSupported = true;
  bool get arSupported => _arSupported;

  Future<void> init() async {
    if (!Platform.isAndroid) {
      // iOS's ARKit requirement is enforced by the plugin's own iOS
      // deployment target at build time, so there's no separate runtime
      // check needed here.
      _arSupported = true;
      return;
    }
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      _arSupported = androidInfo.version.sdkInt >= _minArSdkInt;
    } catch (_) {
      // If the SDK level can't be determined, fail safe: hide AR rather
      // than risk invoking plugin code on an unsupported device.
      _arSupported = false;
    }
  }
}
