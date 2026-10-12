```bash
#!/usr/bin/env bash
set -e

FLUTTER_VERSION="3.47.1"
FLUTTER_ARCHIVE="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

echo "Downloading Flutter ${FLUTTER_VERSION}..."
curl -fL \
  "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${FLUTTER_ARCHIVE}" \
  -o "/tmp/${FLUTTER_ARCHIVE}"

echo "Extracting Flutter..."
tar -xf "/tmp/${FLUTTER_ARCHIVE}" -C /tmp

export PATH="/tmp/flutter/bin:$PATH"

flutter --version
flutter pub get
flutter build web --release

echo "Flutter web build completed."
```