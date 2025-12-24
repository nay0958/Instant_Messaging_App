// lib/home_page.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:characters/characters.dart';
import 'package:study1/call_manager.dart';
import 'package:study1/call_signal.dart';
import 'package:study1/main.dart';

import 'profile.dart';
import 'api.dart';
import 'auth_store.dart';
import 'socket_service.dart';
import 'chat_page.dart';
import 'notifications.dart';
import 'foreground_chat.dart';
import 'login_page.dart';
import 'call_history_screen.dart';
import 'widgets/avatar_with_status.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'background_service.dart';
import 'firebase_messaging_handler.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  Map<String, dynamic>? me;
  String? _token;

  int _tabIndex = 0;

  bool loadingProfile = true;
  bool loadingActive = true;
  bool loadingPending = true;
  bool loadingCallHistory = false;
  String? activeError;
  String? pendingError;

  List<_Row> activeRows = [];
  List<_Row> pendingRows = [];
  Map<String, dynamic> idMap = {};

  final Map<String, String> _lastTextByPeer = {};
  final Map<String, String> _lastFromByPeer = {};

  final Map<String, bool> _deliveredLastByPeer = {};
  final Map<String, bool> _readLastByPeer = {};

  final Map<String, int> _unreadByPeer = {};
  final Map<String, bool> _onlineByUser = {};
  final Map<String, bool> _stickyDoubleByPeer = {};

  // Contact discovery
  List<Map<String, dynamic>> _contactsOnApp = [];
  bool _loadingContacts = false;
  String? _contactsError;

  final TextEditingController _friendsSearchCtrl = TextEditingController();
  String _friendsQuery = '';
  final TextEditingController _chatSearchCtrl = TextEditingController();
  String _chatQuery = '';
  final TextEditingController _callSearchCtrl = TextEditingController();
  String _callQuery = '';
  
  Timer? _connectionMonitorTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connectSocket();
    _boot();
    SocketService.I.off(
      'call:incoming',
      onIncomingCall,
    ); // prevent double handlers
    SocketService.I.on('call:incoming', onIncomingCall); // register once
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectionMonitorTimer?.cancel();
    // Stop background service when home page is disposed
    BackgroundService.instance.stop();
    _chatSearchCtrl.dispose();
    _friendsSearchCtrl.dispose();
    _callSearchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.resumed:
        debugPrint('App resumed - stopping background service and reconnecting socket');
        // Stop background service when app comes to foreground
        BackgroundService.instance.stop();
        // Reconnect socket if disconnected (now that app is in foreground, network is available)
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && !SocketService.I.isConnected) {
            debugPrint('Socket.io disconnected, reconnecting now that app is in foreground...');
            _connectSocket();
          } else if (mounted) {
            debugPrint('Socket.io is connected');
          }
        });
        break;
      case AppLifecycleState.paused:
        debugPrint('App paused - starting background service');
        // Start background service (FCM will handle messages when socket is disconnected)
        BackgroundService.instance.start();
        // Note: Android will disconnect socket in background - this is normal
        // FCM push notifications will handle messages when socket is disconnected
        debugPrint('💡 Socket may disconnect in background (normal Android behavior)');
        debugPrint('💡 FCM will handle messages when socket is disconnected');
        break;
      case AppLifecycleState.inactive:
        // Inactive is a transitional state that occurs briefly when:
        // - App is going to background (resumed -> inactive -> paused)
        // - App is coming to foreground (paused -> inactive -> resumed)
        // - System overlays appear (notification drawer, incoming call, etc.)
        // This is normal Android behavior - the app is transitioning between states
        debugPrint('App inactive (transitioning state - normal when going to/from background)');
        break;
      case AppLifecycleState.detached:
        debugPrint('App detached');
        break;
      case AppLifecycleState.hidden:
        debugPrint('App hidden');
        break;
    }
  }

  int _ts(String? s) => DateTime.tryParse(s ?? '')?.millisecondsSinceEpoch ?? 0;

  Future<void> _boot() async {
    try {
      final t = await AuthStore.getToken();
      if (t == null) return _toLogin();
      _token = t;

      await Noti.init();

      final r = await http
          .get(
            Uri.parse('$apiBase/auth/me'),
            headers: {'Authorization': 'Bearer $t'},
          )
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) {
        await AuthStore.clear();
        return _toLogin();
      }
      me = Map<String, dynamic>.from(jsonDecode(r.body)['user']);
      setState(() {
        loadingProfile = false;
        activeError = null;
        pendingError = null;
      });

      // ✅ delivered → sender UI ပြောင်း (✓✓ grey)
      SocketService.I.on('delivered', (data) {
        final m = Map<String, dynamic>.from(data);
        final by = (m['by'] ?? '').toString(); // receiver uid (peer)
        if (by.isEmpty) return;
        _deliveredLastByPeer[by] = true;
        if (_onlineByUser[by] == true) _stickyDoubleByPeer[by] = true;
        if (mounted) setState(() {});
      });

      // ✅ read_up_to → sender UI ပြောင်း (✓✓ blue)
      SocketService.I.on('read_up_to', (data) {
        final m = Map<String, dynamic>.from(data);
        final by = (m['by'] ?? '').toString();
        if (by.isEmpty) return;
        _readLastByPeer[by] = true;
        _deliveredLastByPeer[by] = true; // read ⇒ delivered
        if (_onlineByUser[by] == true) _stickyDoubleByPeer[by] = true;
        if (mounted) setState(() {});
      });

      // Register profile update listener BEFORE connecting
      // This ensures we catch events even if they arrive immediately
      SocketService.I.on('user_profile_updated', (data) async {
        try {
          debugPrint('📸 Received user_profile_updated event: $data');
          final m = Map<String, dynamic>.from(data);
          final userId = (m['userId'] ?? '').toString();
          final userData = m['user'] as Map<String, dynamic>?;
          
          if (userId.isEmpty || userData == null) {
            debugPrint('⚠️ Invalid profile update data: userId=$userId, userData=$userData');
            return;
          }
          
          debugPrint('🔄 Updating profile for user: $userId, new avatarUrl: ${userData['avatarUrl']}');
          
          // Add timestamp directly to avatarUrl for immediate cache-busting
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final avatarUrl = userData['avatarUrl']?.toString();
          if (avatarUrl != null && avatarUrl.isNotEmpty) {
            final separator = avatarUrl.contains('?') ? '&' : '?';
            userData['avatarUrl'] = '$avatarUrl${separator}_t=$timestamp';
            debugPrint('✅ Updated avatarUrl with timestamp: ${userData['avatarUrl']}');
          } else {
            // If avatarUrl is null or empty, explicitly set it to null to clear the avatar
            userData['avatarUrl'] = null;
            debugPrint('✅ Cleared avatarUrl for user: $userId');
          }
          userData['_avatarTimestamp'] = timestamp;
          
          // Update idMap with new profile data
          idMap[userId] = userData;
          
          debugPrint('✅ Updated idMap for $userId, timestamp: $timestamp, avatarUrl: ${userData['avatarUrl']}');
          
          // Refresh UI to show updated avatar
          // The idMap update will automatically be reflected in the UI since
          // _getAvatarUrl() and _nameOrEmail() read from idMap
          if (mounted) {
            debugPrint('✅ Refreshing UI for profile update');
            setState(() {});
          }
        } catch (e) {
          debugPrint('❌ Error handling profile update: $e');
        }
      });

      SocketService.I.connect(baseUrl: apiBase, token: t);
      
      // Listen for disconnections - socket.io will auto-reconnect
      // BackgroundService will handle manual reconnection if needed
      SocketService.I.onDisconnect((reason) {
        debugPrint('Socket disconnected: $reason');
        // Let socket.io's built-in reconnection handle it first
        // BackgroundService will monitor and manually reconnect if socket.io fails
        debugPrint('Socket.io will attempt auto-reconnection...');
      });
      
      // Listen for reconnection
      SocketService.I.onReconnect(() {
        debugPrint('✅ Socket reconnected successfully - user should appear online');
        // Verify connection is actually working
        if (SocketService.I.isConnected) {
          debugPrint('✅ Connection verified: Socket is connected');
        } else {
          debugPrint('⚠️ Warning: Reconnect event fired but socket reports disconnected');
        }
      });
      
      // Listen for reconnection attempts
      SocketService.I.onReconnectAttempt((attemptNumber) {
        debugPrint('Socket reconnection attempt #$attemptNumber');
      });
      
      // Monitor connection status periodically (only when app is in foreground)
      // BackgroundService handles monitoring when app is in background
      _connectionMonitorTimer?.cancel();
      _connectionMonitorTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
        if (!mounted) {
          timer.cancel();
          _connectionMonitorTimer = null;
          return;
        }
        final isConnected = SocketService.I.isConnected;
        if (!isConnected) {
          debugPrint('⚠️ Connection check (foreground): Socket is disconnected');
          // Only reconnect if background service is not active
          // (BackgroundService handles reconnection when app is in background)
          if (!BackgroundService.instance.isActive) {
            debugPrint('Attempting reconnect from foreground...');
            _connectSocket();
          }
        } else {
          // Log connection status periodically (every 2 minutes) for debugging
          if (timer.tick % 4 == 0) { // Every 2 minutes (4 * 30 seconds)
            debugPrint('✅ Connection check: Socket is connected');
          }
        }
      });
      
      CallSignal.setup();
      // ---- core socket events ----

      // request arrived
      SocketService.I.on('chat_request', (data) async {
        try {
          final myId = me?['id']?.toString();
          final m = Map<String, dynamic>.from(data);
          final toId = m['to']?.toString();
          final fromId = m['from']?.toString();
          final convId = (m['_id'] ?? '').toString();
          if (toId != myId) return;

          await _ensureProfiles([fromId ?? '']);
          final who = _nameOrEmail(fromId) ?? 'Someone';

          await Noti.showIfNew(
            messageId: 'req_$convId',
            title: 'New friend request',
            body: '$who wants to friend',
            payload: {
              'type': 'request',
              'conversationId': convId,
              'fromId': fromId ?? '',
            },
          );

          if (mounted) setState(() => _tabIndex = 1); // Navigate to Contacts
          await _loadPending();
        } catch (_) {}
      });

      // message_deleted
      SocketService.I.on('message_deleted', (data) async {
        try {
          final m = Map<String, dynamic>.from(data);
          final myId = me?['id']?.toString();
          final fromId = m['from']?.toString();
          final toId = m['to']?.toString();
          final peer = (fromId == myId) ? toId : fromId;
          if (peer != null) _lastTextByPeer.remove(peer);
          setState(() {});
          await _loadActive();
        } catch (_) {}
      });

      // request accepted
      SocketService.I.on('chat_request_accepted', (data) async {
        try {
          final m = Map<String, dynamic>.from(data);
          final partnerId = (m['partnerId'] ?? '').toString();
          await _ensureProfiles([partnerId]);
          final who = _nameOrEmail(partnerId) ?? 'Your partner';

          if (ForegroundChat.currentPeerId != partnerId) {
            await Noti.showIfNew(
              messageId: 'accepted_${m["conversationId"]}',
              title: 'Request accepted',
              body: '$who accepted your request',
              payload: {
                'type': 'accepted',
                'conversationId': (m['conversationId'] ?? '').toString(),
              },
            );
          }
          await Future.wait([_loadActive(), _loadPending(), _syncContacts()]);
        } catch (_) {}
      });

      // presence
      SocketService.I.on('presence', (data) {
        final m = Map<String, dynamic>.from(data);
        final uid = (m['uid'] ?? '').toString();
        final on = m['online'] == true;
        if (uid.isEmpty) return;
        setState(() {
          _onlineByUser[uid] = on;
          // Store lastSeen from presence event if available
          if (m['lastSeen'] != null && idMap.containsKey(uid)) {
            idMap[uid]!['lastSeen'] = m['lastSeen'];
          }
        });
        if (on &&
            _lastFromByPeer[uid] == 'me' &&
            (_deliveredLastByPeer[uid] ?? false)) {
          _stickyDoubleByPeer[uid] = true;
        }
      });


      SocketService.I.on('message_edited', (data) async {
        try {
          // quickest: just refresh active (lastPreview recomputed on server)
          await _loadActive();
        } catch (_) {}
      });

      // message
      SocketService.I.on('message', (data) async {
        try {
          final m = Map<String, dynamic>.from(data);
          final myId = me?['id']?.toString();
          final fromId = m['from']?.toString();
          final toId = m['to']?.toString();
          final text = (m['text'] ?? '').toString();

          final isSender = fromId == myId;
          final isReceiver = toId == myId;

          // ✅ receiver ⇒ immediately emit delivered
          if (isReceiver) {
            final id = (m['_id'] ?? m['id'] ?? m['messageId'] ?? '').toString();
            if (id.isNotEmpty)
              SocketService.I.emit('delivered', {'messageId': id});
          }

          if (isReceiver) {
            if (ForegroundChat.currentPeerId != fromId) {
              // Prepare notification body - replace "📎 filename" with "Photo", "Video", or "File"
              String notificationBody = text;
              final fileUrl = (m['fileUrl'] ?? '').toString();
              final fileType = (m['fileType'] ?? '').toString();
              final fileName = (m['fileName'] ?? '').toString();
              final isImage = fileType == 'image' || fileName.toLowerCase().contains('.jpg') || 
                  fileName.toLowerCase().contains('.png') || fileName.toLowerCase().contains('.gif') ||
                  fileName.toLowerCase().contains('.jpeg') || fileName.toLowerCase().contains('.webp');
              final isVideo = fileType == 'video' || fileName.toLowerCase().contains('.mp4') || 
                  fileName.toLowerCase().contains('.mov') || fileName.toLowerCase().contains('.avi') ||
                  fileName.toLowerCase().contains('.mkv') || fileName.toLowerCase().contains('.webm');
              
              if (isImage && text.isNotEmpty) {
                // Check if text contains paperclip emoji (in any form)
                if (text.contains('📎')) {
                  notificationBody = 'Photo';
                } else {
                  // Also check for image file extensions in text
                  final textLower = text.toLowerCase();
                  if (textLower.contains('.jpg') || textLower.contains('.jpeg') || 
                      textLower.contains('.png') || textLower.contains('.gif') || 
                      textLower.contains('.webp') || textLower.contains('.bmp')) {
                    notificationBody = 'Photo';
                  }
                }
              } else if (isImage && text.isEmpty) {
                notificationBody = 'Photo';
              } else if (isVideo && text.isNotEmpty) {
                // Check if text contains paperclip emoji (in any form)
                if (text.contains('📎')) {
                  notificationBody = 'Video';
                } else {
                  // Also check for video file extensions in text
                  final textLower = text.toLowerCase();
                  if (textLower.contains('.mp4') || textLower.contains('.mov') || 
                      textLower.contains('.avi') || textLower.contains('.mkv') || 
                      textLower.contains('.webm')) {
                    notificationBody = 'Video';
                  }
                }
              } else if (isVideo && text.isEmpty) {
                notificationBody = 'Video';
              } else if (text.isNotEmpty && text.contains('📎')) {
                // For other files, extract filename from "📎 filename" format
                final index = text.indexOf('📎');
                if (index >= 0 && index + 2 < text.length) {
                  final extractedName = text.substring(index + 2).trim();
                  notificationBody = extractedName.isNotEmpty ? extractedName : (fileName.isNotEmpty ? fileName : 'File');
                } else {
                  notificationBody = fileName.isNotEmpty ? fileName : 'File';
                }
              } else if (text.isEmpty && (fileUrl.isNotEmpty || fileName.isNotEmpty) && !isImage && !isVideo) {
                // Show file name in notification
                notificationBody = fileName.isNotEmpty ? fileName : 'File';
              }
              
              // Get message ID - try multiple formats to match FCM handler
              // CRITICAL: Normalize messageId (trim) to ensure consistent matching
              final rawMessageId = (m['_id'] ?? m['id'] ?? m['messageId'] ?? '').toString();
              final messageId = rawMessageId.trim();
              
              // CRITICAL: Check if message was already processed by FCM handler
              // This prevents duplicate notifications when both FCM and socket receive the same message
              // FCM handler marks message as processed BEFORE emitting to socket, so this check will catch it
              if (messageId.isNotEmpty && FirebaseMessagingHandler.isMessageProcessed(messageId)) {
                debugPrint('⚠️ Message $messageId already processed by FCM - skipping duplicate notification');
                // Still update unread count even if notification was already shown
                if (fromId != null && fromId.isNotEmpty) {
                  _lastFromByPeer[fromId] = 'them';
                  _unreadByPeer[fromId] = (_unreadByPeer[fromId] ?? 0) + 1;
                }
                return; // Skip showing notification
              }
              
              // Mark message as processed BEFORE showing notification (in case it wasn't marked by FCM)
              // This handles the case where message comes directly via socket (not from FCM)
              if (messageId.isNotEmpty) {
                final wasNew = FirebaseMessagingHandler.markMessageProcessed(messageId);
                if (wasNew) {
                  debugPrint('✅ Marked message $messageId as processed (socket handler)');
                } else {
                  debugPrint('⚠️ Message $messageId was already processed - this should not happen');
                  return; // Safety check - if already processed, skip
                }
              }
              
              await Noti.showIfNew(
                messageId: messageId,
                title: 'New message',
                body: notificationBody,
                payload: {'fromId': fromId ?? ''},
              );
              if (fromId != null && fromId.isNotEmpty) {
                _lastFromByPeer[fromId] = 'them';
                _unreadByPeer[fromId] = (_unreadByPeer[fromId] ?? 0) + 1;
              }
            }
            if (fromId != null && fromId.isNotEmpty) {
              // Build preview text - check for file messages
              final fileUrl = (m['fileUrl'] ?? '').toString();
              final fileName = (m['fileName'] ?? '').toString();
              final fileType = (m['fileType'] ?? '').toString();
              
              String previewText = text;
              // Check if text contains paperclip emoji and filename (for images/videos, replace with "Photo"/"Video")
              final isImage = fileType == 'image' || fileName.toLowerCase().contains('.jpg') || 
                  fileName.toLowerCase().contains('.png') || fileName.toLowerCase().contains('.gif') ||
                  fileName.toLowerCase().contains('.jpeg') || fileName.toLowerCase().contains('.webp');
              final isVideo = fileType == 'video' || fileName.toLowerCase().contains('.mp4') || 
                  fileName.toLowerCase().contains('.mov') || fileName.toLowerCase().contains('.avi') ||
                  fileName.toLowerCase().contains('.mkv') || fileName.toLowerCase().contains('.webm');
              
              // If it's an image message, replace any text containing paperclip emoji with "Photo"
              if (isImage && text.isNotEmpty) {
                // Check if text contains paperclip emoji (in any form)
                if (text.contains('📎')) {
                  previewText = 'Photo';
                } else {
                  // Also check for image file extensions in text
                  final textLower = text.toLowerCase();
                  if (textLower.contains('.jpg') || textLower.contains('.jpeg') || 
                      textLower.contains('.png') || textLower.contains('.gif') || 
                      textLower.contains('.webp') || textLower.contains('.bmp')) {
                    previewText = 'Photo';
                  }
                }
              }
              // If it's a video message, replace any text containing paperclip emoji with "Video"
              else if (isVideo && text.isNotEmpty) {
                // Check if text contains paperclip emoji (in any form)
                if (text.contains('📎')) {
                  previewText = 'Video';
                } else {
                  // Also check for video file extensions in text
                  final textLower = text.toLowerCase();
                  if (textLower.contains('.mp4') || textLower.contains('.mov') || 
                      textLower.contains('.avi') || textLower.contains('.mkv') || 
                      textLower.contains('.webm')) {
                    previewText = 'Video';
                  }
                }
              }
              if (text.isEmpty && (fileUrl.isNotEmpty || fileName.isNotEmpty)) {
                if (isImage) {
                  previewText = 'Photo';
                } else if (isVideo) {
                  previewText = 'Video';
                } else if (fileType == 'audio' || fileName.toLowerCase().contains('.mp3') || 
                           fileName.toLowerCase().contains('.wav')) {
                  previewText = '🎵 Audio';
                } else {
                  // For other files, show the file name
                  previewText = fileName.isNotEmpty ? fileName : 'File';
                }
              }
              if (previewText.isNotEmpty) {
                _lastTextByPeer[fromId] = previewText;
              }
            }
          }

          if (isSender && toId != null && toId.isNotEmpty) {
            // Build preview text - check for file messages
            final fileUrl = (m['fileUrl'] ?? '').toString();
            final fileName = (m['fileName'] ?? '').toString();
            final fileType = (m['fileType'] ?? '').toString();
            
            String previewText = text;
            // Check if text contains paperclip emoji and filename (for images/videos, replace with "Photo"/"Video")
            final isImage = fileType == 'image' || fileName.toLowerCase().contains('.jpg') || 
                fileName.toLowerCase().contains('.png') || fileName.toLowerCase().contains('.gif') ||
                fileName.toLowerCase().contains('.jpeg') || fileName.toLowerCase().contains('.webp');
            final isVideo = fileType == 'video' || fileName.toLowerCase().contains('.mp4') || 
                fileName.toLowerCase().contains('.mov') || fileName.toLowerCase().contains('.avi') ||
                fileName.toLowerCase().contains('.mkv') || fileName.toLowerCase().contains('.webm');
            
            // If it's an image message, replace any text containing paperclip emoji with "Photo"
            if (isImage && text.isNotEmpty) {
              // Check if text contains paperclip emoji (in any form)
              if (text.contains('📎')) {
                previewText = 'Photo';
              } else {
                // Also check for image file extensions in text
                final textLower = text.toLowerCase();
                if (textLower.contains('.jpg') || textLower.contains('.jpeg') || 
                    textLower.contains('.png') || textLower.contains('.gif') || 
                    textLower.contains('.webp') || textLower.contains('.bmp')) {
                  previewText = 'Photo';
                }
              }
            }
            // If it's a video message, replace any text containing paperclip emoji with "Video"
            else if (isVideo && text.isNotEmpty) {
              // Check if text contains paperclip emoji (in any form)
              if (text.contains('📎')) {
                previewText = 'Video';
              } else {
                // Also check for video file extensions in text
                final textLower = text.toLowerCase();
                if (textLower.contains('.mp4') || textLower.contains('.mov') || 
                    textLower.contains('.avi') || textLower.contains('.mkv') || 
                    textLower.contains('.webm')) {
                  previewText = 'Video';
                }
              }
            }
            if (text.isEmpty && (fileUrl.isNotEmpty || fileName.isNotEmpty)) {
              if (isImage) {
                previewText = 'Photo';
              } else if (isVideo) {
                previewText = 'Video';
              } else if (fileType == 'audio' || fileName.toLowerCase().contains('.mp3') || 
                         fileName.toLowerCase().contains('.wav')) {
                previewText = '🎵 Audio';
              } else {
                previewText = '📎 ${fileName.isNotEmpty ? fileName : "File"}';
              }
            }
            if (previewText.isNotEmpty) {
              _lastTextByPeer[toId] = previewText;
            }
            _lastFromByPeer[toId] = 'me';
            _deliveredLastByPeer[toId] = false; // ✅ send မတင်ခင် single ✓
            _stickyDoubleByPeer[toId] = _onlineByUser[toId] == true;
          }

          if (mounted) setState(() {});
          await _loadActive();
        } catch (_) {}
      });

      await Future.wait([_loadActive(), _loadPending(), _syncContacts()]);
    } catch (e) {
      setState(() {
        loadingProfile = false;
        loadingActive = false;
        loadingPending = false;
        activeError = 'Failed: $e';
        pendingError = 'Failed: $e';
      });
    }
  }

  Future<void> _seedChatPreviews() async {
    final rows = List<_Row>.from(activeRows).take(20);

    for (final t in rows) {
      final pid = t.peerId;
      if (pid == null) continue;
      if ((_lastTextByPeer[pid] ?? '').isNotEmpty) continue;

      try {
        final r = await getJson(
          '/messages?conversation=${t.conversationId}',
        ).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final list = (jsonDecode(r.body) as List)
              .cast<Map<String, dynamic>>();
          if (list.isNotEmpty) {
            Map<String, dynamic>? last;
            for (var i = list.length - 1; i >= 0; i--) {
              final m = list[i];
              final del = m['deleted'] == true || m['deletedForMe'] == true;
              if (del) continue; // Skip deleted messages
              
              final txt = (m['text'] ?? '').toString().trim();
              final fileUrl = (m['fileUrl'] ?? '').toString();
              final fileName = (m['fileName'] ?? '').toString();
              
              // Accept message if it has text OR a file
              if (txt.isNotEmpty || fileUrl.isNotEmpty || fileName.isNotEmpty) {
                last = m;
                break;
              }
            }

            if (last != null) {
              final from = (last['from'] ?? '').toString();
              if (from == me?['id']?.toString()) {
                _lastFromByPeer[pid] = 'me';
                // ❌ အောက်ကလို delivered ကို မပြောင်းပါနဲ့ (✓✓ seed bug ပြေ)
                // _deliveredLastByPeer[pid] = true;
              } else {
                _lastFromByPeer[pid] = 'them';
              }
            }

            final txt = (last?['text'] ?? '').toString().trim();
            final fileUrl = (last?['fileUrl'] ?? '').toString();
            final fileName = (last?['fileUrl'] ?? last?['fileName'] ?? '').toString();
            final fileType = (last?['fileType'] ?? '').toString();
            
            // Build preview text - prioritize text, then show file type indicator
            String previewText = '';
            final isImage = fileType == 'image' || fileName.toLowerCase().contains('.jpg') || 
                fileName.toLowerCase().contains('.png') || fileName.toLowerCase().contains('.gif') ||
                fileName.toLowerCase().contains('.jpeg') || fileName.toLowerCase().contains('.webp');
            final isVideo = fileType == 'video' || fileName.toLowerCase().contains('.mp4') || 
                fileName.toLowerCase().contains('.mov') || fileName.toLowerCase().contains('.avi') ||
                fileName.toLowerCase().contains('.mkv') || fileName.toLowerCase().contains('.webm');
            if (txt.isNotEmpty) {
              // If it's an image message, replace any text containing paperclip emoji with "Photo"
              if (isImage) {
                // Check if text contains paperclip emoji (in any form)
                if (txt.contains('📎')) {
                  previewText = 'Photo';
                } else {
                  // Also check for image file extensions in text
                  final txtLower = txt.toLowerCase();
                  if (txtLower.contains('.jpg') || txtLower.contains('.jpeg') || 
                      txtLower.contains('.png') || txtLower.contains('.gif') || 
                      txtLower.contains('.webp') || txtLower.contains('.bmp')) {
                    previewText = 'Photo';
                  } else {
                    previewText = txt;
                  }
                }
              } 
              // If it's a video message, replace any text containing paperclip emoji with "Video"
              else if (isVideo) {
                // Check if text contains paperclip emoji (in any form)
                if (txt.contains('📎')) {
                  previewText = 'Video';
                } else {
                  // Also check for video file extensions in text
                  final txtLower = txt.toLowerCase();
                  if (txtLower.contains('.mp4') || txtLower.contains('.mov') || 
                      txtLower.contains('.avi') || txtLower.contains('.mkv') || 
                      txtLower.contains('.webm')) {
                    previewText = 'Video';
                  } else {
                    previewText = txt;
                  }
                }
              } else {
                previewText = txt;
              }
            } else if (fileUrl.isNotEmpty || fileName.isNotEmpty) {
              if (isImage) {
                previewText = 'Photo';
              } else if (isVideo) {
                previewText = 'Video';
              } else if (fileType == 'audio' || fileName.toLowerCase().contains('.mp3') || 
                         fileName.toLowerCase().contains('.wav')) {
                previewText = '🎵 Audio';
              } else {
                previewText = '📎 ${fileName.isNotEmpty ? fileName : "File"}';
              }
            }
            
            if (previewText.isNotEmpty) _lastTextByPeer[pid] = previewText;
          }
        }
      } catch (_) {}
    }

    if (mounted) setState(() {});
  }

  Future<void> _loadActive() async {
    if (me == null) return;
    setState(() {
      loadingActive = true;
      activeError = null;
    });
    try {
      final myId = me!['id'].toString();
      final a = await getJson(
        '/conversations?me=$myId&status=active',
      ).timeout(const Duration(seconds: 12));

      final active = a.statusCode == 200
          ? (jsonDecode(a.body) as List).cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];

      final ids = <String>{};
      for (final it in active) {
        ids.addAll((it['participants'] as List).map((e) => e.toString()));
      }
      await _ensureProfiles(ids.toList());

      String emailOf(String id) => idMap[id]?['email']?.toString() ?? id;
      String nameOf(String id) => idMap[id]?['name']?.toString() ?? '';

      final list = <_Row>[];
      for (final it in active) {
        final parts = (it['participants'] as List)
            .map((e) => e.toString())
            .toList();
        final other = parts.firstWhere((x) => x != myId, orElse: () => myId);
        list.add(
          _Row(
            conversationId: it['_id'].toString(),
            peerId: other,
            email: emailOf(other),
            name: nameOf(other),
            isPending: false,
            isIncoming: null,
            label: 'Active chat',
            sortKey: _ts(
              it['lastMessageAt'] ?? it['updatedAt'] ?? it['createdAt'],
            ),
            createdBy: it['createdBy']?.toString(),
          ),
        );

        final lastPreview = (it['lastPreview'] ?? '').toString();
        if (lastPreview.isNotEmpty) _lastTextByPeer[other] = lastPreview;

        final lastOutIso = it['lastOutgoingAt']?.toString();
        final lastOutMs =
            DateTime.tryParse(lastOutIso ?? '')?.millisecondsSinceEpoch ?? 0;

        // ✅ who sent last?
        final lastFrom = (it['lastFrom'] ?? '').toString();
        if (lastFrom.isNotEmpty) {
          _lastFromByPeer[other] = (lastFrom == myId) ? 'me' : 'them';
        }

        final deliveredUpTo = Map<String, dynamic>.from(
          it['deliveredUpTo'] ?? {},
        );
        final readUpTo = Map<String, dynamic>.from(it['readUpTo'] ?? {});
        final deliveredMs =
            DateTime.tryParse(
              (deliveredUpTo[other] ?? '').toString(),
            )?.millisecondsSinceEpoch ??
            0;
        final readMs =
            DateTime.tryParse(
              (readUpTo[other] ?? '').toString(),
            )?.millisecondsSinceEpoch ??
            0;

        if (lastOutMs > 0) {
          _deliveredLastByPeer[other] = deliveredMs >= lastOutMs; // ✓✓ grey
          _readLastByPeer[other] = readMs >= lastOutMs; // ✓✓ blue
        }
      }
      list.sort((a, b) => b.sortKey.compareTo(a.sortKey));

      setState(() {
        activeRows = list;
      });

      await _seedChatPreviews();

      final peerIds = activeRows
          .map((r) => r.peerId)
          .whereType<String>()
          .toSet()
          .toList();
      if (peerIds.isNotEmpty) {
        final r = await getJson(
          '/presence?ids=${peerIds.join(",")}',
        ).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final map = Map<String, dynamic>.from(jsonDecode(r.body));
          setState(() {
            if (map.containsKey('online')) {
              for (final uid in (map['online'] as List).map(
                (e) => e.toString(),
              )) {
                _onlineByUser[uid] = true;
              }
            } else {
              map.forEach((k, v) => _onlineByUser[k] = v == true);
            }
            for (final uid in peerIds) {
              if (_onlineByUser[uid] == true &&
                  _lastFromByPeer[uid] == 'me' &&
                  (_deliveredLastByPeer[uid] ?? false)) {
                _stickyDoubleByPeer[uid] = true;
              }
            }
          });
        }
      }
    } on TimeoutException {
      setState(() => activeError = 'Timeout: server not reachable (chats)');
    } catch (e) {
      setState(() => activeError = 'Load active failed: $e');
    } finally {
      setState(() => loadingActive = false);
    }
  }

  Future<void> _loadPending() async {
    if (me == null) return;
    setState(() {
      loadingPending = true;
      pendingError = null;
    });
    try {
      final myId = me!['id'].toString();
      final p = await getJson(
        '/chat-requests?me=$myId&status=pending',
      ).timeout(const Duration(seconds: 12));

      final pending = p.statusCode == 200
          ? (jsonDecode(p.body) as List).cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];

      final ids = <String>{};
      for (final it in pending) {
        ids.addAll((it['participants'] as List).map((e) => e.toString()));
      }
      await _ensureProfiles(ids.toList());

      String emailOf(String id) => idMap[id]?['email']?.toString() ?? id;
      String nameOf(String id) => idMap[id]?['name']?.toString() ?? '';

      final list = <_Row>[];
      for (final it in pending) {
        final parts = (it['participants'] as List)
            .map((e) => e.toString())
            .toList();
        final other = parts.firstWhere((x) => x != myId, orElse: () => myId);
        final createdBy = it['createdBy']?.toString();
        final isIncoming = createdBy != myId;
        list.add(
          _Row(
            conversationId: it['_id'].toString(),
            peerId: other,
            email: emailOf(other),
            name: nameOf(other),
            isPending: true,
            isIncoming: isIncoming,
            label: isIncoming ? 'Incoming request' : 'Awaiting acceptance',
            sortKey: _ts(it['createdAt']),
            createdBy: createdBy,
          ),
        );
      }
      list.sort((a, b) => b.sortKey.compareTo(a.sortKey));

      setState(() {
        pendingRows = list;
      });
    } on TimeoutException {
      setState(() => pendingError = 'Timeout: server not reachable (requests)');
    } catch (e) {
      setState(() => pendingError = 'Load pending failed: $e');
    } finally {
      setState(() => loadingPending = false);
    }
  }

  Future<void> _syncContacts() async {
    if (me == null || _token == null) return;
    
    setState(() {
      _loadingContacts = true;
      _contactsError = null;
    });
    try {
      // Request permission
      final hasPermission = await FlutterContacts.requestPermission();
      if (!hasPermission) {
        setState(() {
          _loadingContacts = false;
          _contactsError = 'Permission denied: Please allow contacts access';
        });
        return;
      }

      // Read device contacts
      final deviceContacts = await FlutterContacts.getContacts(
        withProperties: true,
        withThumbnail: false,
      );

      // Extract phone numbers
      final contactList = deviceContacts
          .where((c) => c.phones.isNotEmpty)
          .map((c) {
            final phone = c.phones.first.number;
            return {
              'phone': phone,
              'name': c.name.first,
            };
          })
          .toList();

      if (contactList.isEmpty) {
        setState(() {
          _loadingContacts = false;
          _contactsOnApp = [];
          _contactsError = null;
        });
        return;
      }

      // Send to backend to find matches
      final res = await http.post(
        Uri.parse('$apiBase/contacts/sync'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_token',
        },
        body: jsonEncode({ 'contacts': contactList }),
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final matches = (data['matches'] as List?)
            ?.cast<Map<String, dynamic>>() ?? [];
        
        // Load profiles for matched users
        final matchedIds = matches.map((m) => m['id'].toString()).toList();
        if (matchedIds.isNotEmpty) {
          await _ensureProfiles(matchedIds);
          // Fetch presence data with verbose mode to get lastSeen information
          try {
            final presenceRes = await getJson(
              '/presence?ids=${matchedIds.join(",")}&verbose=true',
            ).timeout(const Duration(seconds: 5));
            if (presenceRes.statusCode == 200) {
              final presenceMap = Map<String, dynamic>.from(jsonDecode(presenceRes.body));
              // Update idMap with presence data including lastSeen
              bool hasUpdates = false;
              presenceMap.forEach((k, v) {
                if (v is Map) {
                  // Update online status
                  final wasOnline = _onlineByUser[k] == true;
                  _onlineByUser[k] = v['online'] == true;
                  
                  // Store lastSeen from presence data (use 'at' field as lastSeen)
                  if (v['at'] != null) {
                    if (!idMap.containsKey(k)) {
                      idMap[k] = <String, dynamic>{};
                    }
                    final oldLastSeen = idMap[k]!['lastSeen'];
                    idMap[k]!['lastSeen'] = v['at'];
                    if (oldLastSeen != v['at']) {
                      hasUpdates = true;
                    }
                    debugPrint('📅 Stored lastSeen for $k: ${v['at']}');
                  } else {
                    debugPrint('⚠️ No lastSeen data for $k (online: ${v['online']})');
                  }
                  
                  if (wasOnline != (v['online'] == true)) {
                    hasUpdates = true;
                  }
                } else if (v is bool) {
                  final wasOnline = _onlineByUser[k] == true;
                  _onlineByUser[k] = v;
                  if (wasOnline != v) {
                    hasUpdates = true;
                  }
                }
              });
              // Force UI update after storing lastSeen
              if (mounted && hasUpdates) {
                setState(() {});
                debugPrint('🔄 UI updated with presence data');
              }
            }
          } catch (e) {
            debugPrint('Error fetching presence for contacts: $e');
          }
        }

        setState(() {
          _contactsOnApp = matches;
          _loadingContacts = false;
          _contactsError = null;
        });
      } else {
        setState(() {
          _loadingContacts = false;
          _contactsError = 'Failed to sync contacts (${res.statusCode})';
        });
      }
    } on TimeoutException {
      setState(() {
        _loadingContacts = false;
        _contactsError = 'Timeout: Server not reachable';
      });
    } catch (e) {
      debugPrint('Contact sync error: $e');
      setState(() {
        _loadingContacts = false;
        _contactsError = 'Error syncing contacts: ${e.toString()}';
      });
    }
  }

  Future<void> _ensureProfiles(List<String> ids) async {
    final needs = ids
        .where((id) => id.isNotEmpty && idMap[id] == null)
        .toList();
    if (needs.isEmpty) return;
    final r = await getJson(
      '/users/by-ids?ids=${needs.join(",")}',
    ).timeout(const Duration(seconds: 8));
    if (r.statusCode == 200) {
      final map = Map<String, dynamic>.from(jsonDecode(r.body));
      debugPrint('📥 Loaded ${map.length} profiles from /users/by-ids');
      for (final entry in map.entries) {
        final userId = entry.key;
        final userData = entry.value as Map<String, dynamic>;
        final avatarUrl = userData['avatarUrl']?.toString();
        debugPrint('  User $userId: name=${userData['name']}, avatarUrl=$avatarUrl');
      }
      idMap.addAll(map);
      if (mounted) setState(() {});
    } else {
      debugPrint('⚠️ Failed to load profiles: status ${r.statusCode}');
    }
  }

  String? _nameOrEmail(String? uid) {
    if (uid == null || uid.isEmpty) return null;
    final m = idMap[uid];
    if (m == null) return null;
    final name = (m['name'] ?? '').toString().trim();
    final email = (m['email'] ?? '').toString().trim();
    return name.isNotEmpty ? name : (email.isNotEmpty ? email : null);
  }

  String? _getAvatarUrl(String? uid) {
    if (uid == null || uid.isEmpty) return null;
    final m = idMap[uid];
    if (m == null) return null;
    final avatarUrl = (m['avatarUrl'] ?? '').toString().trim();
    if (avatarUrl.isEmpty || avatarUrl == 'null') return null;
    
    // Add cache-busting parameter if timestamp exists
    // This ensures images refresh when profile is updated
    final timestamp = m['_avatarTimestamp'];
    if (timestamp != null) {
      final separator = avatarUrl.contains('?') ? '&' : '?';
      return '$avatarUrl${separator}_t=$timestamp';
    }
    return avatarUrl;
  }

  void _toLogin() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
    );
  }

  Future<void> _logout() async {
    await AuthStore.clear();
    SocketService.I.disconnect();
    _toLogin();
  }

  Future<void> _accept(_Row t) async {
    final r = await postJson('/chat-requests/${t.conversationId}/accept', {
      'me': me!['id'],
    });
    if (r.statusCode == 200) {
      await Future.wait([_loadActive(), _loadPending(), _syncContacts()]);
      if (!mounted) return;
      // Get phone number from idMap if available, otherwise use email or peerId
      final phone = (t.peerId != null && idMap[t.peerId!] != null)
          ? (idMap[t.peerId!]?['phone']?.toString() ?? 
             idMap[t.peerId!]?['email']?.toString() ?? 
             t.peerId!)
          : (t.email ?? t.peerId!);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatPage(
            peerId: t.peerId!,
            partnerEmail: phone,
            peerName: t.name ?? t.email ?? t.peerId!,
          ),
        ),
      );
    } else {
      _toast('Accept failed (${r.statusCode})');
    }
  }

  Future<void> _declineOrCancel(_Row t) async {
    final r = await postJson('/chat-requests/${t.conversationId}/decline', {
      'me': me!['id'],
    });
    if (r.statusCode == 200) {
      await _loadPending();
    } else {
      _toast('Failed (${r.statusCode})');
    }
  }

  Future<void> _startNewRequest() async {
    final phone = await showDialog<String>(
      context: context,
      builder: (_) => const _NewChatDialog(),
    );
    if (phone == null || phone.trim().isEmpty) return;
    final u = await AuthStore.getUser();
    final res = await postJson('/contacts/start-chat', {
      'from': u!['id'],
      'toPhone': phone.trim(),
    });
    if (res.statusCode == 200) {
      _toast('Contact ready to chat');
      // Refresh active conversations and contacts so this friend appears immediately
      await Future.wait([
        _loadActive(),
        _syncContacts(),
      ]);
      if (mounted) setState(() => _tabIndex = 1);
    } else if (res.statusCode == 404) {
      _toast('This phone is not registered on Instant Messaging');
    } else {
      _toast('Could not add contact (${res.statusCode})');
    }
  }

  Future<void> _openChatFromFriends(String partnerId) async {
    await _ensureProfiles([partnerId]);
    final phone = idMap[partnerId]?['phone']?.toString() ?? 
                  idMap[partnerId]?['email']?.toString() ?? 
                  partnerId;
    final name = idMap[partnerId]?['name']?.toString() ?? phone;
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatPage(peerId: partnerId, partnerEmail: phone, peerName: name),
      ),
    );
  }

  Future<void> _connectSocket() async {
    final t = await AuthStore.getToken();
    if (t == null) return;
    // Ensure socket connected with auth
    SocketService.I.connect(baseUrl: apiBase, token: t);
    // ⬇️ Wire global call listeners exactly once
    CallManager.I.wire();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      floatingActionButton: _tabIndex == 1
          ? FloatingActionButton(
              elevation: 0,
              backgroundColor: Colors.transparent,
              splashColor: Theme.of(context).colorScheme.primary.withOpacity(0.2),
              onPressed: _startNewRequest,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).colorScheme.secondary,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.person_add_alt_1,
                  color: Theme.of(context).colorScheme.onPrimary,
                  size: 30,
                ),
              ),
            )
          : null,
      appBar: _tabIndex == 0
          ? null
          : _tabIndex == 1
              ? AppBar(
                  automaticallyImplyLeading: false,
                  title: const Text('Contacts'),
                  flexibleSpace: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Theme.of(context).colorScheme.primary.withOpacity(0.8),
                          Theme.of(context).colorScheme.secondary,
                        ],
                      ),
                    ),
                  ),
                  bottom: PreferredSize(
                    preferredSize: const Size.fromHeight(80),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: Theme.of(context).colorScheme.shadow.withOpacity(0.1),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: TextField(
                          controller: _friendsSearchCtrl,
                          textInputAction: TextInputAction.search,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontSize: 15,
                          ),
                          onChanged: (v) => setState(() => _friendsQuery = v),
                          decoration: InputDecoration(
                            hintText: 'Search friends',
                            hintStyle: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                              fontSize: 15,
        ),
                            prefixIcon: Icon(
                              Icons.search,
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                              size: 22,
                            ),
                            suffixIcon: _friendsQuery.isNotEmpty
                                ? IconButton(
                                    icon: Icon(
                                      Icons.clear,
                                      size: 20,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
            onPressed: () {
                                      _friendsSearchCtrl.clear();
                                      setState(() => _friendsQuery = '');
                                    },
                                  )
                                : null,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(28),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(28),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(28),
                              borderSide: BorderSide(
                                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                                width: 1.5,
                              ),
                            ),
                            filled: true,
                            fillColor: Colors.transparent,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : AppBar(
                  automaticallyImplyLeading: false,
                  title: const Text('Calls'),
                  flexibleSpace: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Theme.of(context).colorScheme.primary.withOpacity(0.8),
                          Theme.of(context).colorScheme.secondary,
                        ],
                      ),
                    ),
                  ),
                  bottom: PreferredSize(
                    preferredSize: const Size.fromHeight(80),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: Theme.of(context).colorScheme.shadow.withOpacity(0.1),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: TextField(
                          controller: _callSearchCtrl,
                          textInputAction: TextInputAction.search,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontSize: 15,
                          ),
                          onChanged: (v) => setState(() => _callQuery = v),
                          decoration: InputDecoration(
                            hintText: 'Search calls',
                            hintStyle: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                              fontSize: 15,
                            ),
                            prefixIcon: Icon(
                              Icons.search,
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                              size: 22,
                            ),
                            suffixIcon: _callQuery.isNotEmpty
                                ? IconButton(
                                    icon: Icon(
                                      Icons.clear,
                                      size: 20,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                    onPressed: () {
                                      _callSearchCtrl.clear();
                                      setState(() => _callQuery = '');
                                    },
                                  )
                                : null,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(28),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(28),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(28),
                              borderSide: BorderSide(
                                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                                width: 1.5,
                              ),
                            ),
                            filled: true,
                            fillColor: Colors.transparent,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                  ),
      ),
      body: RefreshIndicator(
        onRefresh: () async =>
            await Future.wait([_loadActive(), _loadPending(), _syncContacts()]),
        child: IndexedStack(
          index: _tabIndex,
          children: [
            ChatsTab(
              rows: activeRows,
              loading: loadingActive,
              errorText: activeError,
              lastTextByPeer: _lastTextByPeer,
              unreadByPeer: _unreadByPeer,
              idMap: idMap,
              myAvatarUrl: me?['avatarUrl']?.toString(),
              myName: (me?['name'] ?? me?['email'])?.toString(),
              onOpenChat: (_Row t) async {
                // 1) local unread badge ဖယ်
                if (t.peerId != null) {
                  setState(() => _unreadByPeer.remove(t.peerId));
                }

                // 2) ✅ EMIT read_up_to *before* navigation (sender ဘက်မှာ ✓✓ အပြာ realtime)
                try {
                  final myId = me?['id']?.toString();
                  if (myId != null && t.conversationId.isNotEmpty) {
                    SocketService.I.emit('read_up_to', {
                      'conversationId': t.conversationId,
                      'by': me!['id'],
                      'at': DateTime.now().toUtc().toIso8601String(),
                    });
                  }
                } catch (_) {
                  // fail silently — navigation is still fine
                }

                // 3) open chat page
                if (!mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatPage(
                      conversationId: t.conversationId,
                      peerId: t.peerId!,
                      partnerEmail: t.email ?? t.peerId!,
                      peerName: t.name ?? t.email ?? t.peerId!,
                    ),
                  ),
                );
              },

              onlineByUser: _onlineByUser,
              lastFromByPeer: _lastFromByPeer,
              deliveredLastByPeer: _deliveredLastByPeer,
              readLastByPeer: _readLastByPeer,
              stickyDoubleByPeer: _stickyDoubleByPeer,
              searchController: _chatSearchCtrl,
              searchQuery: _chatQuery,
              onSearchChanged: (v) => setState(() => _chatQuery = v),
            ),
            FriendsTab(
              rows: activeRows,
              loading: loadingActive,
              errorText: activeError,
              controller: _friendsSearchCtrl,
              query: _friendsQuery,
              onQueryChanged: (v) => setState(() => _friendsQuery = v),
              onOpen: (partnerId) => _openChatFromFriends(partnerId),
              onlineByUser: _onlineByUser,
              idMap: idMap,
              onInviteFriends: _startNewRequest,
            ),
            CallHistoryScreen(
              searchController: _callSearchCtrl,
              searchQuery: _callQuery,
              onSearchChanged: (v) => setState(() => _callQuery = v),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: _GradientPillNav(
          selectedIndex: _tabIndex,
          totalUnread: _unreadByPeer.values.fold<int>(0, (a, b) => a + b),
          contactsBadge: pendingRows.length,
          onTap: (i) => setState(() => _tabIndex = i),
        ),
      ),
      backgroundColor: Theme.of(context).colorScheme.surface,
    );
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
}

// ===== ChatsTab / RequestsTab / FriendsTab / models (unchanged except comments) =====
// ... (same as your current code) ...

// =======================================================
// ChatsTab (separate page)
// =======================================================
class ChatsTab extends StatelessWidget {
  final List<_Row> rows;
  final bool loading;
  final String? errorText;
  final Map<String, String> lastTextByPeer;
  final Map<String, int> unreadByPeer;
  final void Function(_Row) onOpenChat;
  final Map<String, bool> onlineByUser;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final Map<String, String> lastFromByPeer; // 'me' | 'them'
  final Map<String, bool> deliveredLastByPeer; // ✓
  final Map<String, bool> readLastByPeer; // ✓✓ colored
  final Map<String, bool> stickyDoubleByPeer;
  final Map<String, dynamic> idMap;
  final String? myAvatarUrl;
  final String? myName;

  const ChatsTab({
    super.key,
    required this.rows,
    required this.loading,
    required this.errorText,
    required this.lastTextByPeer,
    required this.unreadByPeer,
    required this.onOpenChat,
    required this.onlineByUser,
    required this.lastFromByPeer,
    required this.deliveredLastByPeer,
    required this.readLastByPeer,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.stickyDoubleByPeer,
    required this.idMap,
    this.myAvatarUrl,
    this.myName,
  });

  String? _getAvatarUrl(String? uid) {
    if (uid == null || uid.isEmpty) return null;
    final m = idMap[uid];
    if (m == null) return null;
    final avatarUrl = (m['avatarUrl'] ?? '').toString().trim();
    if (avatarUrl.isEmpty) return null;
    
    // AvatarUrl already includes timestamp if it was updated via socket event
    // This ensures immediate cache refresh when profile is updated
    return avatarUrl;
  }

  String _displayNameOf(_Row t) => (t.name?.trim().isNotEmpty ?? false)
      ? t.name!.trim()
      : (t.email ?? 'Unknown');

  String _initialOf(_Row t) {
    final s = _displayNameOf(t);
    if (s.isEmpty) return '?';
    final cp = s.runes.first;
    return String.fromCharCode(cp).toUpperCase();
  }

  String _timeLabel(_Row t) {
    final ms = t.sortKey;
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${dt.month}/${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    // ----- error state -----
    if (errorText != null && errorText!.isNotEmpty) {
      return Column(
        children: [
          _buildCustomHeader(
            context,
            avatarUrl: myAvatarUrl,
            titleName: myName,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Server ကျနေပါတယ်။ refresh လုပ်ပေးပါ။',
                      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // ----- loading state -----
    if (loading) {
      return Column(
        children: [
          _buildCustomHeader(
            context,
            avatarUrl: myAvatarUrl,
            titleName: myName,
          ),
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: CircularProgressIndicator(),
              ),
            ),
          ),
        ],
      );
    }

    // ----- empty state -----
    if (rows.isEmpty) {
      return Column(
        children: [
          _buildCustomHeader(
            context,
            avatarUrl: myAvatarUrl,
            titleName: myName,
          ),
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('No active chats'),
              ),
            ),
          ),
        ],
      );
    }

    // ----- searchable list -----
    String q = ''; // local search query (kept inside StatefulBuilder)
    return StatefulBuilder(
      builder: (context, setSBState) {
        final qq = q.trim().toLowerCase();
        final filtered = qq.isEmpty
            ? rows
            : rows.where((t) {
                final name = _displayNameOf(t).toLowerCase();
                final email = (t.email ?? '').toLowerCase();
                final preview = (lastTextByPeer[t.peerId] ?? '').toLowerCase();
                return name.contains(qq) ||
                    email.contains(qq) ||
                    preview.contains(qq);
              }).toList();
        final onlineItems = rows
            .where((t) => t.peerId != null && (onlineByUser[t.peerId] == true))
            .toList();

        return Column(
          children: [
            _buildCustomHeader(
              context,
              searchQuery: q,
              onSearchChanged: (v) => setSBState(() => q = v),
              avatarUrl: myAvatarUrl,
              titleName: myName,
            ),
            Expanded(
              child: Container(
                color: Theme.of(context).colorScheme.surface,
                child: ListView(
                  padding: const EdgeInsets.only(top: 8),
                  children: [
                    // 🔹 Active Users Section
                    if (onlineItems.isNotEmpty) ...[
                    _buildStoriesSection(onlineItems),
                      const SizedBox(height: 8),
                      Divider(
                        height: 1,
                        thickness: 0.5,
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (filtered.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.chat_bubble_outline,
                                size: 64,
                                color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.5),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No conversations yet',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Start a new conversation',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      ...filtered.map((t) {
                // presence map ကနေ online flag (HomePage မှာ onlineByUser ပို့ထားရပါမယ်)
                final online =
                    t.peerId != null && (onlineByUser[t.peerId] == true);
                String preview = (lastTextByPeer[t.peerId] ?? '').trim();
                // Filter: Replace "📎 filename" with "Photo", "Video", or extract filename
                if (preview.isNotEmpty && preview.contains('📎')) {
                  final previewLower = preview.toLowerCase();
                  if (previewLower.contains('.jpg') || previewLower.contains('.jpeg') || 
                      previewLower.contains('.png') || previewLower.contains('.gif') || 
                      previewLower.contains('.webp') || previewLower.contains('.bmp')) {
                    preview = 'Photo';
                  } else if (previewLower.contains('.mp4') || previewLower.contains('.mov') || 
                             previewLower.contains('.avi') || previewLower.contains('.mkv') || 
                             previewLower.contains('.webm')) {
                    preview = 'Video';
                  } else {
                    // For other files, extract filename from "📎 filename" format
                    final index = preview.indexOf('📎');
                    if (index >= 0 && index + 2 < preview.length) {
                      final extractedName = preview.substring(index + 2).trim();
                      preview = extractedName.isNotEmpty ? extractedName : 'File';
                    } else {
                      preview = 'File';
                    }
                  }
                }
                final timeLabel = _timeLabel(t);
                final unreadCount = unreadByPeer[t.peerId] ?? 0;
                final hasUnread = unreadCount > 0;

                        return Slidable(
                          endActionPane: ActionPane(
                            motion: const DrawerMotion(),
                            extentRatio: 0.75,
                            children: [
                              // Archive (Folder) action
                              SlidableAction(
                                onPressed: (context) {
                                  // TODO: Implement archive functionality
                                  debugPrint('Archive chat: ${t.peerId}');
                                },
                                backgroundColor: Theme.of(context).colorScheme.primary,
                                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                                icon: Icons.folder,
                                label: 'Archive',
                                flex: 1,
                                borderRadius: BorderRadius.zero,
                              ),
                              // Delete action
                              SlidableAction(
                                onPressed: (context) {
                                  // TODO: Implement delete functionality
                                  debugPrint('Delete chat: ${t.peerId}');
                                },
                                backgroundColor: Theme.of(context).colorScheme.error,
                                foregroundColor: Theme.of(context).colorScheme.onError,
                                icon: Icons.delete,
                                label: 'Delete',
                                flex: 1,
                                borderRadius: BorderRadius.zero,
                              ),
                            ],
                          ),
                          child: InkWell(
                            onTap: () => onOpenChat(t),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(18),
                                boxShadow: [
                                  BoxShadow(
                                    color: Theme.of(context).colorScheme.shadow.withOpacity(0.1),
                                    blurRadius: 14,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                                border: hasUnread
                                    ? Border.all(
                                        color: Theme.of(context).colorScheme.primary.withOpacity(0.18),
                                        width: 1,
                                      )
                                    : null,
                              ),
                              child: Row(
                                children: [
                                  // Avatar
                                  AvatarWithStatus(
                                    avatarUrl: _getAvatarUrl(t.peerId),
                                    fallbackText: _initialOf(t),
                                    radius: 28,
                                    isOnline: online,
                                    imageKey: ValueKey('avatar_${t.peerId}_${_getAvatarUrl(t.peerId)}'),
                                  ),
                                  const SizedBox(width: 16),
                                  // Content
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                      child: Text(
                              _displayNameOf(t),
                                              style: TextStyle(
                                                fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w500,
                                fontSize: 16,
                                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                            const SizedBox(width: 8),
                                            Text(
                                              timeLabel,
                                    style: TextStyle(
                                              fontSize: 12,
                                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                                              fontWeight: hasUnread ? FontWeight.w600 : FontWeight.normal,
                                    ),
                                  ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                              children: [
                                            Expanded(
                                              child: preview.isEmpty
                                                  ? const SizedBox.shrink()
                                                  : Row(
                                                      children: [
                                                        // Message status icons
                                Builder(
                                  builder: (_) {
                                    final peer = t.peerId ?? '';
                                    if (lastFromByPeer[peer] != 'me')
                                      return const SizedBox.shrink();

                                    final isRead =
                                                              readLastByPeer[peer] == true;
                                    final isDouble =
                                        isRead ||
                                                              (deliveredLastByPeer[peer] == true);
                                    final icon = isDouble ? Icons.done_all : Icons.done;
                                    final color = isRead
                                        ? Theme.of(context).colorScheme.primary
                                                              : Theme.of(context).colorScheme.onSurfaceVariant;

                                                          return Padding(
                                                            padding: const EdgeInsets.only(right: 4),
                                                            child: Icon(icon, size: 16, color: color),
                                                          );
                                  },
                                ),
                                                        Expanded(
                                                          child: Text(
                                                            preview,
                                                            maxLines: 1,
                                                            overflow: TextOverflow.ellipsis,
                                                            style: TextStyle(
                                                              fontSize: 14,
                                                              color: hasUnread
                                                                  ? Theme.of(context).colorScheme.onSurface
                                                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                                                              fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                            ),
                                            if (hasUnread) ...[
                                const SizedBox(width: 8),
                                              _UnreadBadge(count: unreadCount),
                                            ],
                                          ],
                                        ),
                              ],
                            ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCustomHeader(
    BuildContext context, {
    String searchQuery = '',
    ValueChanged<String>? onSearchChanged,
    String? avatarUrl,
    String? titleName,
  }) {
    final primaryGradient = LinearGradient(
      colors: [
        Theme.of(context).colorScheme.primary,
        Theme.of(context).colorScheme.secondary,
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    final fallbackInitial = (titleName ?? 'U').characters.take(1).toString().toUpperCase();

    return Container(
      decoration: BoxDecoration(gradient: primaryGradient),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'CHATS',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onPrimary,
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Welcome to chat${titleName != null ? ' $titleName!' : ''}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onPrimary.withOpacity(0.8),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ProfilePage()),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).colorScheme.onPrimary.withOpacity(0.25),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.onPrimary.withOpacity(0.35),
                          width: 1,
                        ),
                      ),
                      child: CircleAvatar(
                        radius: 22,
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        child: ClipOval(
                          child: avatarUrl != null && avatarUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: avatarUrl,
                                  fit: BoxFit.cover,
                                  width: 44,
                                  height: 44,
                                  errorWidget: (_, __, ___) => _InitialAvatar(initial: fallbackInitial),
                                  placeholder: (_, __) => const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                )
                              : _InitialAvatar(initial: fallbackInitial),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(context).colorScheme.shadow.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: TextField(
                  controller: searchController,
                  textInputAction: TextInputAction.search,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 13,
                  ),
                  onChanged: (v) => onSearchChanged?.call(v),
                  decoration: InputDecoration(
                    hintText: 'Search or start new chat',
                    hintStyle: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 18,
                    ),
                    suffixIcon: searchQuery.isNotEmpty
                        ? IconButton(
                            icon: Icon(
                              Icons.clear,
                              size: 16,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                            onPressed: () {
                              searchController.clear();
                              onSearchChanged?.call('');
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: const BorderSide(color: Colors.transparent),
                    ),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    isDense: true,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStoriesSection(List<_Row> onlineItems) {
    if (onlineItems.isEmpty) {
      return const SizedBox.shrink();
    }
    
    return Builder(
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        const double avatarSize = 46;
        const double nameLineHeight = 12; // roughly text height for size 11
        const double spacingBelowAvatar = 4;
        final double listHeight = avatarSize + spacingBelowAvatar + nameLineHeight + 6; // extra padding
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          padding: const EdgeInsets.only(top: 6, bottom: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Active Users',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: listHeight,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shrinkWrap: true,
                  children: [
                    ...onlineItems.take(12).map(
                      (t) => Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildStoryItem(
                              context,
                              row: t,
                              onTap: () => onOpenChat(t),
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              width: 54,
                              child: Text(
                                _displayNameOf(t),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStoryItem(BuildContext context, {_Row? row, bool isAddButton = false, VoidCallback? onTap}) {
    if (isAddButton) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
              width: 2,
              style: BorderStyle.solid,
            ),
          ),
          child: Container(
            margin: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.surfaceVariant,
            ),
            child: Icon(Icons.add, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 30),
          ),
        ),
      );
    }

    if (row == null) return const SizedBox();

    final initial = _initialOf(row);
    final avatarUrl = _getAvatarUrl(row.peerId);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.primary,
              Theme.of(context).colorScheme.secondary,
            ],
          ),
        ),
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context).colorScheme.primaryContainer,
          ),
          child: ClipOval(
            child: avatarUrl != null && avatarUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: avatarUrl,
                    width: 46,
                    height: 46,
                    fit: BoxFit.cover,
                    errorWidget: (context, url, error) => CircleAvatar(
                      radius: 23,
                      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                      child: Text(
                        initial,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    placeholder: (context, url) => CircleAvatar(
                      radius: 23,
                      backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  )
                : CircleAvatar(
                    radius: 23,
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                    child: Text(
                      initial,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// =======================================================
// RequestsTab (separate page)
// =======================================================
class RequestsTab extends StatelessWidget {
  final List<_Row> rows;
  final bool loading;
  final String? errorText;
  final void Function(_Row) onAccept;
  final void Function(_Row) onDeclineOrCancel;

  const RequestsTab({
    super.key,
    required this.rows,
    required this.loading,
    required this.errorText,
    required this.onAccept,
    required this.onDeclineOrCancel,
  });

  String _displayNameOf(_Row t) => (t.name?.trim().isNotEmpty ?? false)
      ? t.name!.trim()
      : (t.email ?? 'Unknown');

  String _initialOf(_Row t) {
    final s = _displayNameOf(t);
    if (s.isEmpty) return '?';
    final cp = s.runes.first;
    return String.fromCharCode(cp).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (errorText != null && errorText!.isNotEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
          ),
        ],
      );
    }
    if (rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('No pending requests'),
        ),
      );
    }

    final incoming = rows.where((r) => r.isIncoming == true).toList();
    final outgoing = rows.where((r) => r.isIncoming != true).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Friend requests', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (incoming.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text('— None —'),
          )
        else
          ...incoming.map(
            (t) => Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.secondaryContainer,
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onSecondaryContainer,
                  child: Text(
                    _initialOf(t),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                title: Text(_displayNameOf(t)),
                subtitle: const Text('Wants to friend'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.red),
                      tooltip: 'Decline',
                      onPressed: () => onDeclineOrCancel(t),
                    ),
                    IconButton(
                      icon: const Icon(Icons.check, color: Colors.green),
                      tooltip: 'Accept',
                      onPressed: () => onAccept(t),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// =======================================================
// FriendsTab (searchable friends list)
// =======================================================
class FriendsTab extends StatelessWidget {
  final List<_Row> rows; // active conversations → friends
  final bool loading;
  final String? errorText;
  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final void Function(String partnerId) onOpen;
  final Map<String, bool> onlineByUser;
  final Map<String, dynamic> idMap;
  final VoidCallback? onInviteFriends;
  const FriendsTab({
    super.key,
    required this.rows,
    required this.loading,
    required this.errorText,
    required this.controller,
    required this.query,
    required this.onQueryChanged,
    required this.onOpen,
    required this.onlineByUser,
    required this.idMap,
    this.onInviteFriends,
  });

  String? _getAvatarUrl(String? uid) {
    if (uid == null || uid.isEmpty) return null;
    final m = idMap[uid];
    if (m == null) return null;
    final avatarUrl = (m['avatarUrl'] ?? '').toString().trim();
    if (avatarUrl.isEmpty) return null;
    
    // AvatarUrl already includes timestamp if it was updated via socket event
    // This ensures immediate cache refresh when profile is updated
    return avatarUrl;
  }

  List<_Row> _dedupAndSort(List<_Row> input) {
    final map = <String, _Row>{};
    for (final r in input) {
      final id = r.peerId ?? '';
      if (id.isEmpty) continue;
      final prev = map[id];
      if (prev == null || r.sortKey > prev.sortKey) {
        map[id] = r; // keep most recent per friend
      }
    }
    final list = map.values.toList();
    list.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (errorText != null && errorText!.isNotEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
          ),
        ],
      );
    }

    final base = _dedupAndSort(rows);
    final queryLower = query.trim().toLowerCase();
    final items = queryLower.isEmpty
        ? base
        : base.where((r) {
            final name = (r.name ?? '').toLowerCase();
            final email = (r.email ?? '').toLowerCase();
            return name.contains(queryLower) || email.contains(queryLower);
          }).toList();

    // Calculate item count: friends + empty state
    final itemCount = (items.isEmpty ? 1 : items.length);

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: itemCount,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        // Friends section
        final friendIdx = i;

        if (items.isEmpty && friendIdx == 0) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 48.0),
            child: Center(
              child: Text(
                'No matches',
                style: TextStyle(
                  fontSize: 15,
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6),
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          );
        }
        if (friendIdx < 0 || friendIdx >= items.length) {
          return const SizedBox.shrink();
        }
        final r = items[friendIdx];
        final online = (r.peerId != null) && (onlineByUser[r.peerId] == true);

        final display = (r.name?.trim().isNotEmpty ?? false)
            ? r.name!
            : (r.email ?? r.peerId ?? 'Unknown');
        final initial = display.isNotEmpty
            ? display.characters.first.toUpperCase()
            : '?';
        final avatarUrl = _getAvatarUrl(r.peerId);
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 10,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: AvatarWithStatus(
              avatarUrl: avatarUrl,
              fallbackText: initial,
              radius: 24,
              isOnline: online,
              imageKey: ValueKey('avatar_${r.peerId}_$avatarUrl'),
            ),
            title: Text(
              display,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                online ? 'online' : 'offline',
                style: TextStyle(
                  color: online
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                ),
              ),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.5),
              size: 20,
            ),
            onTap: () {
              if (r.peerId != null) onOpen(r.peerId!);
            },
          ),
        );
      },
    );
  }

  Future<void> _fetchPresenceForContacts(List<String> contactIds) async {
    try {
      final res = await getJson(
        '/presence?ids=${contactIds.join(",")}&verbose=true',
      ).timeout(const Duration(seconds: 5));
      
      if (res.statusCode == 200) {
        final presenceMap = Map<String, dynamic>.from(jsonDecode(res.body));
        debugPrint('📡 Presence data received: ${presenceMap.keys.length} users');
        
        // Update idMap with presence data including lastSeen
        presenceMap.forEach((k, v) {
          if (v is Map) {
            // Update online status
            onlineByUser[k] = v['online'] == true;
            
            // Store lastSeen from presence data (use 'at' field as lastSeen)
            if (v['at'] != null) {
              if (!idMap.containsKey(k)) {
                idMap[k] = <String, dynamic>{};
              }
              idMap[k]!['lastSeen'] = v['at'];
              debugPrint('✅ Stored lastSeen for $k: ${v['at']}');
            } else {
              debugPrint('⚠️ No lastSeen data for $k');
            }
          } else if (v is bool) {
            onlineByUser[k] = v;
          }
        });
      } else {
        debugPrint('❌ Failed to fetch presence: ${res.statusCode}');
      }
    } catch (e) {
      debugPrint('❌ Error fetching presence for contacts: $e');
    }
  }

  String _formatLastSeen(String? userId) {
    if (userId == null || userId.isEmpty) return 'last seen recently';
    
    // Check if user is online
    if (onlineByUser[userId] == true) {
      return 'online';
    }
    
    // Get last seen from idMap
    final userData = idMap[userId];
    if (userData == null) {
      return 'last seen recently';
    }
    
    // Try to get lastSeen from idMap (can be from /users/by-ids or /presence)
    String? lastSeenStr = userData['lastSeen']?.toString();
    
    // If not found, return a default "last seen" message instead of "offline"
    if (lastSeenStr == null || lastSeenStr.isEmpty || lastSeenStr == 'null') {
      return 'last seen recently';
    }
    
    try {
      final lastSeen = DateTime.tryParse(lastSeenStr);
      if (lastSeen == null) {
        debugPrint('❌ Failed to parse lastSeen: $lastSeenStr for user $userId');
        return 'last seen recently';
      }
      
      final now = DateTime.now();
      final difference = now.difference(lastSeen);
      
      if (difference.inMinutes < 1) {
        return 'last seen just now';
      } else if (difference.inMinutes < 60) {
        return 'last seen ${difference.inMinutes} ${difference.inMinutes == 1 ? 'minute' : 'minutes'} ago';
      } else if (difference.inHours < 24) {
        return 'last seen ${difference.inHours} ${difference.inHours == 1 ? 'hour' : 'hours'} ago';
      } else if (difference.inDays < 7) {
        return 'last seen ${difference.inDays} ${difference.inDays == 1 ? 'day' : 'days'} ago';
      } else {
        return 'last seen a long time ago';
      }
    } catch (e) {
      debugPrint('❌ Error formatting lastSeen: $e for user $userId');
      return 'last seen recently';
    }
  }

}

// =======================================================
// Shared models & widgets
// =======================================================
// Shared models & widgets
class _Row {
  final String conversationId;
  final String? peerId;
  final String? name;
  final String? email;
  final String label;
  final bool isPending;
  final bool? isIncoming; // pending only; true=I can accept/decline
  final int sortKey;
  final String? createdBy; // for reference
  _Row({
    required this.conversationId,
    required this.peerId,
    this.name,
    this.email,
    required this.label,
    required this.isPending,
    required this.isIncoming,
    required this.sortKey,
    required this.createdBy,
  });
}

class _GradientPillNav extends StatelessWidget {
  final int selectedIndex;
  final int totalUnread;
  final int contactsBadge;
  final ValueChanged<int> onTap;

  const _GradientPillNav({
    required this.selectedIndex,
    required this.totalUnread,
    required this.contactsBadge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final badgeColor = Theme.of(context).colorScheme.error;
    final cs = Theme.of(context).colorScheme;

    Widget buildBadge(int count) {
      if (count <= 0) return const SizedBox.shrink();
      return Positioned(
        right: 6,
        top: 6,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: badgeColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    Widget item({
      required int index,
      required IconData icon,
      required String label,
      int badge = 0,
    }) {
      final active = selectedIndex == index;
      return Expanded(
        child: GestureDetector(
          onTap: () => onTap(index),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: active 
                  ? Theme.of(context).colorScheme.onPrimary.withOpacity(0.12) 
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      color: Theme.of(context).colorScheme.onPrimary,
                      size: active ? 22 : 19,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary.withOpacity(active ? 1 : 0.85),
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 11,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ],
                ),
                if (badge > 0) buildBadge(badge),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.secondary,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withOpacity(0.25),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          item(
            index: 0,
            icon: Icons.chat_bubble_rounded,
            label: 'Chats',
            badge: totalUnread,
          ),
          item(
            index: 1,
            icon: Icons.contacts_rounded,
            label: 'Contacts',
            badge: contactsBadge,
          ),
          item(
            index: 2,
            icon: Icons.call_rounded,
            label: 'Calls',
          ),
        ],
      ),
    );
  }
}

class _InitialAvatar extends StatelessWidget {
  final String initial;
  const _InitialAvatar({required this.initial});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 22,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: Text(
        initial,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 18,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          '$count',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _NewChatDialog extends StatefulWidget {
  const _NewChatDialog({super.key});
  @override
  State<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<_NewChatDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      elevation: 0,
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            // Outer purple glow
            BoxShadow(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.28),
              blurRadius: 32,
              spreadRadius: 1,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: Theme.of(context).colorScheme.shadow.withOpacity(0.1),
              blurRadius: 18,
              offset: const Offset(0, 6),
              spreadRadius: 0,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Modern Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 24, 20, 20),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: colorScheme.outline.withOpacity(0.08),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Add Contact',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => Navigator.pop(context),
                      borderRadius: BorderRadius.circular(20),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.close_rounded,
                          color: colorScheme.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Form Content
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Name Field - Modern filled style
                    TextFormField(
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      style: TextStyle(
                        fontSize: 15,
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w400,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Name (optional)',
                        hintStyle: TextStyle(
                          fontSize: 15,
                          color: colorScheme.onSurfaceVariant.withOpacity(0.6),
                        ),
                        prefixIcon: Icon(
                          Icons.person_outline_rounded,
                          color: colorScheme.onSurfaceVariant.withOpacity(0.7),
                          size: 22,
                        ),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: colorScheme.primary.withOpacity(0.35),
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Phone Field - Modern filled style
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.done,
                      style: TextStyle(
                        fontSize: 15,
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w400,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Phone Number',
                        hintStyle: TextStyle(
                          fontSize: 15,
                          color: colorScheme.onSurfaceVariant.withOpacity(0.6),
                        ),
                        prefixIcon: Icon(
                          Icons.phone_outlined,
                          color: colorScheme.onSurfaceVariant.withOpacity(0.7),
                          size: 22,
                        ),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: colorScheme.primary.withOpacity(0.35),
                            width: 1.5,
                          ),
                        ),
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: colorScheme.error,
                            width: 1,
                          ),
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: colorScheme.error,
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Enter phone number';
                        }
                        // Basic phone validation (at least 10 digits)
                        final digits = v.replaceAll(RegExp(r'[^\d+]'), '');
                        if (digits.length < 10) {
                          return 'Enter a valid phone number';
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) {
                        if (_form.currentState!.validate()) {
                          Navigator.pop(context, _phone.text.trim());
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            // Modern Action Buttons
            Container(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: colorScheme.outline.withOpacity(0.08),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      if (_form.currentState!.validate()) {
                        Navigator.pop(context, _phone.text.trim());
                      }
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      'Save',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

