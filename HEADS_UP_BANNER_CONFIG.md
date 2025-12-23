# Heads-Up Banner Configuration Guide

This document summarizes all the configuration needed for incoming call heads-up banners to display properly on Android.

## 1. Notification Channel Configuration

### Channel ID: `'calls'`
- **Importance**: `Importance.max` (Required for heads-up display)
- **Sound**: Enabled
- **Vibration**: Enabled
- **Badge**: Enabled

**Location**: `lib/firebase_messaging_handler.dart`
- Created in foreground: `_createCallKitNotificationChannel()`
- Created in background: `firebaseMessagingBackgroundHandler()`

```dart
const channel = AndroidNotificationChannel(
  'calls',
  'Incoming Calls',
  description: 'High priority notifications for incoming calls',
  importance: Importance.max, // ✅ CRITICAL: Maximum importance for heads-up
  playSound: true,
  enableVibration: true,
  showBadge: true,
);
```

## 2. FCM Message Configuration

### Data-Only Message (No notification object)
- **Priority**: `'high'` (Top-level and Android level)
- **TTL**: `0` (Immediate delivery)
- **Data payload**: Includes `type: 'CALL'`, `call_id`, `caller_name`

**Location**: `backend/src/fcm.js` - `sendCallNotification()`

```javascript
const message = {
  data: fcmData, // Data-only (no notification key)
  token: user.fcmToken,
  android: {
    priority: 'high', // ✅ High priority for immediate delivery
    ttl: 0,           // ✅ Immediate delivery (no delay)
  },
};
```

## 3. AndroidManifest.xml Configuration

### MainActivity Attributes
```xml
<activity
    android:name=".MainActivity"
    android:showWhenLocked="true"      <!-- ✅ Show on locked screen -->
    android:turnScreenOn="true"        <!-- ✅ Wake screen -->
    android:showOnLockScreen="true">   <!-- ✅ Display on lock screen -->
```

### Required Permissions
```xml
<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL" />
<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
```

### CallKit Activity Configuration
```xml
<activity
    android:name="com.hiennv.flutter_callkit_incoming.CallkitIncomingActivity"
    android:showOnLockScreen="true"
    android:turnScreenOn="true"
    android:launchMode="singleTask"
    android:exported="true" />
```

## 4. Flutter CallKit Configuration

### AndroidParams
**Location**: `lib/firebase_messaging_handler.dart` - `_showCallKitIncoming()`

```dart
android: AndroidParams(
  isCustomNotification: true,  // ✅ Use custom notification UI
  isShowLogo: true,            // Show caller avatar/logo
  ringtonePath: 'system_default',
  backgroundColor: '#FFB19CD9',
  backgroundUrl: avatarUrl,    // Caller avatar as background
  actionColor: '#0955fa',
),
```

**Note**: The `flutter_callkit_incoming` package automatically uses the highest priority notification channel available. Since we created the 'calls' channel with `Importance.max`, it will be used automatically.

## 5. Runtime Permissions

### System Alert Window Permission
- **Purpose**: Allows drawing over other apps (required for full-screen call banner)
- **Request Location**: `lib/firebase_messaging_handler.dart` - `_requestSystemAlertWindowPermission()`
- **Status Check**: `hasSystemAlertWindowPermission()`

### Notification Permission
- Requested via `FirebaseMessaging.requestPermission()`
- Required for Android 13+ (POST_NOTIFICATIONS permission)

## 6. Verification Checklist

✅ Notification channel 'calls' created with `Importance.max`  
✅ FCM message sent with `priority: 'high'` and `ttl: 0`  
✅ Data-only FCM message (no notification object)  
✅ MainActivity has `showWhenLocked`, `turnScreenOn`, `showOnLockScreen`  
✅ All required permissions declared in AndroidManifest.xml  
✅ System Alert Window permission requested at runtime  
✅ CallKit AndroidParams configured with `isCustomNotification: true`  

## 7. Troubleshooting

### Banner Not Showing?

1. **Check Channel Importance**
   - Verify channel 'calls' has `Importance.max`
   - Check logs: `✅ CallKit notification channel created: Channel ID: calls, Importance: MAX`

2. **Check FCM Message Priority**
   - Verify FCM payload has `android: { priority: 'high', ttl: 0 }`
   - Ensure it's a data-only message (no notification object)

3. **Check Permissions**
   - System Alert Window: Settings → Apps → Your App → Display over other apps
   - Notification permission: Settings → Apps → Your App → Notifications

4. **Check App State**
   - Foreground: Banner should show immediately via `onMessage`
   - Background: Banner shown via background handler or notification tap
   - Terminated: App opens via notification, then banner shows

5. **Check Logs**
   - Look for: `📞 Call notification detected in background handler`
   - Look for: `✅ CallKit incoming call banner shown`
   - Check for errors in background handler

### Banner Shows But Doesn't Wake Screen?

- Verify `android:turnScreenOn="true"` in MainActivity
- Verify `android:showWhenLocked="true"` in MainActivity
- Check device settings: Some devices have "Wake on notification" settings

### Banner Shows But User Can't Interact?

- Verify System Alert Window permission is granted
- Verify `FOREGROUND_SERVICE_PHONE_CALL` permission is declared
- Check if device has battery optimization enabled (disable for your app)

## 8. Android Version Considerations

- **Android 8.0+ (API 26+)**: Notification channels required (✅ Configured)
- **Android 10+ (API 29+)**: Full-screen intent requires permission (✅ Configured)
- **Android 13+ (API 33+)**: Runtime notification permission required (✅ Requested)
