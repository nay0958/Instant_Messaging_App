# Testing FCM Background Messages

## Prerequisites

1. **Firebase Setup**:
   - Create a Firebase project at https://console.firebase.google.com/
   - Add `google-services.json` to `android/app/`
   - Add `GoogleService-Info.plist` to `ios/Runner/`
   - Rebuild the app

2. **Get FCM Token**:
   - Run the app and check logs for: `✅ FCM Token: <token>`
   - Copy this token for testing

## Testing Methods

### Method 1: Using Firebase Console

1. Go to Firebase Console → Cloud Messaging
2. Click "Send test message"
3. Enter the FCM token
4. Use this payload:
```json
{
  "notification": {
    "title": "Test Message",
    "body": "This is a test message"
  },
  "data": {
    "type": "message",
    "from": "sender_user_id",
    "to": "receiver_user_id",
    "messageId": "test_msg_123",
    "text": "Hello from FCM!",
    "conversationId": "conv_123"
  }
}
```

### Method 2: Using cURL

```bash
curl -X POST https://fcm.googleapis.com/v1/projects/YOUR_PROJECT_ID/messages:send \
  -H "Authorization: Bearer YOUR_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "message": {
      "token": "USER_FCM_TOKEN",
      "notification": {
        "title": "Test Message",
        "body": "This is a test message"
      },
      "data": {
        "type": "message",
        "from": "sender_user_id",
        "to": "receiver_user_id",
        "messageId": "test_msg_123",
        "text": "Hello from FCM!",
        "conversationId": "conv_123"
      }
    }
  }'
```

### Method 3: Using Postman

1. Create a POST request to: `https://fcm.googleapis.com/v1/projects/YOUR_PROJECT_ID/messages:send`
2. Add header: `Authorization: Bearer YOUR_SERVER_KEY`
3. Add header: `Content-Type: application/json`
4. Use the same payload as Method 2

## Testing Scenarios

### Scenario 1: App in Foreground (Socket Connected)
1. Open the app
2. Verify socket is connected (check logs)
3. Send FCM message
4. **Expected**: Message should be ignored (socket handles it)

### Scenario 2: App in Background (Socket Disconnected)
1. Open the app
2. Press Home button (app goes to background)
3. Wait for socket to disconnect (check logs)
4. Send FCM message
5. **Expected**: 
   - Local notification appears
   - Message is processed when app reopens
   - Message appears in chat

### Scenario 3: App Terminated
1. Force close the app
2. Send FCM message
3. **Expected**: 
   - Local notification appears
   - Tapping notification opens app
   - Message is processed

### Scenario 4: Socket Disconnected (Manual Test)
1. Open the app
2. Disconnect from network or stop backend server
3. Send FCM message
4. **Expected**: 
   - FCM message is received
   - Converted to socket format
   - Processed by message handlers

## Checking Logs

Look for these log messages:

**FCM Token Registration**:
- `✅ FCM Token: <token>`
- `✅ FCM token updated to backend successfully`

**FCM Message Received**:
- `📱 Foreground message received: <messageId>`
- `📨 FCM message converted: <messageId>`
- `✅ FCM message processed and emitted as socket message`

**Background Messages**:
- `🔔 Background message received: <messageId>`
- `✅ Local notification shown: <title> - <body>`

## Troubleshooting

1. **No FCM Token**:
   - Check Firebase is initialized
   - Check `google-services.json` is in correct location
   - Rebuild the app

2. **Messages Not Received**:
   - Verify FCM token is sent to backend
   - Check backend has correct FCM token
   - Verify notification permissions are granted

3. **Socket Not Reconnecting**:
   - Check network connection
   - Verify backend server is running
   - Check Android battery optimization settings
