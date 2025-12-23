enum CollaboratorPermission {
  read,
  write,
}

class TripCollaborator {
  final String id;
  final String tripId;
  final String userId;
  final String email;
  final String permission; // 'read' or 'write'
  final String invitedBy;
  final DateTime invitedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  TripCollaborator({
    required this.id,
    required this.tripId,
    required this.userId,
    required this.email,
    required this.permission,
    required this.invitedBy,
    required this.invitedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory TripCollaborator.fromJson(Map<String, dynamic> json) {
    return TripCollaborator(
      id: json['id'] as String,
      tripId: json['trip_id'] as String,
      userId: json['user_id'] as String,
      email: json['email'] as String,
      permission: json['permission'] as String,
      invitedBy: json['invited_by'] as String,
      invitedAt: DateTime.parse(json['invited_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'trip_id': tripId,
      'user_id': userId,
      'email': email,
      'permission': permission,
      'invited_by': invitedBy,
      'invited_at': invitedAt.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  bool get hasWriteAccess => permission == 'write';
  bool get hasReadAccess => permission == 'read' || permission == 'write';

  TripCollaborator copyWith({
    String? id,
    String? tripId,
    String? userId,
    String? email,
    String? permission,
    String? invitedBy,
    DateTime? invitedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TripCollaborator(
      id: id ?? this.id,
      tripId: tripId ?? this.tripId,
      userId: userId ?? this.userId,
      email: email ?? this.email,
      permission: permission ?? this.permission,
      invitedBy: invitedBy ?? this.invitedBy,
      invitedAt: invitedAt ?? this.invitedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
