# How to Get Firebase Service Account Key

This key is needed for your **backend** to send push notifications to users.

## Steps:

1. **Go to Firebase Console**
   - Visit: https://console.firebase.google.com/
   - Select your project: `messaging-9db2b`

2. **Open Project Settings**
   - Click the **gear icon** ⚙️ next to "Project Overview"
   - Select **"Project settings"**

3. **Go to Service Accounts Tab**
   - Click on the **"Service accounts"** tab at the top

4. **Generate New Private Key**
   - Click the button: **"Generate new private key"**
   - A warning dialog will appear - click **"Generate key"**
   - A JSON file will be downloaded (e.g., `messaging-9db2b-firebase-adminsdk-xxxxx.json`)

5. **Place the File**
   - Rename the downloaded file to: `firebase-service-account.json`
   - Move it to: `backend/firebase-service-account.json`
   
   **Full path should be:**
   ```
   /Users/coder-mac/Desktop/18_Messaging/backend/firebase-service-account.json
   ```

6. **Restart Backend**
   - Stop your backend server (Ctrl+C)
   - Start it again: `npm start`
   - You should see: `✅ Firebase Admin SDK initialized`

## Security Note:

⚠️ **DO NOT commit this file to Git!** It's already added to `.gitignore`.

This file contains sensitive credentials - keep it secure and never share it publicly.
