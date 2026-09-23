#!/bin/zsh
# Build Pulse.app.
#   ./build.sh                 build into build/
#   ./build.sh --install       build, then install to ~/Applications and launch
#   ./build.sh --release 1.2.0 build a versioned zip for a GitHub release
set -euo pipefail
cd "${0:A:h}"

VERSION=1.0.0
[[ "${1:-}" == "--release" ]] && VERSION="${2:?version required}"

APP=build/Pulse.app
rm -rf build && mkdir -p $APP/Contents/{MacOS,Resources}
sed "s/VERSION/$VERSION/g" Info.plist > $APP/Contents/Info.plist
cp Resources/Pulse.icns $APP/Contents/Resources/

swiftc -O -parse-as-library -swift-version 6 \
  -target arm64-apple-macos26.0 \
  Sources/*.swift -o $APP/Contents/MacOS/Pulse

codesign --force --sign - $APP

case "${1:-}" in
  --install)
    pkill -x Pulse 2>/dev/null && sleep 1 || true
    rm -rf ~/Applications/Pulse.app
    mkdir -p ~/Applications && cp -R $APP ~/Applications/
    open ~/Applications/Pulse.app
    echo "Installed ~/Applications/Pulse.app" ;;
  --release)
    ditto -c -k --keepParent $APP build/Pulse-$VERSION.zip
    shasum -a 256 build/Pulse-$VERSION.zip ;;
esac
