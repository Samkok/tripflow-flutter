import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/trip_model.dart';
import '../models/location_model.dart';

class StorageService {
  static const String _tripsKey = 'saved_trips';
  static const String _locationsKey = 'pinned_locations';

  static Future<List<TripModel>> getSavedTrips() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tripsJson = prefs.getStringList(_tripsKey) ?? [];
      
      return tripsJson
          .map((tripStr) => TripModel.fromJson(jsonDecode(tripStr)))
          .toList();
    } catch (e) {
      print('Error loading saved trips: $e');
      return [];
    }
  }

  static Future<void> saveTrip(TripModel trip) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final trips = await getSavedTrips();
      
      // Remove existing trip with same ID
      trips.removeWhere((t) => t.id == trip.id);
      trips.add(trip);
      
      final tripsJson = trips.map((t) => jsonEncode(t.toJson())).toList();
      await prefs.setStringList(_tripsKey, tripsJson);
    } catch (e) {
      print('Error saving trip: $e');
    }
  }

  static Future<List<LocationModel>> getPinnedLocations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final locationsJson = prefs.getStringList(_locationsKey) ?? [];
      
      return locationsJson
          .map((locationStr) => LocationModel.fromJson(jsonDecode(locationStr)))
          .toList();
    } catch (e) {
      print('Error loading pinned locations: $e');
      return [];
    }
  }

  static Future<void> savePinnedLocations(List<LocationModel> locations) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final locationsJson = locations.map((l) => jsonEncode(l.toJson())).toList();
      await prefs.setStringList(_locationsKey, locationsJson);
    } catch (e) {
      print('Error saving pinned locations: $e');
    }
  }
}