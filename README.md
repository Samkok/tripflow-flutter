# TripFlow - Flutter Mobile App

A beautiful, minimalist mobile app for trip planning with Google Maps integration, route optimization, and real-time location tracking.

## Features

- 🗺️ **Google Maps Integration** - Interactive maps with custom styling
- 📍 **Location Search** - Google Places Autocomplete for easy location finding
- 🧭 **Route Optimization** - Smart route planning using Google Directions API
- 📱 **Real-time Tracking** - Live location updates with geolocator
- 💾 **Local Storage** - Save trips locally with shared preferences
- 🎨 **Beautiful UI** - Minimalist futuristic design with dark theme
- 📊 **Trip Analytics** - Travel time estimation and ETA calculation
- 🔄 **State Management** - Reactive UI with Riverpod

## Setup Instructions

### 1. Google API Configuration

1. Go to the [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select an existing one
3. Enable the following APIs:
   - Maps SDK for Android
   - Maps SDK for iOS
   - Places API
   - Directions API

4. Create API credentials:
   - Go to "Credentials" in the Google Cloud Console
   - Click "Create Credentials" > "API Key"
   - Create separate keys for each platform if needed

### 2. Environment Setup

Update the `.env` file with your Google API keys:

```env
GOOGLE_MAPS_API_KEY=your_actual_api_key_here
GOOGLE_PLACES_API_KEY=your_actual_api_key_here
GOOGLE_DIRECTIONS_API_KEY=your_actual_api_key_here
```

### 3. Platform Configuration

**Android:**
- Update `android/app/src/main/AndroidManifest.xml`
- Replace `your_google_maps_api_key_here` with your actual API key

**iOS:**
- Update `ios/Runner/Info.plist`
- Replace `your_google_maps_api_key_here` with your actual API key

### 4. Installation

```bash
# Get dependencies
flutter pub get

# Run on device/emulator
flutter run
```

## Architecture

- **State Management**: Riverpod for reactive state management
- **Navigation**: go_router for declarative routing
- **Local Storage**: shared_preferences for trip data persistence
- **API Integration**: dio for HTTP requests to Google APIs
- **Location Services**: geolocator for real-time location tracking

## Usage

1. **Search & Pin**: Use the search bar to find places and pin them to your trip
2. **Optimize Route**: Tap the route button to generate an optimized visiting order
3. **Track Progress**: View real-time location updates and trip progress
4. **Save Trips**: Save your planned trips for later reference

## Key Dependencies

- `google_maps_flutter`: Google Maps integration
- `geolocator`: Location tracking and permissions
- `flutter_riverpod`: State management
- `go_router`: Navigation
- `shared_preferences`: Local data storage
- `flutter_dotenv`: Environment variable management

## Project Structure

```
lib/
├── main.dart                 # App entry point
├── app.dart                  # Main app configuration
├── core/
│   └── theme.dart           # App theming
├── models/
│   ├── location_model.dart  # Location data model
│   └── trip_model.dart      # Trip data model
├── providers/
│   ├── trip_provider.dart   # Trip state management
│   └── places_provider.dart # Places search state
├── services/
│   ├── location_service.dart    # Location utilities
│   ├── google_maps_service.dart # Google Maps API
│   ├── places_service.dart      # Google Places API
│   └── storage_service.dart     # Local storage
├── screens/
│   ├── map_screen.dart          # Main map interface
│   └── trip_history_screen.dart # Trip history view
└── widgets/
    ├── map_widget.dart          # Google Maps widget
    ├── search_widget.dart       # Location search
    └── trip_bottom_sheet.dart   # Draggable trip summary
```

## Notes

- Remember to add your Google API keys to both the `.env` file and platform-specific configuration files
- The app requires location permissions to function properly
- Make sure to enable the required Google APIs in your Google Cloud project
- Test on a physical device for best location tracking results