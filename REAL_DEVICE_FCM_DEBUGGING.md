# Real Device FCM & Call Banner Debugging Guide

## ပြဿနာများ (Common Issues)

Emulator မှာ အဆင်ပြေပေမယ့် Real Device မှာ FCM နဲ့ Call Banner မရဘူးဆိုရင် အောက်ပါ အချက်တွေကို စစ်ဆေးပါ:

### 1. FCM Token မရခြင်း (FCM Token Not Retrieved)

**လက္ခဏာများ:**
- Logs မှာ `⚠️ FCM Token is NULL` ပေါ်နေတယ်
- Backend ကို FCM token မပို့နိုင်ဘူး

**ဖြေရှင်းနည်းများ:**

1. **Google Play Services စစ်ဆေးပါ:**
   ```
   Settings → Apps → Google Play Services
   - Update လုပ်ထားရမယ်
   - Storage → Clear Cache (if needed)
   ```

2. **Internet Connection စစ်ဆေးပါ:**
   - WiFi သို့ Mobile Data ဖွင့်ထားရမယ်
   - Firebase servers ကို reachable ဖြစ်ရမယ်

3. **Notification Permission ပေးထားရမယ်:**
   ```
   Settings → Apps → Your App → Notifications
   - Allow notifications ဖွင့်ထားရမယ်
   ```

4. **google-services.json စစ်ဆေးပါ:**
   - `android/app/google-services.json` ရှိရမယ်
   - Firebase project နဲ့ match ဖြစ်ရမယ်
   - App rebuild လုပ်ရမယ် (hot reload မလုံလောက်ဘူး)

### 2. Background Handler မအလုပ်လုပ်ခြင်း (Background Handler Not Working)

**လက္ခဏာများ:**
- App background မှာ call banner မပေါ်ဘူး
- Logs မှာ background handler မခေါ်ဘူး

**ဖြေရှင်းနည်းများ:**

1. **Battery Optimization ပိတ်ထားရမယ် (CRITICAL!):**
   ```
   Settings → Apps → Your App → Battery
   - "Unrestricted" သို့ "Don't optimize" ရွေးပါ
   - ဒါမှမဟုတ် Settings → Battery → Battery Optimization → Your App → Don't optimize
   ```
   
   **Code မှာ auto-request:**
   - App က automatic အနေနဲ့ battery optimization exemption request လုပ်တယ်
   - User က allow လုပ်ပေးရမယ်

2. **Doze Mode စစ်ဆေးပါ:**
   - Device screen off ဖြစ်နေရင် Doze mode ဖြစ်နိုင်တယ်
   - Test လုပ်တဲ့အခါ screen on ထားပြီး test လုပ်ပါ
   - Settings → Battery → Adaptive Battery ပိတ်ထားကြည့်ပါ

3. **Background Restrictions စစ်ဆေးပါ:**
   ```
   Settings → Apps → Your App → Battery → Background restriction
   - Background activity ဖွင့်ထားရမယ်
   ```

4. **System Alert Window Permission:**
   ```
   Settings → Apps → Your App → Display over other apps
   - Allow လုပ်ထားရမယ်
   ```
   - App က automatic request လုပ်တယ်

### 3. Call Banner မပေါ်ခြင်း (Call Banner Not Showing)

**လက္ခဏာများ:**
- FCM message ရတယ် (logs မှာ ပေါ်တယ်)
- ဒါပေမယ့် CallKit banner မပေါ်ဘူး

**ဖြေရှင်းနည်းများ:**

1. **Notification Channel စစ်ဆေးပါ:**
   - Logs မှာ `✅ Created notification channel "calls"` ပေါ်ရမယ်
   - Channel importance `MAX` ဖြစ်ရမယ်

2. **Full Screen Intent Permission:**
   - AndroidManifest.xml မှာ `USE_FULL_SCREEN_INTENT` permission ရှိရမယ်
   - Android 10+ မှာ runtime permission လိုတယ်

3. **CallKit Activity Configuration:**
   - AndroidManifest.xml မှာ CallkitIncomingActivity properly configured ဖြစ်ရမယ်
   - `showWhenLocked="true"` နဲ့ `turnScreenOn="true"` ရှိရမယ်

4. **Background Handler Execution:**
   - Logs မှာ `🚀 BACKGROUND HANDLER CALLED` ပေါ်ရမယ်
   - မပေါ်ရင် battery optimization ပိတ်ထားတာဖြစ်နိုင်တယ်

### 4. Network Issues (Real Device)

**လက္ခဏာများ:**
- Emulator မှာ အဆင်ပြေပေမယ့် real device မှာ backend ကို reach မလုပ်နိုင်ဘူး

**ဖြေရှင်းနည်းများ:**

1. **API Base URL စစ်ဆေးပါ:**
   - Real device မှာ `localhost` သုံးလို့မရဘူး
   - Computer's LAN IP address သုံးရမယ်
   - `lib/config/app_config.dart` မှာ `serverIpAddress` ထားရမယ်

2. **Firewall စစ်ဆေးပါ:**
   - Computer firewall က port 3000 (or your backend port) ကို allow လုပ်ထားရမယ်
   - Real device က same WiFi network မှာ ရှိရမယ်

3. **Backend Server Running:**
   - Backend server က running ဖြစ်နေရမယ်
   - Real device က reachable ဖြစ်ရမယ်

## Diagnostic Function သုံးပြီး စစ်ဆေးခြင်း

App ထဲမှာ diagnostic function ကို call လုပ်ပြီး စစ်ဆေးနိုင်တယ်:

```dart
// Anywhere in your code
final diagnostics = await FirebaseMessagingHandler.diagnoseFCMIssues();
print('FCM Diagnostics: $diagnostics');
```

ဒါက အောက်ပါ အချက်တွေကို check လုပ်ပေးတယ်:
- Firebase initialization
- FCM token availability
- Notification permissions
- System Alert Window permission
- Battery optimization exemption
- Notification channel creation

## Testing Steps for Real Device

1. **Initial Setup:**
   ```bash
   # Rebuild app (not hot reload)
   flutter clean
   flutter pub get
   flutter run --release  # Release mode မှာ test လုပ်ပါ
   ```

2. **Check Logs:**
   ```bash
   # Real device logs ကြည့်ရန်
   adb logcat | grep -E "FCM|CallKit|BACKGROUND"
   ```

3. **Test FCM Token:**
   - App ဖွင့်ပြီး logs မှာ FCM token ရှိမရှိ စစ်ဆေးပါ
   - Backend database မှာ user's fcmToken field ကို check လုပ်ပါ

4. **Test Background Handler:**
   - App ကို background ထည့်ပါ (home button နှိပ်ပါ)
   - Backend က call notification ပို့ပါ
   - Logs မှာ `🚀 BACKGROUND HANDLER CALLED` ပေါ်ရမယ်
   - Call banner ပေါ်ရမယ်

5. **Test Permissions:**
   - Settings → Apps → Your App → Permissions
   - All required permissions granted ဖြစ်ရမယ်
   - Battery optimization exempted ဖြစ်ရမယ်

## Common Real Device Issues Summary

| Issue | Symptom | Solution |
|-------|---------|----------|
| FCM Token NULL | No token in logs | Update Google Play Services, check internet |
| Background handler not called | No logs when app in background | Disable battery optimization |
| Call banner not showing | FCM received but no UI | Check System Alert Window permission |
| Network error | Can't reach backend | Use LAN IP instead of localhost |
| Doze mode | Handler delayed | Test with screen on, disable adaptive battery |

## Quick Fix Checklist

- [ ] Google Play Services updated
- [ ] Internet connection active
- [ ] Notification permission granted
- [ ] Battery optimization disabled for your app
- [ ] System Alert Window permission granted
- [ ] Backend server running and reachable
- [ ] API base URL uses LAN IP (not localhost)
- [ ] App rebuilt (not hot reload)
- [ ] Testing in release mode

## Additional Notes

- **Release Mode Testing:** Always test FCM in release mode (`flutter run --release`) because debug mode may have different behavior
- **Battery Optimization:** This is the #1 cause of FCM issues on real devices. Always disable it for your app.
- **Network:** Real devices cannot use `localhost`. Always use your computer's LAN IP address.
- **Google Play Services:** FCM requires Google Play Services. Make sure it's installed and updated.

## Getting Help

If issues persist after checking all above:

1. Run diagnostic function and share results
2. Check `adb logcat` for detailed error messages
3. Verify backend is sending correct FCM payload (data-only, no notification key)
4. Check Firebase Console → Cloud Messaging → Delivery reports

