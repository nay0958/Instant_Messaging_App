# FCM Call Notification Format Comparison

## ❌ NOT RECOMMENDED: Notification + Data Message

```javascript
const message = {
  data: {
    type: 'video',
    callId: '123',
    nameCaller: 'Aung Aung',
    // ...
  },
  android: {
    priority: 'high',
    notification: {
      channel_id: "callkit_incoming",  // Must match app channel ID
      priority: "max",
      visibility: "public"
    }
  },
  token: registrationToken
};
```

**Problems with this approach:**
- Android will show a system notification automatically
- May interfere with CallKit's custom banner
- Background handler may not be called reliably
- User sees two notifications (system + CallKit)

## ✅ RECOMMENDED: Data-Only Message (Current Implementation)

```javascript
const message = {
  data: {
    type: 'video',  // 'voice' or 'video'
    callId: '123',
    nameCaller: 'Aung Aung',
    avatar: 'https://...',
    callerId: 'user123',
    from: 'user123',
    to: 'user456',
    isVideoCall: 'true',
    kind: 'video',
  },
  token: registrationToken,
  android: {
    priority: 'high',  // High priority for immediate delivery
  },
  apns: {
    headers: {
      'apns-priority': '10',
    },
    payload: {
      aps: {
        contentAvailable: true,
        sound: 'default',
        badge: 1,
      },
    },
  },
};
```

**Benefits:**
- Background handler is called reliably
- CallKit shows custom banner without interference
- No duplicate notifications
- Full control over UI

## Important Notes

1. **Channel ID**: Only needed if using `notification` field. Since we use data-only, no channel ID needed in FCM payload.

2. **App Channel**: The `callkit_incoming` channel is created in the app for CallKit's internal use, not for FCM payload.

3. **For CallKit**: Data-only messages are the correct approach.
