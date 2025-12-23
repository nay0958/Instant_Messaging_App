# Android Call Banner Setup - Troubleshooting Guide

## Issues Fixed

1. ✅ **Missing Theme**: Added `CallkitIncomingTheme` to `android/app/src/main/res/values/styles.xml`
2. ✅ **Background Handler**: Created top-level background message handler with `@pragma('vm:entry-point')`
3. ✅ **Permissions**: All required permissions are in AndroidManifest.xml

## Important Notes

### Background Isolate Limitation

**⚠️ Critical Issue**: `flutter_callkit_incoming` uses Flutter platform channels, which **do not work** in background isolates on Android. This means:

- ✅ **Foreground**: CallKit banner works perfectly
- ⚠️ **Background**: The plugin may not work when called from `firebaseMessagingBackgroundHandler`
- ✅ **App Opened from Notification**: When user taps notification, app comes to foreground and CallKit works

### How It Works

1. **Foreground State**: 
   - FCM message arrives → `onMessage` handler → Shows CallKit banner ✅

2. **Background/Terminated State**:
   - FCM message arrives → Android shows system notification
   - User taps notification → App opens → `onMessageOpenedApp` handler → Shows CallKit banner ✅
   - OR notification auto-opens app (if configured) → Shows CallKit banner ✅

3. **Background Handler**:
   - Currently tries to show CallKit but may fail (expected behavior)
   - Logs are added to track this

## Testing

1. **Test Foreground**:
   ```bash
   # Send FCM while app is open
   # Should see CallKit banner immediately
   ```

2. **Test Background**:
   ```bash
   # Send FCM while app is in background
   # Should see system notification
   # Tap notification → App opens → CallKit banner shows
   ```

3. **Check Logs**:
   ```bash
   adb logcat | grep -E "(flutter|CallKit|FCM|Background)"
   ```

## FCM Message Format

Your backend should send:
```json
{
  "notification": {
    "title": "Incoming Call",
    "body": "John Doe is calling you"
  },
  "data": {
    "type": "video",  // or "voice"
    "callId": "123",
    "nameCaller": "John Doe",
    "avatar": "https://...",
    "callerId": "user123",
    "from": "user123",
    "to": "user456"
  }
}
```

## Android Manifest Checklist

- ✅ `USE_FULL_SCREEN_INTENT` permission
- ✅ `FOREGROUND_SERVICE` permission
- ✅ `FOREGROUND_SERVICE_PHONE_CALL` permission
- ✅ `SYSTEM_ALERT_WINDOW` permission
- ✅ `CallkitIncomingActivity` declared
- ✅ `CallkitIncomingTheme` defined in styles.xml

## Next Steps (If Still Not Working)

1. **Check if notification is received**:
   - Look for FCM logs in logcat
   - Verify Firebase is properly configured

2. **Test with data-only message** (no notification payload):
   ```javascript
   // In backend, try sending data-only for testing
   const message = {
     data: { /* call data */ },
     // No notification field
   };
   ```

3. **Verify CallKit activity launches**:
   - Check logcat for `CallkitIncomingActivity` launch attempts
   - Look for theme-related errors

4. **Test on physical device**:
   - Some features don't work on emulators
   - Battery optimization might block notifications

5. **Check Android version**:
   - Some features require Android 8.0+ (API 26+)
   - Verify targetSdk is recent enough

## Alternative Approach

If CallKit doesn't work in background, consider:
1. Use foreground service to keep app alive during calls
2. Use high-priority notifications with heads-up display
3. Custom native Android implementation for background calls