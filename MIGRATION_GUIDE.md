# Migration Guide: Performance Optimization Update

## Overview
This guide helps you understand the changes made during the performance optimization update and how to work with the new architecture.

## Breaking Changes

### Deprecated Providers

#### 1. `proximityThresholdProvider` (settings_provider.dart)
**Old:**
```dart
final threshold = ref.watch(proximityThresholdProvider);
ref.read(proximityThresholdProvider.notifier).state = 1500.0;
```

**New:**
```dart
// For display (updates immediately)
final threshold = ref.watch(proximityThresholdPreviewProvider);

// For calculations (debounced)
final threshold = ref.watch(proximityThresholdCommittedProvider);

// To update
ref.read(debouncedProximityThresholdProvider.notifier).updatePreviewValue(1500.0);
```

#### 2. `tappedPolylineIdProvider` (settings_provider.dart)
**Old:**
```dart
final polylineId = ref.watch(tappedPolylineIdProvider);
ref.read(tappedPolylineIdProvider.notifier).state = 'leg_0';
```

**New:**
```dart
final polylineId = ref.watch(tappedPolylineIdProvider);
ref.read(mapUIStateProvider.notifier).setTappedPolyline('leg_0');
```

### Removed Local State Variables

The following local state variables in `MapScreen` have been moved to providers:

- `_isFabMenuOpen` → `fabMenuOpenProvider`
- `_showPolylineInfoOverlay` → Part of `mapUIStateProvider`
- `_highlightedLocationIndex` → `highlightedLocationIndexProvider`
- `_currentRouteDescription`, etc. → Part of `mapUIStateProvider`

### Widget Parameter Changes

#### TripBottomSheet
**Old:**
```dart
TripBottomSheet(
  sheetController: _sheetController,
  onLocationTap: _zoomToLocation,
  highlightedLocationIndex: _highlightedLocationIndex,
)
```

**New:**
```dart
TripBottomSheet(
  sheetController: _sheetController,
  onLocationTap: _zoomToLocation,
)
// highlightedLocationIndex is now read from highlightedLocationIndexProvider
```

## New Features

### 1. Place Names Toggle
A new mini FAB button in the top-right corner toggles marker info windows:

```dart
// Check current state
final showPlaceNames = ref.watch(showPlaceNamesProvider);

// Toggle
ref.read(showPlaceNamesProvider.notifier).state = !showPlaceNames;
```

### 2. Debounced Settings
Settings that trigger expensive calculations now use debouncing:

```dart
// Update with debounce (for user input)
ref.read(debouncedProximityThresholdProvider.notifier).updatePreviewValue(value);

// Check if debouncing
final isDebouncing = ref.watch(isProximityThresholdDebouncingProvider);

// Set immediately (for programmatic updates)
ref.read(debouncedProximityThresholdProvider.notifier).setValueImmediately(value);
```

## Provider Architecture

### State Hierarchy

```
1. Data Providers (heavy operations)
   - tripProvider: Locations, routes, trip data
   - Triggers: User adds/removes locations, generates routes

2. Cached Computation Providers (expensive, memoized)
   - cachedMarkersProvider: Marker generation
   - memoizedZonesProvider: Zone polygon calculations
   - Triggers: Only when underlying data changes

3. UI State Providers (lightweight, frequent)
   - mapUIStateProvider: All transient UI state
   - showPlaceNamesProvider: Toggle for info windows
   - Triggers: Button clicks, user interactions

4. Settings Providers (debounced)
   - debouncedProximityThresholdProvider: Zone distance
   - Triggers: After user stops adjusting

5. Assembly Providers (combine others)
   - assembledMapOverlaysProvider: Final map state
   - styledPolylinesProvider: Polylines with styling
   - Triggers: When any dependency changes
```

### Provider Selection Strategy

**Use `.select()` for specific values:**
```dart
// Good: Only rebuilds when this specific value changes
final isFabMenuOpen = ref.watch(
  mapUIStateProvider.select((state) => state.isFabMenuOpen)
);

// Better: Use pre-defined selector provider
final isFabMenuOpen = ref.watch(fabMenuOpenProvider);
```

**Use full state when you need multiple values:**
```dart
// Acceptable when you need multiple values
final uiState = ref.watch(mapUIStateProvider);
final hasOverlay = uiState.showPolylineInfoOverlay;
final routeDesc = uiState.routeDescription;
```

## Common Patterns

### Pattern 1: Update UI Without Map Rebuild
```dart
// ✅ Good: Updates UI state only
ref.read(mapUIStateProvider.notifier).toggleFabMenu();

// ❌ Bad: Would trigger setState and full rebuild
setState(() { _isFabMenuOpen = !_isFabMenuOpen; });
```

### Pattern 2: Batch Multiple UI Updates
```dart
// ✅ Good: Single state update
ref.read(mapUIStateProvider.notifier).showPolylineInfo(
  routeDescription: desc,
  formattedDuration: duration,
  formattedDistance: distance,
  legIndex: index,
);

// ❌ Bad: Multiple separate updates
ref.read(mapUIStateProvider.notifier).setTappedPolyline(id);
setState(() {
  _showOverlay = true;
  _routeDescription = desc;
  _formattedDuration = duration;
});
```

### Pattern 3: Clear All Highlights
```dart
// ✅ Good: Single method clears everything
ref.read(mapUIStateProvider.notifier).clearHighlights();

// ❌ Bad: Multiple separate calls
ref.read(tappedPolylineIdProvider.notifier).state = null;
setState(() {
  _showOverlay = false;
  _highlightedIndex = null;
});
```

### Pattern 4: Debounced User Input
```dart
// ✅ Good: Updates preview immediately, commits after delay
Slider(
  value: ref.watch(proximityThresholdPreviewProvider),
  onChanged: (value) {
    ref.read(debouncedProximityThresholdProvider.notifier)
       .updatePreviewValue(value);
  },
);

// ❌ Bad: Triggers expensive calculations on every change
Slider(
  value: ref.watch(proximityThresholdProvider),
  onChanged: (value) {
    ref.read(proximityThresholdProvider.notifier).state = value;
  },
);
```

## Testing Guidance

### Unit Testing Providers

```dart
test('mapUIStateProvider toggles FAB menu', () {
  final container = ProviderContainer();
  
  // Initial state
  expect(container.read(mapUIStateProvider).isFabMenuOpen, false);
  
  // Toggle
  container.read(mapUIStateProvider.notifier).toggleFabMenu();
  
  // Verify
  expect(container.read(mapUIStateProvider).isFabMenuOpen, true);
});
```

### Testing Debounced Providers

```dart
test('proximityThreshold debounces updates', () async {
  final container = ProviderContainer();
  
  // Rapid updates
  container.read(debouncedProximityThresholdProvider.notifier)
           .updatePreviewValue(1000);
  container.read(debouncedProximityThresholdProvider.notifier)
           .updatePreviewValue(2000);
  
  // Preview updates immediately
  expect(container.read(proximityThresholdPreviewProvider), 2000);
  
  // Committed value hasn't changed yet
  expect(container.read(proximityThresholdCommittedProvider), 1000);
  
  // Wait for debounce
  await Future.delayed(Duration(milliseconds: 350));
  
  // Now committed value updates
  expect(container.read(proximityThresholdCommittedProvider), 2000);
});
```

### Testing Cached Providers

```dart
test('cachedMarkersProvider uses cache', () async {
  final container = ProviderContainer();
  
  // First call generates markers
  final markers1 = await container.read(cachedMarkersProvider.future);
  
  // Second call uses cache (same location data)
  final markers2 = await container.read(cachedMarkersProvider.future);
  
  // Should be identical (cached)
  expect(markers1.cacheKey, markers2.cacheKey);
});
```

## Debugging

### Provider Observers

Add a provider observer to track state changes:

```dart
class MyProviderObserver extends ProviderObserver {
  @override
  void didUpdateProvider(
    ProviderBase provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    print('Provider ${provider.name ?? provider.runtimeType} updated');
    print('Previous: $previousValue');
    print('New: $newValue');
  }
}

// In main.dart
runApp(
  ProviderScope(
    observers: [MyProviderObserver()],
    child: TripFlowApp(),
  ),
);
```

### Performance Monitoring

Check console logs for performance insights:
- `🏗️ Building MapOverlayNotifier` - Overlay initialization
- `🔄 MapOverlay build triggered` - Rebuild events
- `🎨 Generating cached markers` - Marker generation
- `📏 Computing zones with key` - Zone calculations
- `✅ MapWidget rendering` - Final render

## Troubleshooting

### Issue: Map not updating after location change
**Cause:** Not watching the right provider
**Solution:** Use `cachedMarkersProvider` which watches `tripProvider`

### Issue: Slider feels laggy
**Cause:** Using committed value for display
**Solution:** Use `proximityThresholdPreviewProvider` for slider value

### Issue: Button click causes full screen rebuild
**Cause:** Using setState in widget
**Solution:** Update provider state instead

### Issue: Place names not toggling
**Cause:** Markers not regenerating with new InfoWindow state
**Solution:** Ensure `showPlaceNamesProvider` is watched by `cachedMarkersProvider`

## Performance Checklist

✅ **Do:**
- Use provider selectors for specific values
- Batch related state updates into single method
- Use debouncing for user input that triggers expensive operations
- Cache expensive computations (markers, zones)
- Separate UI state from data state

❌ **Don't:**
- Use setState for state that affects map rendering
- Watch entire provider when you only need one value
- Update providers in loops without batching
- Regenerate markers when only styling changes
- Calculate zones on every UI interaction

## Getting Help

If you encounter issues:
1. Check console logs for performance insights
2. Verify you're using the new providers (not deprecated ones)
3. Ensure proper provider watching (not reading in build)
4. Review the performance optimization documentation
5. Check that debounced values are used correctly

## Summary

The optimization transforms state management from:
- Local setState → Provider-based state
- Synchronous blocking → Async non-blocking
- Full rebuilds → Granular updates
- No caching → Smart caching with memoization
- Direct updates → Debounced updates for expensive operations

Result: **Instant button interactions, no screen refreshing, smooth 60 FPS performance.**
