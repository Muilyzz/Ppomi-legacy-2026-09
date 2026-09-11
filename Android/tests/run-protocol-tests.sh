#!/bin/sh
set -eu
ANDROID_PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_JAVA_HOME=${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}
TEST_CLASSES=$(mktemp -d)
trap 'rm -rf "$TEST_CLASSES"' EXIT
"$TEST_JAVA_HOME/bin/javac" -d "$TEST_CLASSES" \
  "$ANDROID_PROJECT/app/src/main/java/com/ppomi/androidbridge/BridgePolicy.java" \
  "$ANDROID_PROJECT/app/src/main/java/com/ppomi/androidbridge/HttpRequest.java" \
  "$ANDROID_PROJECT/app/src/main/java/com/ppomi/androidbridge/VoiceBridgePolicy.java" \
  "$ANDROID_PROJECT/app/src/main/java/com/ppomi/androidbridge/VoiceToolErrors.java" \
  "$ANDROID_PROJECT/app/src/main/java/com/ppomi/androidbridge/ProtectedActionPolicy.java" \
  "$ANDROID_PROJECT/app/src/main/java/com/ppomi/androidbridge/ExecutorOwnership.java" \
  "$ANDROID_PROJECT/app/src/main/java/com/ppomi/androidbridge/FamilyWebPackage.java" \
  "$ANDROID_PROJECT/app/src/main/java/com/ppomi/androidbridge/FamilyWebStore.java" \
  "$ANDROID_PROJECT/tests/BridgeProtocolTest.java" \
  "$ANDROID_PROJECT/tests/VoiceBridgePolicyTest.java" \
  "$ANDROID_PROJECT/tests/VoiceToolErrorsTest.java" \
  "$ANDROID_PROJECT/tests/ProtectedActionPolicyTest.java" \
  "$ANDROID_PROJECT/tests/ExecutorOwnershipTest.java" \
  "$ANDROID_PROJECT/tests/FamilyWebUpdatesTest.java"
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.ppomi.androidbridge.BridgeProtocolTest
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.ppomi.androidbridge.VoiceBridgePolicyTest
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.ppomi.androidbridge.VoiceToolErrorsTest
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.ppomi.androidbridge.ProtectedActionPolicyTest
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.ppomi.androidbridge.FamilyWebUpdatesTest "$ANDROID_PROJECT/../tests/updates"
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.ppomi.androidbridge.ExecutorOwnershipTest
