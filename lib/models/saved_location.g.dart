// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'saved_location.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SavedLocationAdapter extends TypeAdapter<SavedLocation> {
  @override
  final int typeId = 1;

  @override
  SavedLocation read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SavedLocation(
      id: fields[0] as String,
      userId: fields[1] as String,
      name: fields[2] as String,
      lat: fields[3] as double,
      lng: fields[4] as double,
      createdAt: fields[5] as DateTime,
      lastSyncedAt: fields[6] as DateTime?,
      isSynced: fields[7] as bool,
      source: fields[8] as String,
      fingerprint: fields[9] as String,
      isSkipped: fields[10] as bool,
      stayDuration: fields[11] as int,
      scheduledDate: fields[12] as DateTime?,
      tripId: fields[13] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, SavedLocation obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.userId)
      ..writeByte(2)
      ..write(obj.name)
      ..writeByte(3)
      ..write(obj.lat)
      ..writeByte(4)
      ..write(obj.lng)
      ..writeByte(5)
      ..write(obj.createdAt)
      ..writeByte(6)
      ..write(obj.lastSyncedAt)
      ..writeByte(7)
      ..write(obj.isSynced)
      ..writeByte(8)
      ..write(obj.source)
      ..writeByte(9)
      ..write(obj.fingerprint)
      ..writeByte(10)
      ..write(obj.isSkipped)
      ..writeByte(11)
      ..write(obj.stayDuration)
      ..writeByte(12)
      ..write(obj.scheduledDate)
      ..writeByte(13)
      ..write(obj.tripId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SavedLocationAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
