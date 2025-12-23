// lib/services/call_state_service.dart
// Global call state management for Telegram/Viber-like calling logic

import 'package:flutter/foundation.dart';

/// Global call state service - tracks active call data
/// Similar to Telegram/Viber: only shows CallKit in background, navigates on resume if call is still active
class CallStateService {
  CallStateService._();
  static final CallStateService instance = CallStateService._();

  /// Active call data - set when call starts, cleared when call ends/cancelled
  /// Format: { callId, from, sdp, kind, timestamp, receivedAt }
  Map<String, dynamic>? _activeCallData;

  /// Get active call data
  Map<String, dynamic>? get activeCallData => _activeCallData;

  /// Check if there's an active call
  bool get hasActiveCall => _activeCallData != null;

  /// Get call ID from active call data
  String? get activeCallId => _activeCallData?['callId']?.toString();

  /// Set active call data (when call is received)
  void setActiveCall({
    required String callId,
    required String from,
    required Map<String, dynamic> sdp,
    required String kind,
    int? timestamp,
  }) {
    _activeCallData = {
      'callId': callId,
      'from': from,
      'sdp': sdp,
      'kind': kind,
      'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
      'receivedAt': DateTime.now().millisecondsSinceEpoch,
    };
    debugPrint('📞 CallStateService: Active call set - callId: $callId, from: $from');
  }

  /// Clear active call data (when call ends/cancelled)
  void clearActiveCall() {
    if (_activeCallData != null) {
      final callId = _activeCallData!['callId']?.toString() ?? 'unknown';
      debugPrint('📞 CallStateService: Active call cleared - callId: $callId');
      _activeCallData = null;
    }
  }

  /// Clear active call by call ID (for specific call cancellation)
  void clearActiveCallById(String callId) {
    if (_activeCallData != null && _activeCallData!['callId']?.toString() == callId) {
      debugPrint('📞 CallStateService: Active call cleared by ID - callId: $callId');
      _activeCallData = null;
    }
  }
}

