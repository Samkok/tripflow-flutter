import 'package:hive/hive.dart';

part 'saved_location.g.dart';

@HiveType(typeId: 1)
class SavedLocation extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String userId;

  @HiveField(2)
  final String name;

  @HiveField(3)
  final double lat;

  @HiveField(4)
  final double lng;

  @HiveField(5)
  final DateTime createdAt;

  @HiveField(6)
  final DateTime? lastSyncedAt;

  @HiveField(7)
  final bool isSynced;

  @HiveField(8)
  final String source; // 'local' or 'synced'

  @HiveField(9)
  final String fingerprint;

  @HiveField(10)
  final bool isSkipped;

  @HiveField(11)
  final int stayDuration; // in seconds

  @HiveField(12)
  final DateTime? scheduledDate;

  @HiveField(13)
  final String? tripId; // UUID of associated trip

  SavedLocation({
    required this.id,
    required this.userId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.createdAt,
    this.lastSyncedAt,
    this.isSynced = false,
    this.source = 'local',
    required this.fingerprint,
    this.isSkipped = false,
    this.stayDuration = 0,
    this.scheduledDate,
    this.tripId,
  });

  SavedLocation copyWith({
    String? id,
    String? userId,
    String? name,
    double? lat,
    double? lng,
    DateTime? createdAt,
    DateTime? lastSyncedAt,
    bool? isSynced,
    String? source,
    String? fingerprint,
    bool? isSkipped,
    int? stayDuration,
    DateTime? scheduledDate,
    String? tripId,
  }) {
    return SavedLocation(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      createdAt: createdAt ?? this.createdAt,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      isSynced: isSynced ?? this.isSynced,
      source: source ?? this.source,
      fingerprint: fingerprint ?? this.fingerprint,
      isSkipped: isSkipped ?? this.isSkipped,
      stayDuration: stayDuration ?? this.stayDuration,
      scheduledDate: scheduledDate ?? this.scheduledDate,
      tripId: tripId ?? this.tripId,
    );
  }

  factory SavedLocation.fromJson(Map<String, dynamic> json) {
    return SavedLocation(
      id: json['id'],
      userId: json['user_id'] ?? '',
      name: json['name'],
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      createdAt: DateTime.parse(json['created_at']),
      lastSyncedAt: json['last_synced_at'] != null ? DateTime.parse(json['last_synced_at']) : null,
      isSynced: json['is_synced'] ?? true, // Assume synced if from remote
      source: json['source'] ?? 'synced',
      fingerprint: json['fingerprint'] ?? '',
      isSkipped: json['is_skipped'] ?? false,
      stayDuration: json['stay_duration'] ?? 0,
      scheduledDate: json['scheduled_date'] != null ? DateTime.parse(json['scheduled_date']) : null,
      tripId: json['trip_id'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'trip_id': tripId,
      'name': name,
      'lat': lat,
      'lng': lng,
      'created_at': createdAt.toIso8601String(),
      'last_synced_at': lastSyncedAt?.toIso8601String(),
      'is_synced': isSynced,
      'source': source,
      'fingerprint': fingerprint,
      'is_skipped': isSkipped,
      'stay_duration': stayDuration,
      'scheduled_date': scheduledDate?.toIso8601String(),
    };
  }
}