/// What the operating system says about tracking permission.
enum TrackingStatus {
  /// No such permission here: Android, or a build without Apple's prompt.
  notSupported,

  /// Never asked. The only state in which the system prompt can appear.
  notDetermined,
  restricted,
  denied,
  authorized,
}

/// Apple's App Tracking Transparency question, behind an interface so the
/// rest of the app does not depend on the native code that asks it.
abstract class TrackingPermissionGateway {
  Future<TrackingStatus> status();

  /// Shows the system prompt (it appears only when [status] is
  /// [TrackingStatus.notDetermined]) and returns the answer.
  Future<TrackingStatus> request();
}

/// The gateway for builds that do not ask: there is nothing to ask about.
class NoTrackingPermission implements TrackingPermissionGateway {
  const NoTrackingPermission();

  @override
  Future<TrackingStatus> status() async => TrackingStatus.notSupported;

  @override
  Future<TrackingStatus> request() async => TrackingStatus.notSupported;
}

/// The gateway in use. Start-up replaces it with `AppleTrackingPermission`
/// (meta_ads_bridge.dart) in builds with ads measurement; otherwise the app
/// never asks.
TrackingPermissionGateway trackingPermission = const NoTrackingPermission();
