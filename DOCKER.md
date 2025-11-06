# Docker Setup for TripFlow Flutter App

This document explains how to use Docker with the TripFlow Flutter application.

## Prerequisites

- Docker installed on your system
- Docker Compose (optional, for easier management)

## Available Docker Stages

### 1. Development Environment
For local development with hot reload:
```bash
# Using Docker Compose
docker-compose up dev

# Using Docker directly
docker build --target dev -t tripflow-dev .
docker run -p 3000:3000 -v $(pwd):/app tripflow-dev
```

### 2. Production Web App
For serving the web version:
```bash
# Using Docker Compose
docker-compose up web

# Using Docker directly
docker build --target production-web -t tripflow-web .
docker run -p 8080:80 tripflow-web
```

### 3. Testing
Run Flutter tests:
```bash
# Using Docker Compose
docker-compose up test

# Using Docker directly
docker build --target test -t tripflow-test .
docker run tripflow-test
```

### 4. Linting
Run Flutter analyze:
```bash
# Using Docker Compose
docker-compose up lint

# Using Docker directly
docker build --target lint -t tripflow-lint .
docker run tripflow-lint
```

### 5. Building APK
Build Android APK:
```bash
# Using Docker Compose
docker-compose up build-android

# Using Docker directly
docker build --target build-android -t tripflow-android .
docker run -v $(pwd)/build:/app/build tripflow-android
```

### 6. Building App Bundle
Build Android App Bundle:
```bash
# Using Docker Compose
docker-compose up build-appbundle

# Using Docker directly
docker build --target build-appbundle -t tripflow-bundle .
docker run -v $(pwd)/build:/app/build tripflow-bundle
```

## Environment Variables

Create a `.env` file in your project root with your API keys:
```env
GOOGLE_MAPS_API_KEY=your_google_maps_api_key_here
GOOGLE_PLACES_API_KEY=your_google_places_api_key_here
```

## Quick Commands

### Development
```bash
# Start development server with hot reload
docker-compose up dev
# Access at http://localhost:3000
```

### Production Web
```bash
# Build and serve web app
docker-compose up web
# Access at http://localhost:8080
```

### Build Android APK
```bash
# Build APK and save to ./build directory
docker-compose up build-android
```

### Run Tests
```bash
# Run all tests
docker-compose up test
```

## Docker Compose Services

- `dev`: Development environment with hot reload
- `web`: Production web server
- `test`: Run Flutter tests
- `lint`: Run Flutter analyze
- `build-android`: Build Android APK
- `build-appbundle`: Build Android App Bundle
- `build-web`: Build web application

## Troubleshooting

### Android Build Issues
If you encounter Android build issues, ensure:
1. Your Google Maps API key is properly set in the `.env` file
2. Android SDK licenses are accepted (handled automatically in Dockerfile)

### Web Build Issues
For web-specific issues:
1. Ensure all web dependencies are properly configured
2. Check that your API keys work for web domain

### Permission Issues
The Docker setup uses a non-root `flutter` user to prevent file permission issues when mounting local volumes (e.g., for hot reload or retrieving build artifacts).

If you have old files created by a previous root-user container, you may need to fix their ownership on your host machine (Linux/macOS):
```bash
# Fix file permissions
sudo chown -R $USER:$USER .
```

## File Structure
```
.
├── Dockerfile              # Multi-stage Docker build
├── docker-compose.yml      # Docker Compose configuration
├── .dockerignore          # Files to ignore during build
├── nginx.conf             # Nginx configuration for web
└── DOCKER.md              # This documentation
```

## Notes

- The Dockerfile uses multi-stage builds for optimization
- Development stage includes hot reload capabilities
- Production web stage uses nginx for serving
- All builds include proper caching for faster subsequent builds
- Android builds require proper API keys and signing configuration
