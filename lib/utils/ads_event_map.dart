/// One event as an advertising platform receives it.
class AdsEvent {
  const AdsEvent(
    this.name, {
    this.parameters = const {},
    this.value,
    this.currency,
    this.oncePerInstall = false,
  });

  /// The platform's event name.
  final String name;
  final Map<String, Object> parameters;

  /// Money amount, for purchases.
  final double? value;
  final String? currency;

  /// A milestone rather than a count: the platform hears of it the first
  /// time it happens on this install, and never again.
  final bool oncePerInstall;

  /// A one-off purchase (as opposed to a subscription or a trial).
  bool get isPurchase => name == adsEventPurchase;

  @override
  String toString() => 'AdsEvent($name, $parameters, $value $currency)';
}

// Meta's standard event names.
const String adsEventCompleteRegistration = 'fb_mobile_complete_registration';

/// Meta's purchase event. The app itself no longer sends it: trials and
/// purchases reach Meta from RevenueCat's servers (see [adsEventFor]). The
/// name stays so a sink knows a purchase when it sees one.
const String adsEventPurchase = 'fb_mobile_purchase';

/// Ours: the first sign that someone is really using the app.
const String adsEventTripCreated = 'TripCreated';

/// Ours: someone has had the app work out a route, the thing it is for.
/// Sent once per install.
const String adsEventRouteOptimized = 'RouteOptimized';

/// The advertising event for one of the app's own analytics events, or
/// null when that event is none of an ad platform's business.
///
/// The privacy policy lists exactly what advertising partners are told by
/// the app: that someone signed up, created a trip, or optimized a route
/// for the first time. This function is that list. Nothing about places,
/// sharing or onboarding goes through it, a route is reported only as
/// having happened, and no parameter carries anything a person typed.
///
/// Trials and purchases are deliberately NOT here. A trial that converts to
/// a paid plan does so on the store's servers days later, usually with the
/// app closed, so the app cannot report it; RevenueCat's server-side Meta
/// integration reports trial starts, conversions, purchases and renewals
/// instead, for people whose ads measurement is on (it only sends when the
/// customer carries the identifiers `MetaAdsSink` hands it). Sending them
/// from here as well would count every purchase twice.
AdsEvent? adsEventFor(String name, [Map<String, Object>? params]) {
  switch (name) {
    case 'signup':
      final method = params?['method'];
      return AdsEvent(
        adsEventCompleteRegistration,
        parameters: {
          if (method is String) 'fb_registration_method': method,
        },
      );
    case 'trip_created':
      return const AdsEvent(adsEventTripCreated);
    case 'route_optimized':
      // That it happened, once: not how many stops, not the time saved.
      return const AdsEvent(adsEventRouteOptimized, oncePerInstall: true);
  }
  // 'trial_started' and 'purchase' included: RevenueCat reports those.
  return null;
}
