import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/location_service.dart';

// Provider for toggling the visibility of marker info windows (names)
final showMarkerNamesProvider = StateProvider<bool>((ref) => true);

// Provider for the device's compass heading
final headingStreamProvider = StreamProvider<double?>((ref) => LocationService.getCompassStream());
