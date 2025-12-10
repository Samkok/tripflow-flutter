// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'saved_location.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SavedLocationAdapter extends TypeAdapter<SavedLocation> {
  @override
  final int typeId = 0;

  @override
  SavedLocation read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SavedLocation(
      id: fields[0] as String,
      name: fields[1] as String,
      lat: fields[2] as double,
      lng: fields[3] as double,
      createdAt: fields[4] as DateTime,
      userId: fields[6] == null ? '' : fields[6] as String,
      fingerprint: fields[7] == null ? '' : fields[7] as String,
      isSynced: fields[5] as bool,
      lastSyncedAt: fields[8] as DateTime?,
      source: fields[9] == null ? 'local' : fields[9] as String,
    );
  }

  @override
  void write(BinaryWriter writer, SavedLocation obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.lat)
      ..writeByte(3)
      ..write(obj.lng)
      ..writeByte(4)
      ..write(obj.createdAt)
      ..writeByte(5)
      ..write(obj.isSynced)
      ..writeByte(6)
      ..write(obj.userId)
      ..writeByte(7)
      ..write(obj.fingerprint)
      ..writeByte(8)
      ..write(obj.lastSyncedAt)
      ..writeByte(9)
      ..write(obj.source);
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
