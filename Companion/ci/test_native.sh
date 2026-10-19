#!/bin/bash
set -euo pipefail

mkdir -p "${RUNNER_TEMP}/CompanionReceipt"

simulator_id="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
phones = [device for devices in json.load(sys.stdin)["devices"].values() for device in devices
          if device["name"].startswith("iPhone") and device["isAvailable"]]
assert phones, "No available iPhone simulator on this runner"
phones.sort(key=lambda device: (not device["name"].startswith("iPhone 17 Pro"), device["name"]))
print(phones[0]["udid"])
')"

xcodebuild test \
  -project ios/HermesCompanion.xcodeproj \
  -scheme HermesCompanion \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${simulator_id}" \
  -derivedDataPath "${RUNNER_TEMP}/CompanionTestDerivedData" \
  -resultBundlePath "${RUNNER_TEMP}/CompanionTests.xcresult" \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -skip-testing:HermesCompanionUITests/LiveFlowUITests/testFollowUpCompletesWithAppClosedAndRestoresConversation \
  -skip-testing:HermesCompanionUITests/LiveFlowUITests/testForegroundFollowUpOpensNewResultConversation \
  -skip-testing:HermesCompanionUITests/LiveFlowUITests/testRealChatClearsAcceptedDraft \
  -skip-testing:HermesCompanionUITests/LiveFlowUITests/testInjectedNotificationOpensCanonicalResult \
  -skip-testing:HermesCompanionUITests/CompanionUITests/testRealHistoryWorkloadWhenSessionProvided \
  -skip-testing:HermesCompanionUITests/CompanionUITests/testPairingAndRealHostWhenInvitationProvided \
  -skip-testing:HermesCompanionUITests/ChatPolishUITests/testNativePhotoPickerWhenSeeded \
  -skip-testing:HermesCompanionUITests/ChatPolishUITests/testRealFileSendWhenConfigured \
  -skip-testing:HermesCompanionUITests/PerformanceFlowUITests \
  'DEVELOPMENT_TEAM=' 'CODE_SIGN_IDENTITY=-'

xcrun xcresulttool get test-results summary \
  --path "${RUNNER_TEMP}/CompanionTests.xcresult" \
  > "${RUNNER_TEMP}/CompanionReceipt/native-tests.json"
python3 - <<'PY'
import json, os
from pathlib import Path
summary = json.loads((Path(os.environ['RUNNER_TEMP']) / 'CompanionReceipt/native-tests.json').read_text())
assert summary['result'] == 'Passed', summary['result']
assert summary['passedTests'] > 0 and summary['failedTests'] == 0
assert summary['skippedTests'] == 0, 'An expected fixture or unit test was skipped'
PY
