import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The native side's small device channel: `MainActivity.kt` answers
/// `androidId`. iOS needs no bridge (device_info_plus has the vendor id).
const MethodChannel deviceChannel = MethodChannel('voyza/device');

/// The identifier the abuse checks record when a free trial starts and send
/// along with a referral redemption (privacy policy, section 2, "Free-trial
/// abuse prevention").
///
/// iOS: the identifier-for-vendor. Android: the Android ID
/// (`Settings.Secure.ANDROID_ID`), stable for this app's signing key on this
/// device and user until a factory reset — one value per device, which is
/// what a same-device check needs. Until 2026-10-06 the app sent
/// `Build.ID` here, the firmware build label, which every device on the
/// same build shares.
///
/// Null when the platform has nothing to offer (desktop, web, tests) or the
/// lookup fails; callers decide on a fallback.
Future<String?> abuseCheckDeviceId({
  bool? isAndroid,
  bool? isIOS,
  MethodChannel channel = deviceChannel,
}) async {
  try {
    if (isAndroid ?? Platform.isAndroid) {
      final id = await channel.invokeMethod<String>('androidId');
      return (id == null || id.isEmpty) ? null : id;
    }
    if (isIOS ?? Platform.isIOS) {
      final ios = await DeviceInfoPlugin().iosInfo;
      final id = ios.identifierForVendor;
      return (id == null || id.isEmpty) ? null : id;
    }
  } on MissingPluginException {
    return null;
  } catch (e) {
    debugPrint('abuseCheckDeviceId: $e');
  }
  return null;
}
