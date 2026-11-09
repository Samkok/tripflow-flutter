import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which parts of the place sheet are open. Session memory, shared by every
/// sheet opened this run (the sheet itself is stateless), so a traveller
/// who opened "Details" once keeps it open for the next place too.
final detailSheetDetailsOpenProvider = StateProvider<bool>((_) => false);
final detailSheetPhotosOpenProvider = StateProvider<bool>((_) => false);
final detailSheetHoursOpenProvider = StateProvider<bool>((_) => false);
