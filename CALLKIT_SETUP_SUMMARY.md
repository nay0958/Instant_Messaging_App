# CallKit Notification Channel Setup Summary

## ✅ Current Configuration

### 1. Notification Channel Created in App
- **Channel ID**: `callkit_incoming`
- **Channel Name**: "Incoming Calls"
- **Importance**: `Importance.max` (Maximum - enables heads-up display)
- **Sound**: Enabled
- **Vibration**: Enabled
- **Badge**: Enabled

**Location**: Created in `FirebaseMessagingHandler.initialize()` via `_createCallKitNotificationChannel()`

### 2. FCM Message Format
- **Type**: Data-only message (no `notification` key)
- **Android Priority**: `high`
- **Channel ID**: N/A (data-only messages don't use notification channels directly)

### 3. Important Notes

#### Data-Only Messages vs Notification Channels
Since we're using **data-only FCM messages** (no `notification` key):
- FCM doesn't automatically show a system notification
- The notification channel ID doesn't need to match in the FCM payload
- The channel is created for:
  - CallKit to use when showing the banner
  - Fallback local notifications if needed
  - Any native Android notifications triggered by the app

#### Why Channel ID Matching Isn't Critical
For data-only messages, Android doesn't use the channel ID from the FCM payload because:
1. There's no `notification` payload in the FCM message
2. The app processes the data and decides how to display it
3. CallKit handles its own notification display
4. If local notifications are shown, they use the channel specified in the code

### 4. Verification Checklist

✅ **Notification channel created with `Importance.max`**
- Location: `_createCallKitNotificationChannel()` method
- Called during: `FirebaseMessagingHandler.initialize()`

✅ **System Alert Window permission requested**
- Location: `_requestSystemAlertWindowPermission()` method
- Called during: `FirebaseMessagingHandler.initialize()`

✅ **Data-only FCM messages**
- Backend sends only `data` field (no `notification` key)
- Ensures background handler is called properly

### 5. If You Need to Match Channel IDs (Optional)

If you ever switch to notification + data messages (not recommended for CallKit), you would need to specify the channel ID in the FCM payload:

```javascript
// In backend/fcm.js (NOT CURRENTLY USED)
android: {
  priority: 'high',
  notification: {
    channelId: 'callkit_incoming', // Would match app channel
    sound: 'default',
    priority: 'high',
  },
}
```

**However, this is NOT recommended** because:
- Notification + data messages may not trigger background handler properly
- CallKit needs data-only messages to work correctly

### 6. Testing

To verify the channel is created, check logs during app initialization:
```
✅ CallKit notification channel created:
   Channel ID: callkit_incoming
   Importance: MAX (heads-up display enabled)
```

The channel will be visible in Android Settings > Apps > Your App > Notifications > "Incoming Calls" channel.