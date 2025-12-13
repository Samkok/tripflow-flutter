import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks whether the user has made a sync decision during this session
/// to prevent showing the sync modal repeatedly
final syncDecisionProvider = StateProvider<bool?>((ref) => null);

/// Tracks the user's choice: true = sync, false = discard
final userSyncChoiceProvider = StateProvider<bool?>((ref) => null);

/// Tracks if a sync operation is in progress
final isSyncingProvider = StateProvider<bool>((ref) => false);

/// Tracks sync errors for display in UI
final syncErrorProvider = StateProvider<String?>((ref) => null);
