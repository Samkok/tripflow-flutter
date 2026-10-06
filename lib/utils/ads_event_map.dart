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
const String adsEventStartTrial = 'StartTrial';
const String adsEventSubscribe = 'Subscribe';
const String adsEventPurchase = 'fb_mobile_purchase';

/// Ours: the first sign that someone is really using the app.
const String adsEventTripCreated = 'TripCreated';

/// Ours: someone has had the app work out a route, the thing it is for.
/// Sent once per install.
const String adsEventRouteOptimized = 'RouteOptimized';

/// The advertising event for one of the app's own analytics events, or
/// null when that event is none of an ad platform's business.
///
/// The privacy policy lists exactly what advertising partners are told:
/// that someone signed up, created a trip, optimized a route for the first
/// time, started a trial or made a purchase (with product, price and
/// currency). This function is that list. Nothing about places, sharing or
/// onboarding goes through it, a route is reported only as having happened,
/// and no parameter carries anything a person typed.
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
    case 'trial_started':
      final product = params?['product'];
      return AdsEvent(
        adsEventStartTrial,
        parameters: {if (product is String) 'fb_content_id': product},
      );
    case 'purchase':
      final product = params?['product'];
      final value = params?['value'];
      final currency = params?['currency'];
      final oneOff = product is String && product.contains('lifetime');
      return AdsEvent(
        oneOff ? adsEventPurchase : adsEventSubscribe,
        parameters: {if (product is String) 'fb_content_id': product},
        value: value is num ? value.toDouble() : null,
        currency: currency is String ? currency : null,
      );
  }
  return null;
}
