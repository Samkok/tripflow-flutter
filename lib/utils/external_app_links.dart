import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyza/models/location_model.dart';

/// Helpers for opening saved locations in external apps (Google Maps, Grab)
/// using their canonical Google place_id and original name when available,
/// so that handoff resolves to the *exact* place even after the user
/// renames it in-app.
///
/// Locations added before place_id was captured silently fall back to
/// coordinate-only handoff, matching the pre-rollout behavior — no caller
/// needs to branch on whether the field is populated.

/// Opens a single location in Google Maps. Prefers a search anchored to
/// `place_id` (which resolves to the exact place; bypasses fuzzy name
/// search) and includes the location's original Google name in the query
/// so the search box reads correctly when Google Maps opens.
Future<void> openLocationInGoogleMaps(LocationModel location) async {
  final placeId = location.placeId;
  final label = location.externalHandoffName;
  final lat = location.coordinates.latitude;
  final lng = location.coordinates.longitude;

  // Universal Maps URL — works on web, iOS Maps app handoff, and Android.
  // `query_place_id` is honored only when paired with a non-empty `query`,
  // which is why we always set both.
  final params = <String, String>{
    'api': '1',
    'query': label.isNotEmpty ? label : '$lat,$lng',
    if (placeId != null && placeId.isNotEmpty) 'query_place_id': placeId,
  };
  final url = Uri.https('www.google.com', '/maps/search/', params);

  await _launchOrFallback(
    url,
    fallbackCoords: LatLng(lat, lng),
  );
}

/// Opens turn-by-turn directions in Google Maps from [origin] to
/// [destination], with optional intermediate stops as waypoints. Anchors
/// each stop to its place_id when available; falls back to lat/lng for
/// stops without one.
Future<void> openDirectionsInGoogleMaps({
  required LocationModel origin,
  required LocationModel destination,
  List<LocationModel> waypoints = const [],
}) async {
  final params = <String, String>{
    'api': '1',
    'origin': _coordsParam(origin),
    'destination': _coordsParam(destination),
    'travelmode': 'driving',
    if (origin.placeId != null && origin.placeId!.isNotEmpty)
      'origin_place_id': origin.placeId!,
    if (destination.placeId != null && destination.placeId!.isNotEmpty)
      'destination_place_id': destination.placeId!,
  };

  if (waypoints.isNotEmpty) {
    params['waypoints'] = waypoints.map(_coordsParam).join('|');
    final waypointPlaceIds = waypoints.map((w) => w.placeId ?? '').toList();
    if (waypointPlaceIds.any((id) => id.isNotEmpty)) {
      // Google's spec requires same length as `waypoints` (empty entries
      // are allowed and fall back to the coord). We always emit the full
      // pipe-separated list for that reason.
      params['waypoint_place_ids'] = waypointPlaceIds.join('|');
    }
  }

  final url = Uri.https('www.google.com', '/maps/dir/', params);
  await _launchOrFallback(
    url,
    fallbackCoords: destination.coordinates,
  );
}

/// Books a Grab ride from [origin] to [destination]. Includes the
/// human-readable names as `pickUpKeyWords` / `dropOffKeyWords` so the
/// Grab booking screen displays the saved label instead of "Lat, Lng".
/// The actual pickup/dropoff pin is still anchored to the coordinates
/// (Grab's deep-link API doesn't accept place_id).
Future<void> openGrabRoute({
  required LocationModel origin,
  required LocationModel destination,
}) async {
  final params = <String, String>{
    'screenType': 'BOOKING',
    'pickUpLatitude': origin.coordinates.latitude.toString(),
    'pickUpLongitude': origin.coordinates.longitude.toString(),
    'dropOffLatitude': destination.coordinates.latitude.toString(),
    'dropOffLongitude': destination.coordinates.longitude.toString(),
    if (origin.externalHandoffName.isNotEmpty)
      'pickUpKeyWords': origin.externalHandoffName,
    if (destination.externalHandoffName.isNotEmpty)
      'dropOffKeyWords': destination.externalHandoffName,
  };
  final deepLink = Uri(
    scheme: 'grab',
    host: 'open',
    queryParameters: params,
  );

  try {
    if (await canLaunchUrl(deepLink)) {
      await launchUrl(deepLink, mode: LaunchMode.externalApplication);
      return;
    }
  } catch (e) {
    debugPrint('Grab deep link failed: $e');
  }

  try {
    await launchUrl(deepLink, mode: LaunchMode.externalApplication);
    return;
  } catch (e) {
    debugPrint('Grab direct launch failed: $e');
  }

  // Final fallback: install/open Grab from the web.
  final webUrl = Uri.parse('https://grab.onelink.me/2695613898');
  try {
    await launchUrl(webUrl, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('Could not launch Grab: $e');
  }
}

String _coordsParam(LocationModel l) =>
    '${l.coordinates.latitude},${l.coordinates.longitude}';

/// Tries the universal `https://www.google.com/maps/...` URL first, then
/// falls back to a `geo:` scheme anchored to [fallbackCoords] for devices
/// where the Maps URL can't resolve.
Future<void> _launchOrFallback(
  Uri url, {
  required LatLng fallbackCoords,
}) async {
  try {
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return;
    }
  } catch (e) {
    debugPrint('External map launch failed: $e');
  }

  final geoUrl =
      Uri.parse('geo:${fallbackCoords.latitude},${fallbackCoords.longitude}');
  try {
    await launchUrl(geoUrl, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('Geo fallback failed: $e');
  }
}
