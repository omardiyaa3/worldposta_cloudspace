#!/bin/bash
# App Store screenshots on an iOS simulator (see integration_test/store_screenshots_test.dart).
#   SHOT_TOKEN=dk_… tool/store_shots.sh <simulator-udid> <out-dir>
set -euo pipefail
UDID=$1; OUT=$2; BUNDLE=com.worldposta.cloudspace
: "${SHOT_TOKEN:?set SHOT_TOKEN}"
mkdir -p "$OUT"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
flutter test integration_test/store_screenshots_test.dart -d "$UDID" \
  --dart-define=SHOT_TOKEN="$SHOT_TOKEN" > "$OUT/test.log" 2>&1 &
PID=$!
while kill -0 $PID 2>/dev/null; do
  DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null || true)
  if [ -n "$DATA" ]; then
    for req in "$DATA"/tmp/shot_request_*; do
      [ -e "$req" ] || continue
      name=${req##*shot_request_}
      xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
      rm -f "$req"
      echo "shot $name"
    done
  fi
  sleep 0.3
done
wait $PID && echo "test passed" || { echo "test FAILED"; tail -30 "$OUT/test.log"; exit 1; }
