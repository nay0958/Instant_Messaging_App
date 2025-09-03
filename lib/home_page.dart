import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'auth_store.dart';
import 'login_page.dart';
import 'socket_service.dart';
import 'chat_page.dart';
import 'notifications.dart';
import 'foreground_chat.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Map<String, dynamic>? me;

  // Tabs: 0 = Chats, 1 = Requests
  int _tabIndex = 0;

  // Loading & error
  bool loadingProfile = true;
  bool loadingActive = true;
  bool loadingPending = true;
  String? activeError;
  String? pendingError;

  // Data
  List<_Row> activeRows = [];
  List<_Row> pendingRows = [];
  Map<String, dynamic> idMap = {}; // userId -> {name,email}

  // last text preview & unread counters (key = peerId)
  final Map<String, String> _lastTextByPeer = {};
  final Map<String, int> _unreadByPeer = {};

  @override
  void initState() {
    super.initState();
    _boot();
  }

  // -------- Utils --------
  int _ts(String? s) => DateTime.tryParse(s ?? '')?.millisecondsSinceEpoch ?? 0;

  Future<void> _boot() async {
    try {
      final t = await AuthStore.getToken();
      if (t == null) return _toLogin();

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

      SocketService.I.connect(baseUrl: apiBase, token: t);

      // ---- socket events (registered once in shell) ----

      // Request arrived → Noti + refresh Requests tab
      SocketService.I.on('chat_request', (data) async {
        try {
          final myId = me?['id']?.toString();
          final m = Map<String, dynamic>.from(data);
          final toId = m['to']?.toString();
          final fromId = m['from']?.toString();
          final convId = (m['_id'] ?? '').toString();
          if (toId != myId) return;

          // ensure we know sender's name/email
          await _ensureProfiles([fromId ?? '']);
          final who = _nameOrEmail(fromId) ?? 'Someone';

          await Noti.showIfNew(
            messageId: 'req_$convId',
            title: 'New chat request',
            body: '$who wants to chat',
            payload: {
              'type': 'request',
              'conversationId': convId,
              'fromId': fromId ?? '',
            },
          );

          // switch to Requests tab (optional UX)
          if (mounted) setState(() => _tabIndex = 1);

          await _loadPending();
        } catch (_) {}
      });

      // Request accepted → Noti + refresh lists
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
          await Future.wait([_loadActive(), _loadPending()]);
        } catch (_) {}
      });

      // Message → preview/unread + refresh Chats list (reorder by lastMessageAt)
      SocketService.I.on('message', (data) async {
        try {
          final m = Map<String, dynamic>.from(data);
          final myId = me?['id']?.toString();
          final fromId = m['from']?.toString();
          final toId = m['to']?.toString();
          final text = (m['text'] ?? '').toString();

          final isSender = fromId == myId;
          final isReceiver = toId == myId;

          if (isReceiver) {
            if (ForegroundChat.currentPeerId != fromId) {
              await Noti.showIfNew(
                messageId: (m['_id'] ?? '').toString(),
                title: 'New message',
                body: text,
                payload: {'fromId': fromId ?? ''},
              );
              if (fromId != null && fromId.isNotEmpty) {
                _unreadByPeer[fromId] = (_unreadByPeer[fromId] ?? 0) + 1;
              }
            }
            if (fromId != null && fromId.isNotEmpty) {
              _lastTextByPeer[fromId] = text;
            }
          }

          if (isSender && toId != null && toId.isNotEmpty) {
            _lastTextByPeer[toId] = text;
          }

          if (mounted) setState(() {});
          await _loadActive();
        } catch (_) {}
      });

      // initial loads
      await Future.wait([_loadActive(), _loadPending()]);
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

      // collect ids
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
      }
      list.sort((a, b) => b.sortKey.compareTo(a.sortKey));

      setState(() {
        activeRows = list;
      });
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
      idMap.addAll(map);
      if (mounted) setState(() {});
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

  // ===== Request actions =====
  Future<void> _accept(_Row t) async {
    final r = await postJson('/chat-requests/${t.conversationId}/accept', {
      'me': me!['id'],
    });
    if (r.statusCode == 200) {
      await Future.wait([_loadActive(), _loadPending()]);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatPage(
            peerId: t.peerId!,
            partnerEmail: t.email ?? t.peerId!,
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

  // ===== New request (by email) =====
  Future<void> _startNewRequest() async {
    final email = await showDialog<String>(
      context: context,
      builder: (_) => const _NewChatDialog(),
    );
    if (email == null || email.trim().isEmpty) return;
    final u = await AuthStore.getUser();
    final res = await postJson('/chat-requests', {
      'from': u!['id'],
      'toEmail': email.trim(),
    });
    if (res.statusCode == 200) {
      _toast('Request sent to $email');
      await _loadPending();
      if (mounted) setState(() => _tabIndex = 1);
    } else if (res.statusCode == 404) {
      _toast('No user for $email');
    } else {
      _toast('Send request failed (${res.statusCode})');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final unreadTotal = _unreadByPeer.values.fold<int>(0, (a, b) => a + b);
    final pendingCount = pendingRows.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(_tabIndex == 0 ? 'Chats' : 'Requests'),
        actions: [
          IconButton(onPressed: _logout, icon: const Icon(Icons.logout)),
        ],
      ),

      body: RefreshIndicator(
        onRefresh: () async =>
            await Future.wait([_loadActive(), _loadPending()]),
        child: IndexedStack(
          index: _tabIndex,
          children: [
            // ===== Chats page =====
            ChatsTab(
              rows: activeRows,
              loading: loadingActive,
              errorText: activeError,
              lastTextByPeer: _lastTextByPeer,
              unreadByPeer: _unreadByPeer,
              onOpenChat: (_Row t) {
                if (t.peerId != null) {
                  setState(() => _unreadByPeer.remove(t.peerId));
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatPage(
                      peerId: t.peerId!,
                      partnerEmail: t.email ?? t.peerId!,
                      peerName: t.name ?? t.email ?? t.peerId!,
                    ),
                  ),
                );
              },
            ),

            // ===== Requests page =====
            RequestsTab(
              rows: pendingRows,
              loading: loadingPending,
              errorText: pendingError,
              onAccept: _accept,
              onDeclineOrCancel: _declineOrCancel,
            ),
          ],
        ),
      ),

      // FAB changes by tab
      floatingActionButton: FloatingActionButton.extended(
        icon: Icon(_tabIndex == 0 ? Icons.message : Icons.person_add),
        label: Text(_tabIndex == 0 ? 'Message' : 'New request'),
        onPressed: () async {
          if (_tabIndex == 0) {
            // Chats tab → start request then jump to chat
            final email = await showDialog<String>(
              context: context,
              builder: (_) => const _NewChatDialog(),
            );
            if (email == null || email.trim().isEmpty) return;
            final u = await AuthStore.getUser();
            await postJson('/chat-requests', {
              'from': u!['id'],
              'toEmail': email.trim(),
            });
            if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatPage(
                  partnerEmail: email.trim(),
                  peerName: email.trim(),
                ),
              ),
            );
          } else {
            // Requests tab → just create request and stay
            await _startNewRequest();
          }
        },
      ),

      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: unreadTotal > 0 ? 'Chats ($unreadTotal)' : 'Chats',
          ),
          NavigationDestination(
            icon: const Icon(Icons.inbox_outlined),
            selectedIcon: const Icon(Icons.inbox),
            label: pendingCount > 0 ? 'Requests ($pendingCount)' : 'Requests',
          ),
        ],
      ),

      backgroundColor: cs.surfaceContainerLowest,
    );
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
}

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

  const ChatsTab({
    super.key,
    required this.rows,
    required this.loading,
    required this.errorText,
    required this.lastTextByPeer,
    required this.unreadByPeer,
    required this.onOpenChat,
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
    if (errorText != null && errorText!.isNotEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Colors.red.withOpacity(.08),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                errorText!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ),
        ],
      );
    }
    if (loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('No active chats'),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Active chats', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...rows.map(
          (t) => Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                foregroundColor: Theme.of(
                  context,
                ).colorScheme.onPrimaryContainer,
                child: Text(
                  _initialOf(t),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              title: Text(_displayNameOf(t)),
              subtitle: Text(
                lastTextByPeer[t.peerId] ?? 'Active chat',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _UnreadBadge(count: (unreadByPeer[t.peerId] ?? 0)),
              onTap: () => onOpenChat(t),
            ),
          ),
        ),
      ],
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
            color: Colors.red.withOpacity(.08),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                errorText!,
                style: const TextStyle(color: Colors.red),
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
        Text('Incoming', style: Theme.of(context).textTheme.titleMedium),
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
                subtitle: const Text('Wants to chat'),
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

        const SizedBox(height: 16),
        Text('Outgoing', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (outgoing.isEmpty)
          const Text('— None —')
        else
          ...outgoing.map(
            (t) => Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.tertiaryContainer,
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onTertiaryContainer,
                  child: Text(
                    _initialOf(t),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                title: Text(_displayNameOf(t)),
                subtitle: const Text('Awaiting acceptance'),
                trailing: TextButton.icon(
                  onPressed: () => onDeclineOrCancel(t),
                  icon: const Icon(Icons.cancel),
                  label: const Text('Cancel'),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// =======================================================
// Shared models & widgets
// =======================================================
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

class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
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
  final _email = TextEditingController();
  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Start new chat'),
      content: Form(
        key: _form,
        child: TextFormField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Peer email',
            prefixIcon: Icon(Icons.email),
          ),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'Enter email' : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_form.currentState!.validate()) {
              Navigator.pop(context, _email.text.trim());
            }
          },
          child: const Text('Send request'),
        ),
      ],
    );
  }
}
