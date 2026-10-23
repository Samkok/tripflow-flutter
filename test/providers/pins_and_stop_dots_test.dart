import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/building_outline_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/optimized_map_overlay_provider.dart';
import 'package:voyza/providers/theme_provider.dart';
import 'package:voyza/providers/trip_day_labeler_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/utils/marker_ids.dart';
import 'package:voyza/utils/transit_line_style.dart';
import 'package:voyza/utils/trip_day_labels.dart';

class _FakeTripNotifier extends StateNotifier<TripState>
    implements TripNotifier {
  _FakeTripNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTheme extends StateNotifier<ThemeMode> implements ThemeNotifier {
  _FakeTheme() : super(ThemeMode.dark);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _day = DateTime(2026, 10, 14);

LocationModel _stop(String id, double lat, double lng) => LocationModel(
      id: id,
      name: 'Stop $id',
      address: '',
      coordinates: LatLng(lat, lng),
      addedAt: _day,
      scheduledDate: _day,
    );

/// One transit leg a → b: walk, a 4-stop tram ride (3 intermediate
/// stops), walk.
TripState _state() {
  final a = _stop('a', 22.2790, 114.1650);
  final b = _stop('b', 22.2770, 114.1730);
  final walk1 = [a.coordinates, const LatLng(22.2792, 114.1660)];
  final ride = [
    const LatLng(22.2792, 114.1660),
    const LatLng(22.2785, 114.1690),
    const LatLng(22.2780, 114.1710),
    const LatLng(22.2775, 114.1720),
  ];
  final walk2 = [const LatLng(22.2775, 114.1720), b.coordinates];
  final whole = [...walk1, ...ride, ...walk2];
  return TripState(
    pinnedLocations: [a, b],
    optimizedLocationsForSelectedDate: [a, b],
    startLocationId: 'a',
    optimizedRoute: whole,
    legPolylines: [whole],
    legDetails: [
      {
        'mode': 'transit',
        'distance': 1200.0,
        'duration': const Duration(minutes: 14),
        'fromId': 'a',
        'toId': 'b',
        'transit': [
          {
            'lineShort': '',
            'lineName': 'Tram',
            'lineColor': '#266b5c',
            'vehicleType': 'TRAM',
            'stopCount': 4,
            'boardStop': 'Admiralty Station',
            'alightStop': 'Wan Chai',
            // Left through exit A3, whose mouth is a few metres east of
            // the platform and faces east (Google's exit step geometry).
            'alightGate': {
              'kind': 'exit',
              'label': 'A3',
              'lat': 22.2775,
              'lng': 114.1722,
              'frontLat': 22.2775,
              'frontLng': 114.1724,
              'headingDeg': 88.0,
            },
          },
        ],
        'transitSteps': [
          {'mode': 'WALK', 'points': walk1, 'durationSeconds': 120},
          {
            'mode': 'TRANSIT',
            'points': ride,
            'durationSeconds': 600,
            'lineColor': '#266b5c',
            'vehicleType': 'TRAM',
          },
          {'mode': 'WALK', 'points': walk2, 'durationSeconds': 90},
        ],
      },
    ],
  );
}

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [
    tripProvider.overrideWith((ref) => _FakeTripNotifier(_state())),
    selectedDateProvider.overrideWith((ref) => _day),
    themeProvider.overrideWith((ref) => _FakeTheme()),
    activeTripDayLabelerProvider.overrideWithValue(DayLabeler.forTrip(null)),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Set<Marker>> markersOf(ProviderContainer c) async {
    await c.read(cachedMarkerBitmapsProvider.future);
    await c.read(transitStopLabelsProvider.future);
    await c.read(stationGateIconsProvider.future);
    // Let the sync provider pick the resolved bitmaps up.
    await Future<void>.delayed(Duration.zero);
    return c.read(finalMarkersProvider);
  }

  test('the names switch leaves the pin markers untouched', () async {
    final c = _container();
    final before = (await markersOf(c))
        .where((m) =>
            baseMarkerId(m.markerId.value) == 'a' ||
            baseMarkerId(m.markerId.value) == 'b')
        .toList();
    expect(before, hasLength(2));
    c.read(showPlaceNamesProvider.notifier).state = false;
    final after = (await markersOf(c))
        .where((m) =>
            baseMarkerId(m.markerId.value) == 'a' ||
            baseMarkerId(m.markerId.value) == 'b')
        .toList();
    // Equal markers = no platform update = no pin redraw on iOS.
    expect(after, before);
  });

  test('the selected leg beads its ride with one dot per intermediate stop',
      () async {
    final c = _container();
    Iterable<Marker> dots(Set<Marker> ms) =>
        ms.where((m) => m.markerId.value.startsWith('leg_stop_dot_'));
    expect(dots(await markersOf(c)), isEmpty);

    c.read(mapUIStateProvider.notifier).setTappedPolyline('leg_0_s1');
    final beads = dots(await markersOf(c)).toList();
    expect(beads, hasLength(3)); // 4 stops counted to the arrival → 3 between
    // All on the ride, none at its ends.
    for (final d in beads) {
      expect(d.position.longitude, greaterThan(114.1660));
      expect(d.position.longitude, lessThan(114.1720));
    }

    c.read(mapUIStateProvider.notifier).clearHighlights();
    expect(dots(await markersOf(c)), isEmpty);
  });

  test(
      'a ride left through a named exit gets a badge and an arrow on the ground',
      () async {
    final c = _container();
    final ms = await markersOf(c);
    // Ground overlays, not markers: a fixed footprint in metres.
    expect(ms.where((m) => m.markerId.value.startsWith('gate_')), isEmpty);
    final overlays = c.read(stationGateOverlaysProvider);
    final arrow = overlays
        .singleWhere((o) => o.groundOverlayId.value == 'gate_0_0_alight_arrow');
    final badge = overlays
        .singleWhere((o) => o.groundOverlayId.value == 'gate_0_0_alight');
    const mouth = LatLng(22.2775, 114.1722);
    for (final o in [arrow, badge]) {
      final b = o.bounds!;
      expect(b.contains(mouth), isTrue);
      expect(o.clickable, isFalse);
    }
    // The arrow is turned to the gate's outward heading (a map bearing, so
    // it survives map rotation); the badge stays upright.
    expect(arrow.bearing, 88.0);
    expect(badge.bearing, 0.0);
    expect(badge.zIndex, greaterThan(arrow.zIndex));
    // Metres, not pixels: the arrow's box is wider than the badge's, and
    // both are a few tens of metres at most.
    double widthM(GroundOverlay o) =>
        (o.bounds!.northeast.longitude - o.bounds!.southwest.longitude) *
        111320 *
        0.926; // cos(22.3°)
    expect(widthM(arrow), closeTo(35.5, 1));
    expect(widthM(badge), inInclusiveRange(10, 25));
    // No entrance was named for boarding, so no boarding gate.
    expect(overlays.where((o) => o.groundOverlayId.value.contains('board')),
        isEmpty);
    // The gate's mouth gets no endpoint collar of its own.
    expect(ms.where((m) => m.markerId.value == 'leg_dot_22.27750,114.17220'),
        isEmpty);
  });

  test('the focused place gets the app callout, not a platform info window',
      () async {
    final c = _container();
    final pins = (await markersOf(c)).where((m) =>
        baseMarkerId(m.markerId.value) == 'a' ||
        baseMarkerId(m.markerId.value) == 'b');
    for (final p in pins) {
      expect(p.infoWindow, InfoWindow.noText);
    }
    expect(await c.read(focusedPlaceCalloutProvider.future), isEmpty);

    final a = c.read(tripProvider).pinnedLocations.first;
    c.read(focusedPlaceProvider.notifier).state = a;
    final callout = await c.read(focusedPlaceCalloutProvider.future);
    expect(callout.map((m) => baseMarkerId(m.markerId.value)),
        ['place_callout_a']);
    final m = callout.single;
    expect(m.position, a.coordinates);
    // Bottom-centre anchored: the card floats above the pin's head.
    expect(m.anchor, const Offset(0.5, 1.0));
    expect(m.consumeTapEvents, isTrue);

    c.read(focusedPlaceProvider.notifier).state = null;
    expect(await c.read(focusedPlaceCalloutProvider.future), isEmpty);
  });

  test('chip badges carry every ride in its line colour, or the shared blue',
      () {
    final badges = chipBadgesFor([
      {'lineShort': '15', 'lineColor': '#f2f200', 'lineTextColor': '#1f4b7d'},
      {'lineShort': 'Island Line'},
      {'lineShort': '   '},
    ]);
    expect(badges.map((b) => b.text), ['15', 'Island Line']);
    expect(badges[0].fill, const Color(0xFFF2F200));
    expect(badges[0].textColor, const Color(0xFF1F4B7D));
    expect(badges[1].fill, defaultTransitLineColor);
    expect(badges[1].textColor, isNull);
  });
}
