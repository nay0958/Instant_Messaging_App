# Firebase Cloud Messaging (FCM) Setup Guide

This guide will help you set up Firebase Cloud Messaging for your messaging app so that messages are delivered even when the app is in the background or terminated.

## Step 1: Create Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Click **"Add project"** or select an existing project
3. Enter your project name (e.g., "Messaging App")
4. Follow the setup wizard (disable Google Analytics if you don't need it)
5. Click **"Create project"**

## Step 2: Add Android App to Firebase

1. In Firebase Console, click the **Android icon** (or "Add app" → Android)
2. Enter your Android package name: `com.study.messaging`
   - You can find this in `android/app/build.gradle.kts` under `applicationId`
3. Enter app nickname (optional): "Messaging App Android"
4. Enter debug signing certificate SHA-1 (optional for now)
5. Click **"Register app"**

## Step 3: Download google-services.json

1. After registering the app, Firebase will generate a `google-services.json` file
2. **Download** the `google-services.json` file
3. **Place it** in: `android/app/google-services.json`
   ```
   android/app/google-services.json
   ```

## Step 4: Configure Android Build Files

The build files have been automatically configured with the Google Services plugin. The configuration is already in place:

- ✅ `android/settings.gradle.kts` - Google Services plugin added
- ✅ `android/app/build.gradle.kts` - Google Services plugin applied

No manual configuration needed!

## Step 5: Get FCM Server Key (for Backend)

1. In Firebase Console, go to **Project Settings** (gear icon)
2. Click on **"Cloud Messaging"** tab
3. Under **"Cloud Messaging API (Legacy)"**, you'll see:
   - **Server key** (for sending notifications)
   - **Sender ID** (for client apps)

4. **Copy the Server key** - you'll need this for your backend

## Step 6: Set Up Backend to Send FCM Notifications

### 6.1 Install firebase-admin in Backend

```bash
cd backend
npm install firebase-admin
```

### 6.2 Download Firebase Admin SDK Service Account Key

1. In Firebase Console → **Project Settings** → **Service Accounts**
2. Click **"Generate new private key"**
3. Download the JSON file (e.g., `firebase-service-account.json`)
4. **Place it** in: `backend/firebase-service-account.json`
5. **Add to `.gitignore`**:
   ```
   backend/firebase-service-account.json
   ```

### 6.3 Update Backend to Send FCM Notifications

The backend needs to send FCM notifications when:
- A message is sent and the recipient's socket is disconnected
- A call is initiated and the recipient's socket is disconnected

I'll create a helper file for this.

## Step 7: Rebuild the App

After adding `google-services.json`:

```bash
cd android
./gradlew clean
cd ..
flutter clean
flutter pub get
flutter run
```

## Step 8: Test FCM

1. **Get FCM Token**: When the app starts, check logs for:
   ```
   ✅ FCM token obtained: [token]
   ✅ FCM token updated to backend
   ```

2. **Send Test Notification**:
   - Use Firebase Console → Cloud Messaging → Send test message
   - Or use the backend API (after Step 6 is complete)

## Troubleshooting

### App crashes on startup
- Check that `google-services.json` is in `android/app/`
- Verify package name matches in Firebase Console and `build.gradle.kts`

### FCM token not generated
- Check Firebase initialization logs
- Verify `google-services.json` is correct
- Check internet connection

### Notifications not received
- Verify FCM token is saved in backend
- Check backend is sending notifications correctly
- Verify notification permissions are granted

## Step 9: Set Up Backend to Send FCM Notifications

### 9.1 Install firebase-admin

```bash
cd backend
npm install firebase-admin
```

### 9.2 Download Firebase Service Account Key

1. In Firebase Console → **Project Settings** → **Service Accounts**
2. Click **"Generate new private key"**
3. Download the JSON file (e.g., `firebase-service-account.json`)
4. **Place it** in: `backend/firebase-service-account.json`
5. **Add to `.gitignore`**:
   ```
   backend/firebase-service-account.json
   ```

### 9.3 Backend is Already Configured

The backend code has already been updated to:
- Import FCM helper functions
- Check if recipient is connected via socket
- Send FCM notification if recipient is not connected

The FCM helper file (`backend/src/fcm.js`) is already created and will:
- Initialize Firebase Admin SDK
- Send FCM notifications for messages
- Send FCM notifications for calls
- Handle invalid tokens automatically

### 9.4 Test Backend FCM

1. Start your backend server
2. Check logs for: `✅ Firebase Admin SDK initialized`
3. If you see `⚠️ Firebase service account key not found`, make sure you completed Step 9.2

## How It Works

1. **When a message is sent**:
   - Backend checks if recipient is connected via Socket.io
   - If connected: Message is delivered via Socket.io (real-time)
   - If NOT connected: Backend sends FCM push notification

2. **When app receives FCM notification**:
   - If app is in foreground: Shows local notification and processes message
   - If app is in background: Shows notification, processes message when opened
   - If app is terminated: Shows notification, processes message when opened

3. **FCM Token Management**:
   - App automatically gets FCM token on startup
   - App sends token to backend via `PATCH /users/me`
   - Backend stores token in user's profile
   - Backend uses token to send notifications

## Troubleshooting

### Backend: "Firebase service account key not found"
- Make sure `firebase-service-account.json` is in `backend/` directory
- Check file permissions

### Backend: "FCM notification sent" but no notification received
- Check FCM token is saved in database
- Verify token is valid (check Firebase Console)
- Check app has notification permissions

### App: FCM token not generated
- Verify `google-services.json` is correct
- Check Firebase initialization logs
- Rebuild app after adding `google-services.json`
