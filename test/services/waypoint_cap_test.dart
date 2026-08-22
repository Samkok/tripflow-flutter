import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/services/google_maps_service.dart';
import 'package:voyza/services/multi_modal_router.dart';

LocationModel _place(int i) => LocationModel(
      id: 'p$i',
      name: 'Place $i',
      address: '',
      coordinates: LatLng(25.0 + i * 0.01, 121.5),
      addedAt: DateTime(2026, 1, 1),
    );

void main() {
  test('constant matches the Routes API intermediates limit', () {
    expect(MultiModalRouter.maxRoutableStopsPerDay, 25);
  });

  test('getOptimizedRouteDetails refuses >25 intermediates with no network',
      () async {
    // 26 intermediates + a destination = over the Routes API cap. The
    // pre-flight must return an explicit error result instantly and
    // offline — if the guard were missing, this call would attempt a real
    // HTTP request (no dotenv/API key in the test environment, so it
    // would fail slowly and via a different path).
    final result = await GoogleMapsService.getOptimizedRouteDetails(
      origin: const LatLng(25.0, 121.5),
      destination: _place(99),
      waypoints: [for (var i = 0; i < 26; i++) _place(i)],
      optimizeWaypoints: true,
    ).timeout(const Duration(seconds: 2));

    expect(result['status'], 'error');
    expect(result['routePoints'], isEmpty);
    expect(result['legDetails'], isEmpty);
  });
}
