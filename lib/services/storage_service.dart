import 'dart:convert';
import 'dart:developer';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/trip_model.dart';
import '../models/location_model.dart';
import '../models/saved_location.dart';

class StorageService {
  static const String _tripsKey = 'saved_trips';
  static const String _locationsKey = 'pinned_locations';
  static const String _hiveLocationBoxName = 'saved_locations';

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

  // Hive-based storage for anonymous and offline locations
  
  /// Get or initialize Hive box for locations
  static Future<Box<SavedLocation>> getHiveBox() async {
    try {
      if (Hive.isBoxOpen(_hiveLocationBoxName)) {
        return Hive.box<SavedLocation>(_hiveLocationBoxName);
      }
      return await Hive.openBox<SavedLocation>(_hiveLocationBoxName);
    } catch (e) {
      log('Error opening Hive box: $e');
      rethrow;
    }
  }

  /// Save a location to Hive
  static Future<void> saveLocationToHive(SavedLocation location) async {
    try {
      final box = await getHiveBox();
      await box.put(location.id, location);
    } catch (e) {
      log('Error saving location to Hive: $e');
    }
  }

  /// Save multiple locations to Hive
  static Future<void> saveLocationsToHive(List<SavedLocation> locations) async {
    try {
      final box = await getHiveBox();
      for (final location in locations) {
        await box.put(location.id, location);
      }
    } catch (e) {
      log('Error saving locations to Hive: $e');
    }
  }

  /// Get locations for a specific user from Hive
  static Future<List<SavedLocation>> getHiveLocations(String userId) async {
    try {
      final box = await getHiveBox();
      return box.values
          .where((loc) => loc.userId == userId)
          .toList();
    } catch (e) {
      log('Error getting Hive locations: $e');
      return [];
    }
  }

  /// Delete a location from Hive
  static Future<void> deleteLocationFromHive(String locationId) async {
    try {
      final box = await getHiveBox();
      await box.delete(locationId);
    } catch (e) {
      log('Error deleting location from Hive: $e');
    }
  }

  /// Clear all locations for a user from Hive
  static Future<void> clearUserLocationsFromHive(String userId) async {
    try {
      final box = await getHiveBox();
      final keysToDelete = <String>[];
      
      for (final location in box.values) {
        if (location.userId == userId) {
          keysToDelete.add(location.id);
        }
      }
      
      for (final key in keysToDelete) {
        await box.delete(key);
      }
    } catch (e) {
      log('Error clearing user locations from Hive: $e');
    }
  }
}
