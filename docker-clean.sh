#!/bin/bash
set -e

echo "🧹 Cleaning project-specific Docker resources..."

# Stop and remove containers, networks, volumes, and images for this project
docker-compose down -v --rmi all

echo "🗑️ Pruning general Docker build cache and dangling images..."

# Clean dangling images and build cache
docker system prune -f

echo "✅ Docker cleanup completed!"

echo "🔨 Building fresh Android APK..."

# The 'up' command with '--build' will build the image.
# '--no-cache' ensures it's a fresh build.
# '--exit-code-from' will wait for the service to finish and return its exit code, propagating build failures.
docker-compose up --build --no-cache --exit-code-from build-android build-android

echo "✅ Build process completed!"
