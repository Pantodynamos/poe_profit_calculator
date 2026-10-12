#!/usr/bin/env bash
set -euo pipefail

FLUTTER_VERSION="3.47.1"
FLUTTER_ARCHIVE="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${FLUTTER_ARCHIVE}"

echo "Downloading Flutter ${FLUTTER_VERSION}..."
curl --fail --location --show-error "$FLUTTER_URL" --output "/tmp/${FLUTTER_ARCHIVE}"

echo "Extracting Flutter..."
tar -xf "/tmp/${FLUTTER_ARCHIVE}" -C /tmp

export PATH="/tmp/flutter/bin:$PATH"

echo "Checking Flutter installation..."
flutter --version

echo "Installing dependencies..."
flutter pub get

echo "Building Flutter Web..."
flutter build web --release

echo "Flutter Web build completed."