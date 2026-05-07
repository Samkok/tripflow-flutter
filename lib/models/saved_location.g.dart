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
      isDone: fields[16] == null ? false : fields[16] as bool,
      stayDuration: fields[11] as int,
      scheduledDate: fields[12] as DateTime?,
      tripId: fields[13] as String?,
      photoReference: fields[14] as String?,
      photoAttributions: (fields[15] as List?)?.cast<String>(),
      photoReferences: (fields[17] as List?)?.cast<String>(),
      placeId: fields[18] as String?,
      originalName: fields[19] as String?,
      googleOpeningHours: (fields[20] as List?)?.cast<OpeningPeriod>(),
      userClosingMinuteOverride: fields[21] as int?,
      hoursLastRefreshedAt: fields[22] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, SavedLocation obj) {
    writer
      ..writeByte(23)
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
      ..write(obj.tripId)
      ..writeByte(14)
      ..write(obj.photoReference)
      ..writeByte(15)
      ..write(obj.photoAttributions)
      ..writeByte(16)
      ..write(obj.isDone)
      ..writeByte(17)
      ..write(obj.photoReferences)
      ..writeByte(18)
      ..write(obj.placeId)
      ..writeByte(19)
      ..write(obj.originalName)
      ..writeByte(20)
      ..write(obj.googleOpeningHours)
      ..writeByte(21)
      ..write(obj.userClosingMinuteOverride)
      ..writeByte(22)
      ..write(obj.hoursLastRefreshedAt);
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

class OpeningPeriodAdapter extends TypeAdapter<OpeningPeriod> {
  @override
  final int typeId = 2;

  @override
  OpeningPeriod read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return OpeningPeriod(
      openDay: fields[0] as int,
      openMinutes: fields[1] as int,
      closeDay: fields[2] as int?,
      closeMinutes: fields[3] as int?,
    );
  }

  @override
  void write(BinaryWriter writer, OpeningPeriod obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.openDay)
      ..writeByte(1)
      ..write(obj.openMinutes)
      ..writeByte(2)
      ..write(obj.closeDay)
      ..writeByte(3)
      ..write(obj.closeMinutes);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpeningPeriodAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
