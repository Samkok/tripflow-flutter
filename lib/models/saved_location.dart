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

  @HiveField(14)
  final String? photoReference;

  @HiveField(15)
  final List<String>? photoAttributions;

  @HiveField(16)
  final bool isDone;

  /// Up to 5 photo references for the in-card gallery. The first item is
  /// also stored in [photoReference] for back-compat with older clients.
  @HiveField(17)
  final List<String>? photoReferences;

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
    this.isDone = false,
    this.stayDuration = 0,
    this.scheduledDate,
    this.tripId,
    this.photoReference,
    this.photoReferences,
    this.photoAttributions,
  });

  /// Effective gallery list: prefers [photoReferences]; falls back to a
  /// single-item list built from [photoReference] for rows written by older
  /// clients.
  List<String> get effectivePhotoReferences {
    if (photoReferences != null && photoReferences!.isNotEmpty) {
      return photoReferences!;
    }
    if (photoReference != null && photoReference!.isNotEmpty) {
      return [photoReference!];
    }
    return const [];
  }

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
    bool? isDone,
    int? stayDuration,
    DateTime? scheduledDate,
    String? tripId,
    String? photoReference,
    List<String>? photoReferences,
    List<String>? photoAttributions,
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
      isDone: isDone ?? this.isDone,
      stayDuration: stayDuration ?? this.stayDuration,
      scheduledDate: scheduledDate ?? this.scheduledDate,
      tripId: tripId ?? this.tripId,
      photoReference: photoReference ?? this.photoReference,
      photoReferences: photoReferences ?? this.photoReferences,
      photoAttributions: photoAttributions ?? this.photoAttributions,
    );
  }

  factory SavedLocation.fromJson(Map<String, dynamic> json) {
    final refs = json['photo_references'];
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
      isDone: json['is_done'] ?? false,
      stayDuration: json['stay_duration'] ?? 0,
      scheduledDate: json['scheduled_date'] != null ? DateTime.parse(json['scheduled_date']) : null,
      tripId: json['trip_id'],
      photoReference: json['photo_reference'],
      photoReferences: refs is List ? List<String>.from(refs) : null,
      photoAttributions: json['photo_attributions'] != null
          ? List<String>.from(json['photo_attributions'])
          : null,
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
      'is_done': isDone,
      'stay_duration': stayDuration,
      'scheduled_date': scheduledDate?.toIso8601String(),
      'photo_reference': photoReference,
      'photo_references': photoReferences,
      'photo_attributions': photoAttributions,
    };
  }
}