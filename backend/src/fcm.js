import admin from 'firebase-admin';
import User from './models/User.js';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { readFileSync, existsSync } from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Initialize Firebase Admin SDK
let fcmInitialized = false;

function initializeFCM() {
  if (fcmInitialized) {
    return true;
  }

  try {
    // Try to load service account key
    const serviceAccountPath = join(__dirname, '../firebase-service-account.json');
    
    if (!existsSync(serviceAccountPath)) {
      console.log('⚠️ Firebase service account key not found at:', serviceAccountPath);
      console.log('💡 FCM push notifications will not work');
      console.log('💡 To enable FCM:');
      console.log('   1. Download service account key from Firebase Console');
      console.log('   2. Place it at: backend/firebase-service-account.json');
      return false;
    }

    const serviceAccount = JSON.parse(
      readFileSync(serviceAccountPath, 'utf8')
    );

    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
    });

    fcmInitialized = true;
    console.log('✅ Firebase Admin SDK initialized');
    return true;
  } catch (error) {
    console.error('❌ Error initializing Firebase Admin SDK:', error.message);
    console.log('💡 FCM push notifications will not work');
    return false;
  }
}

// Export initialization function for server startup
export function initializeFirebaseOnStartup() {
  return initializeFCM();
}

/**
 * Send FCM notification to a user
 * @param {string} userId - User ID to send notification to
 * @param {Object} notification - Notification data
 * @param {string} notification.title - Notification title
 * @param {string} notification.body - Notification body
 * @param {Object} data - Additional data payload
 * @returns {Promise<boolean>} - Returns true if sent successfully
 */
export async function sendFCMNotification(userId, notification, data = {}) {
  if (!initializeFCM()) {
    return false;
  }

  try {
    // Get user's FCM token
    const user = await User.findById(userId);
    if (!user || !user.fcmToken) {
      console.log(`⚠️ User ${userId} has no FCM token - skipping notification`);
      return false;
    }

    // FCM has reserved keys that cannot be used in data payload
    // Reserved keys: from, notification, message, gcm, google, collapse_key, etc.
    // We need to prefix or rename these keys
    const fcmData = {};
    for (const [key, value] of Object.entries(data)) {
      // Rename reserved keys
      if (key === 'from') {
        fcmData.senderId = String(value);
      } else if (key === 'to') {
        fcmData.recipientId = String(value);
      } else {
        fcmData[key] = String(value);
      }
    }
    // Ensure type is always present
    fcmData.type = (data.type || 'message').toString();

    // Determine if this is a call notification
    const isCallNotification = fcmData.type === 'voice' || fcmData.type === 'video';
    
    const message = {
      notification: {
        title: notification.title || 'New Message',
        body: notification.body || 'You have a new message',
      },
      data: fcmData,
      token: user.fcmToken,
      android: {
        priority: isCallNotification ? 'high' : 'high',
        notification: {
          channelId: isCallNotification ? 'messages_v3' : 'messages_v3',
          sound: 'default',
          priority: isCallNotification ? 'high' : 'default',
          visibility: isCallNotification ? 'public' : 'private',
          defaultSound: true,
          defaultVibrateTimings: isCallNotification,
        },
      },
      apns: {
        payload: {
          aps: {
            sound: 'default',
            badge: 1,
            ...(isCallNotification && { contentAvailable: true }),
          },
        },
      },
    };

    const response = await admin.messaging().send(message);
    console.log(`✅ FCM notification sent to user ${userId}:`, response);
    return true;
  } catch (error) {
    if (error.code === 'messaging/invalid-registration-token' || 
        error.code === 'messaging/registration-token-not-registered') {
      // Token is invalid - remove it from user
      console.log(`⚠️ Invalid FCM token for user ${userId} - removing token`);
      await User.updateOne({ _id: userId }, { $set: { fcmToken: null } });
    } else {
      console.error(`❌ Error sending FCM notification to user ${userId}:`, error.message);
    }
    return false;
  }
}

/**
 * Send FCM notification for a new message
 * @param {string} recipientId - User ID of message recipient
 * @param {Object} messageData - Message data
 * @param {string} senderName - Name of message sender
 * @returns {Promise<boolean>}
 */
export async function sendMessageNotification(recipientId, messageData, senderName) {
  const notification = {
    title: senderName || 'New Message',
    body: messageData.text || 'You have a new message',
  };

  const data = {
    type: 'message',
    messageId: String(messageData._id || messageData.id),
    conversationId: String(messageData.conversationId),
    // Note: 'from' and 'to' will be renamed to 'senderId' and 'recipientId' in sendFCMNotification
    // to avoid FCM reserved key conflicts
    from: String(messageData.from),
    to: String(messageData.to),
    text: messageData.text || '',
    ...(messageData.fileUrl && { fileUrl: String(messageData.fileUrl) }),
    ...(messageData.fileName && { fileName: String(messageData.fileName) }),
    ...(messageData.fileType && { fileType: String(messageData.fileType) }),
    ...(messageData.callActivity && { callActivity: 'true' }),
  };

  return await sendFCMNotification(recipientId, notification, data);
}

/**
 * Send FCM notification for an incoming call
 * @param {string} recipientId - User ID of call recipient
 * @param {Object} callData - Call data
 * @param {string} callerName - Name of caller
 * @returns {Promise<boolean>}
 */
/**
 * Send FCM notification for an incoming call
 * IMPORTANT: Sends DATA-ONLY message (no notification key) to trigger CallKit properly
 * @param {string} recipientId - User ID of call recipient
 * @param {Object} callData - Call data
 * @param {string} callerName - Name of caller
 * @returns {Promise<boolean>}
 */
export async function sendCallNotification(recipientId, callData, callerName) {
  console.log(`📱 [sendCallNotification] Called with:`, {
    recipientId,
    callId: callData.callId,
    from: callData.from,
    to: callData.to,
    kind: callData.kind,
    callerName
  });
  
  if (!initializeFCM()) {
    console.log(`❌ [sendCallNotification] Firebase Admin SDK not initialized`);
    return false;
  }
  console.log(`✅ [sendCallNotification] Firebase Admin SDK initialized`);

  try {
    // Get caller's profile to fetch avatar URL
    let avatarUrl = '';
    try {
      const caller = await User.findById(callData.from).select('avatarUrl avatar profilePicture').lean();
      if (caller) {
        avatarUrl = caller.avatarUrl || caller.avatar || caller.profilePicture || '';
      }
    } catch (error) {
      console.log('Could not fetch caller avatar:', error.message);
    }

    // Determine call type: 'voice' or 'video'
    const callType = callData.kind === 'video' || callData.isVideoCall === true ? 'video' : 'voice';
    
    // Get user's FCM token
    const user = await User.findById(recipientId);
    if (!user) {
      console.log(`❌ [sendCallNotification] User ${recipientId} not found`);
      return false;
    }
    if (!user.fcmToken) {
      console.log(`⚠️ [sendCallNotification] User ${recipientId} has no FCM token - skipping call notification`);
      return false;
    }
    console.log(`✅ [sendCallNotification] User ${recipientId} found, FCM token exists`);

    // Prepare data payload - ALL values must be strings for FCM
    // CRITICAL: This is a data-only message - NO notification key should be present
    // This ensures the background handler is triggered in Android
    // NOTE: 'from' and 'to' are reserved FCM keys - use 'callerId' and 'recipientId' instead
    const callTimestamp = callData.timestamp || Date.now(); // Use provided timestamp or current time
    const fcmData = {
      type: 'CALL', // ✅ REQUIRED - Must be exactly 'CALL' for Flutter to recognize it
      call_id: String(callData.callId || callData._id || ''), // REQUIRED - call ID
      caller_name: String(callerName || 'Unknown Caller'), // REQUIRED - caller name for CallKit
      // Additional fields for CallKit display and compatibility
      avatar: String(avatarUrl || ''), // Avatar URL for CallKit
      callerId: String(callData.from), // Caller user ID (use callerId instead of 'from' - FCM reserved key)
      recipientId: String(callData.to), // Recipient user ID (use recipientId instead of 'to' - FCM reserved key)
      isVideoCall: String(callData.isVideoCall === true || callType === 'video'),
      kind: String(callData.kind || callType),
      timestamp: String(callTimestamp), // Timestamp when call was initiated (for expiration check)
      ...(callData.sdp && { sdp: JSON.stringify(callData.sdp) }), // SDP offer if available
    };

    // CRITICAL: Send DATA-ONLY message for background handler
    // On Android, data-only messages trigger background handler when app is in background
    // The background handler will show CallKit banner
    const message = {
      // ✅ DATA-ONLY: Only 'data' key, NO 'notification' key
      // This ensures background handler is called and CallKit can show banner
      data: fcmData,
      token: user.fcmToken,
      android: {
        priority: 'high', // High priority for immediate delivery
        // TTL:0 = ချက်ချင်း deliver လုပ်ရန် (delay မရှိ)
        // TTL:0 means immediate delivery - message will not be queued or delayed
        // If device is offline, message is dropped (not stored for later)
        ttl: 0, // TTL of 0 ensures immediate delivery (no delay)
        // Direct boot - ensures delivery even if device is in doze mode
        directBootOk: true,
      },
      apns: {
        headers: {
          'apns-priority': '10', // High priority for iOS
        },
        payload: {
          aps: {
            contentAvailable: true, // Enable background processing
            sound: 'default',
            badge: 1,
          },
        },
      },
    };

    const response = await admin.messaging().send(message);
    console.log(`✅ Call notification (data-only) sent to user ${recipientId}:`, response);
    console.log(`📱 FCM Payload sent:`, JSON.stringify({
      type: fcmData.type,
      call_id: fcmData.call_id,
      caller_name: fcmData.caller_name,
      has_notification_key: false, // ✅ Data-only message
    }, null, 2));
    return true;
  } catch (error) {
    if (error.code === 'messaging/invalid-registration-token' || 
        error.code === 'messaging/registration-token-not-registered') {
      console.log(`⚠️ Invalid FCM token for user ${recipientId} - removing token`);
      await User.updateOne({ _id: recipientId }, { $set: { fcmToken: null } });
    } else {
      console.error(`❌ Error sending call notification to user ${recipientId}:`, error.message);
    }
    return false;
  }
}

/**
 * Send FCM notification when call is ended/cancelled
 * This is critical when the receiver is in background and socket is disconnected
 * @param {string} recipientId - User ID of call recipient
 * @param {string} callId - Call ID that was ended
 * @param {string} callerName - Name of caller who ended the call
 * @param {number} timestamp - Timestamp when call was ended
 * @returns {Promise<boolean>}
 */
export async function sendCallEndedNotification(recipientId, callId, callerName, timestamp) {
  console.log(`📱 [sendCallEndedNotification] Called with:`, {
    recipientId,
    callId,
    callerName,
    timestamp
  });
  
  if (!initializeFCM()) {
    console.log(`❌ [sendCallEndedNotification] Firebase Admin SDK not initialized`);
    return false;
  }

  try {
    // Get user's FCM token
    const user = await User.findById(recipientId);
    if (!user) {
      console.log(`❌ [sendCallEndedNotification] User ${recipientId} not found`);
      return false;
    }
    if (!user.fcmToken) {
      console.log(`⚠️ [sendCallEndedNotification] User ${recipientId} has no FCM token - skipping`);
      return false;
    }

    // Prepare data payload - DATA-ONLY message to trigger background handler
    // Use CANCEL type to indicate call was cancelled/ended
    const fcmData = {
      type: 'CANCEL', // CANCEL signal - call was cancelled/ended by caller
      call_id: String(callId),
      caller_name: String(callerName || 'Unknown Caller'),
      action: 'dismiss', // Action to dismiss CallKit UI
      timestamp: String(timestamp || Date.now()), // Timestamp when call ended
      reason: 'caller_hung_up', // Reason for cancellation
    };

    // Send DATA-ONLY message (no notification key) to trigger background handler
    const message = {
      data: fcmData,
      token: user.fcmToken,
      android: {
        priority: 'high',
        ttl: 0, // Immediate delivery, no queuing
        directBootOk: true,
      },
      apns: {
        headers: {
          'apns-priority': '10', // High priority for iOS
        },
        payload: {
          aps: {
            contentAvailable: true, // Enable background processing
          },
        },
      },
    };

    const response = await admin.messaging().send(message);
    console.log(`✅ Call ended notification sent to user ${recipientId}:`, response);
    return true;
  } catch (error) {
    if (error.code === 'messaging/invalid-registration-token' || 
        error.code === 'messaging/registration-token-not-registered') {
      console.log(`⚠️ Invalid FCM token for user ${recipientId} - removing token`);
      await User.updateOne({ _id: recipientId }, { $set: { fcmToken: null } });
    } else {
      console.error(`❌ Error sending call ended notification to user ${recipientId}:`, error.message);
    }
    return false;
  }
}

/**
 * @deprecated Use sendCallEndedNotification instead
 * Kept for backward compatibility
 */
export async function sendCallCancelledNotification(recipientId, callId, callerName) {
  return await sendCallEndedNotification(recipientId, callId, callerName, Date.now());
}
