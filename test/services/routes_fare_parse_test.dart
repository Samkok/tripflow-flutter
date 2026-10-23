import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/transit_fare.dart';
import 'package:voyza/services/google_maps_service.dart';
import 'package:voyza/services/multi_modal_router.dart';

/// Replays a canned Routes API body through the REAL request builder and
/// parser, so the fare's whole path — field mask → travelAdvisory →
/// legDetails['fare'] → LegRoute.fare → label — is proven end to end
/// without the network.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.payload);
  final Map<String, dynamic> payload;
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// Google's documented sample polyline — any decodable geometry will do.
const _poly = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';

Map<String, dynamic> _walkStep() => {
      'travelMode': 'WALK',
      'staticDuration': '300s',
      'polyline': {'encodedPolyline': _poly},
    };

Map<String, dynamic> _rideStep(String line) => {
      'travelMode': 'TRANSIT',
      'staticDuration': '900s',
      'polyline': {'encodedPolyline': _poly},
      'transitDetails': {
        'stopDetails': {
          'arrivalStop': {'name': 'Mong Kok'},
          'departureStop': {'name': 'Sunny Bay'},
          'arrivalTime': '2026-10-19T03:40:00Z',
          'departureTime': '2026-10-19T03:20:00Z',
        },
        'headsign': 'Central',
        'stopCount': 6,
        'transitLine': {
          'name': line,
          'color': '#e2231a',
          'textColor': '#ffffff',
          'vehicle': {'type': 'SUBWAY'},
        },
      },
    };

/// One route as the API shapes it; [fare] is the raw `transitFare` Money
/// (an empty map is exactly what Google sends for an unpriced itinerary).
Map<String, dynamic> _route({
  required List<Map<String, dynamic>> steps,
  Object? fare,
}) =>
    {
      'legs': [
        {
          'distanceMeters': 24000,
          'duration': '3370s',
          'polyline': {'encodedPolyline': _poly},
          'steps': steps,
        }
      ],
      if (fare != null) 'travelAdvisory': {'transitFare': fare},
    };

const _hkd24_50 = {
  'currencyCode': 'HKD',
  'units': '24',
  'nanos': 500000000,
};

LocationModel _stop(LatLng at) => LocationModel(
      id: 'stop',
      name: 'Ladies Market',
      address: '',
      coordinates: at,
      addedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

void main() {
  setUpAll(() {
    dotenv.testLoad(fileInput: 'GOOGLE_DIRECTIONS_API_KEY=test-key');
  });

  _CannedAdapter install(Map<String, dynamic> payload) {
    final adapter = _CannedAdapter(payload);
    GoogleMapsService.dioForTesting.httpClientAdapter = adapter;
    return adapter;
  }

  test('a priced itinerary\'s fare reaches the leg details and the options',
      () async {
    final adapter = install({
      'routes': [
        // Google's top "transit" result is a pure walk: the parser must
        // skip it and take the fare of the route it actually keeps.
        _route(steps: [_walkStep()]),
        _route(
          steps: [_walkStep(), _rideStep('Tsuen Wan Line'), _walkStep()],
          fare: _hkd24_50,
        ),
        _route(steps: [_rideStep('A21')], fare: const <String, Object>{}),
      ],
    });

    final res = await GoogleMapsService.getOptimizedRouteDetails(
      origin: const LatLng(22.3130, 114.0413),
      destination: _stop(const LatLng(22.3176, 114.1709)),
      optimizeWaypoints: false,
      mode: 'transit',
      includeAlternatives: true,
    );

    expect(res['status'], 'ok');
    final legs = res['legDetails'] as List<Map<String, dynamic>>;
    expect(legs, hasLength(1));
    expect(legs.first['fare'], {'currency': 'HKD', 'amount': 24.5});
    expect(TransitFare.ofLeg(legs.first)!.label, r'HK$24.50');

    final options = res['alternativeRoutes'] as List<Map<String, dynamic>>;
    expect(options.map((o) => o['fare']).toList(), [
      isNull,
      {'currency': 'HKD', 'amount': 24.5},
      isNull,
    ]);

    // The request asked for the price, and for the least walking.
    final mask = adapter.lastRequest!.headers['X-Goog-FieldMask'] as String;
    expect(mask.split(','), contains('routes.travelAdvisory.transitFare'));
    final body = adapter.lastRequest!.data as Map;
    expect(body['transitPreferences'], {'routingPreference': 'LESS_WALKING'});
  });

  test('an unpriced itinerary carries no fare key at all', () async {
    install({
      'routes': [
        _route(steps: [_rideStep('65')], fare: const <String, Object>{}),
      ],
    });

    final res = await GoogleMapsService.getOptimizedRouteDetails(
      origin: const LatLng(22.2481, 114.1746),
      destination: _stop(const LatLng(22.2782, 114.1821)),
      optimizeWaypoints: false,
      mode: 'transit',
    );

    final legs = res['legDetails'] as List<Map<String, dynamic>>;
    expect(legs.first.containsKey('fare'), isFalse);
    expect(TransitFare.ofLeg(legs.first), isNull);
  });

  test('the router\'s single-leg route carries the fare', () async {
    install({
      'routes': [
        _route(
          steps: [_rideStep('Island Line')],
          fare: const {'currencyCode': 'HKD', 'units': '6'},
        ),
      ],
    });

    final leg = await MultiModalRouter.routeSingleLeg(
      from: const LatLng(22.2934, 114.1751),
      to: const LatLng(22.2841, 114.1555),
      mode: 'transit',
      departureTime: null,
    );

    expect(leg, isNotNull);
    expect(leg!.fare, const TransitFare(currency: 'HKD', amount: 6));
    expect(leg.fare!.label, r'HK$6.00');
  });
}
