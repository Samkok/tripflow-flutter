import 'dart:io';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/location_model.dart';
import 'package:intl/intl.dart';

class CsvService {
  Future<void> generateAndShareTripCsv(List<LocationModel> locations) async {
    if (locations.isEmpty) return;

    List<List<dynamic>> rows = [];

    // Header
    rows.add([
      'Order',
      'Name',
      'Address',
      'Scheduled Date',
      'Stay Duration (min)',
      'Travel Time from Previous (min)',
      'Distance from Previous (km)',
      'Status'
    ]);

    // Data
    for (int i = 0; i < locations.length; i++) {
      final loc = locations[i];

      String scheduledDate = loc.scheduledDate != null
          ? DateFormat('yyyy-MM-dd').format(loc.scheduledDate!)
          : '';

      String travelTime = loc.travelTimeFromPrevious != null
          ? (loc.travelTimeFromPrevious!.inMinutes).toString()
          : '-';

      String distance = loc.distanceFromPrevious != null
          ? (loc.distanceFromPrevious! / 1000).toStringAsFixed(2)
          : '-';

      rows.add([
        i + 1,
        loc.name,
        loc.address,
        scheduledDate,
        loc.stayDuration.inMinutes,
        travelTime,
        distance,
        loc.isSkipped ? 'Skipped' : 'Active'
      ]);
    }

    String csvData = const ListToCsvConverter().convert(rows);

    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/voyza_trip_plan.csv';
    final file = File(path);
    await file.writeAsString(csvData);

    await Share.shareXFiles(
      [XFile(path)],
      text: 'My Trip Plan from VoyZa',
      subject: 'Trip Plan Details',
    );
  }
}
