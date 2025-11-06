# Multi-stage Dockerfile for Flutter TripFlow App

# Use ARGs to easily update versions
ARG FLUTTER_VERSION=3.22.2
ARG ANDROID_CMD_TOOLS_VERSION=11076708

# --- Base Stage ---
# Installs OS, Flutter, and Android SDK
FROM ubuntu:22.04 as base

# Add ARGs to this stage
ARG FLUTTER_VERSION
ARG ANDROID_CMD_TOOLS_VERSION

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV FLUTTER_ROOT=/opt/flutter
ENV PATH=$FLUTTER_ROOT/bin:$PATH
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=${ANDROID_SDK_ROOT}
ENV PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# Install system dependencies, create a non-root user
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    libglu1-mesa \
    openjdk-17-jdk \
    wget \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 flutter \
    && useradd --uid 1000 --gid 1000 -m -s /bin/bash flutter

# Install Flutter
RUN git clone https://github.com/flutter/flutter.git -b ${FLUTTER_VERSION} --depth 1 ${FLUTTER_ROOT} && \
    flutter config --no-analytics && \
    flutter precache

# Install Android SDK
RUN mkdir -p $ANDROID_HOME/cmdline-tools && \
    cd $ANDROID_HOME/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMD_TOOLS_VERSION}_latest.zip -O tools.zip && \
    unzip tools.zip && \
    mv cmdline-tools latest && \
    rm tools.zip

# Accept Android licenses and install required SDK components
RUN yes | sdkmanager --licenses && \
    sdkmanager --install \
    "platform-tools" \
    "platforms;android-34" \
    "build-tools;34.0.0"

# Verify Flutter installation
RUN flutter doctor --android-licenses && \
    chown -R flutter:flutter ${FLUTTER_ROOT} && \
    chown -R flutter:flutter ${ANDROID_HOME}

# --- Builder Stage ---
# Copies source code and fetches dependencies
FROM base as builder

# Set working directory
WORKDIR /app

# Copy pubspec files first for better caching
COPY --chown=flutter:flutter pubspec.yaml pubspec.lock ./

# Switch to non-root user
USER flutter

# Get Flutter dependencies
RUN flutter pub get

# Copy the rest of the application
COPY --chown=flutter:flutter . .

# Create .env file if it doesn't exist (you'll need to provide your actual values)
RUN echo "# Add your environment variables here" > .env && \
    echo "# GOOGLE_MAPS_API_KEY=your_api_key_here" >> .env

# Verify Flutter setup as the non-root user
RUN flutter doctor -v

# Build stage for Android APK
FROM builder as build-android

# Build Android APK with verbose output
RUN flutter build apk --release --verbose

# Build stage for Android App Bundle
FROM builder as build-appbundle

# Build Android App Bundle
RUN flutter build appbundle --release

# Build stage for Web
FROM builder as build-web

# Install web dependencies
RUN flutter config --enable-web && \
    flutter build web --release

# Production stage for serving web app
FROM nginx:1.25-alpine as production-web

# Copy built web app to nginx
COPY --from=build-web /app/build/web /usr/share/nginx/html

# Copy custom nginx config
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]

# Utility stage for running tests
FROM builder as test

# Run Flutter tests
CMD ["flutter", "test"]

# Utility stage for running linting
FROM builder as lint

# Run Flutter analyze
CMD ["flutter", "analyze"]

# Utility stage for development with hot reload
FROM builder as dev

EXPOSE 3000

# Start Flutter web development server
CMD ["flutter", "run", "-d", "web-server", "--web-port", "3000", "--web-hostname", "0.0.0.0"]
