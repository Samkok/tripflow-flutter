import 'dart:io';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/location_model.dart';
import 'package:intl/intl.dart';

class CsvService {
  /// Exports one day's plan. The file is named after the trip and the day
  /// ("Taiwan 2026-09-03.csv") and shared as a bare attachment — no
  /// message text, no subject.
  Future<void> generateAndShareTripCsv(
    List<LocationModel> locations, {
    String? tripName,
    DateTime? date,
  }) async {
    if (locations.isEmpty) return;

    List<List<dynamic>> rows = [];

    // Header. Deliberately NOT exported (owner request): Address, Travel
    // Time from Previous, Distance from Previous, and Status — the sheet
    // is the plan itself: what, when, and for how long.
    rows.add([
      'Order',
      'Name',
      'Scheduled Date',
      'Stay Duration (min)',
    ]);

    // Data
    for (int i = 0; i < locations.length; i++) {
      final loc = locations[i];

      String scheduledDate = loc.scheduledDate != null
          ? DateFormat('yyyy-MM-dd').format(loc.scheduledDate!)
          : '';

      rows.add([
        i + 1,
        loc.name,
        scheduledDate,
        loc.stayDuration.inMinutes,
      ]);
    }

    String csvData = const ListToCsvConverter().convert(rows);

    // File name: "<trip name> <yyyy-MM-dd>.csv", with characters that
    // filesystems / share targets reject stripped, and a sane fallback.
    final safeName = (tripName ?? '')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final dayPart = date == null ? '' : DateFormat('yyyy-MM-dd').format(date);
    final base = [if (safeName.isNotEmpty) safeName, if (dayPart.isNotEmpty) dayPart]
        .join(' ');
    final fileName = '${base.isEmpty ? 'VoyZa trip plan' : base}.csv';

    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/$fileName';
    final file = File(path);
    await file.writeAsString(csvData);

    // Just the file — no message text, no subject.
    await Share.shareXFiles([XFile(path)]);
  }
}
