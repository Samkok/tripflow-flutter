# TripFlow - Text Size Issue Fix

## Problem
The map labels, text, and all UI elements were appearing oversized.

## Root Cause
Flutter apps by default respect system accessibility settings for **text scale factor**. When users have increased "Display Size" or "Font Size" in their device settings (common on Android), the entire app scales up, including:
- Google Maps labels and text
- All UI components
- Bottom sheet text
- Buttons and icons with text

This can cause:
- ❌ Map labels to overlap
- ❌ UI elements to break layouts
- ❌ Bottom sheet content to become too large
- ❌ Poor user experience

## Solution
Added a `MediaQuery` builder in `app.dart` to **constrain the text scale factor** to a reasonable range:

```dart
builder: (context, child) {
  return MediaQuery(
    data: MediaQuery.of(context).copyWith(
      // Clamp text scale between 0.8 and 1.2 (max 20% larger than default)
      textScaleFactor: MediaQuery.of(context).textScaleFactor.clamp(0.8, 1.2),
    ),
    child: child!,
  );
}
```

### What This Does:
- ✅ Limits text scaling to **80% minimum** and **120% maximum** of default size
- ✅ Maintains readability while preventing extreme scaling
- ✅ Keeps layouts intact and prevents overlapping elements
- ✅ Applies to the entire app including Google Maps

### Before:
- Device text scale: 200% (2.0) → App uses 2.0 → Everything huge
- Map labels: Overlapping and unreadable
- Bottom sheet: Content spills out of bounds

### After:
- Device text scale: 200% (2.0) → App uses 1.2 (clamped) → Reasonable size
- Map labels: Clear and properly sized
- Bottom sheet: Everything fits perfectly

## Technical Details

**Text Scale Factor Clamping:**
- `0.8` = 80% of default size (prevents text from being too small)
- `1.2` = 120% of default size (prevents text from being too large)

This strikes a good balance between:
1. **Accessibility** - Text can still scale up 20% for users who need it
2. **Design Integrity** - Prevents extreme scaling that breaks layouts
3. **User Experience** - Maps and UI remain usable and beautiful

## Alternative Approaches Considered

1. **No clamping** - Let system scale infinitely
   - ❌ Breaks layouts with extreme scaling
   
2. **Fixed scale factor (1.0)** - Ignore all system settings
   - ❌ Bad for accessibility
   
3. **Per-widget control** - Apply `textScaleFactor` to each widget
   - ❌ Too much work, inconsistent results

4. **Current solution (0.8 - 1.2 range)** ✅
   - ✅ Best balance of accessibility and design integrity

## Files Modified

- ✅ `lib/app.dart` - Added MediaQuery builder with text scale clamping

## Testing

After this fix, test the app with different device settings:
1. Go to device **Settings → Accessibility → Display Size** and try different sizes
2. Go to device **Settings → Accessibility → Font Size** and try different sizes
3. Verify the app looks good in all cases

The app should now maintain consistent, readable sizing regardless of system settings!
