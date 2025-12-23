// backend/src/index.js
import express from 'express';
import mongoose from 'mongoose';
import cors from 'cors';
import dotenv from 'dotenv';
import http from 'http';
import jwt from 'jsonwebtoken';
import { Server as SocketIOServer } from 'socket.io';
import bcrypt from 'bcrypt';
import multer from 'multer';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

import User from './models/User.js';
import Message from './models/Message.js';
import Conversation from './models/Conversation.js';
import authRoutes from './auth.js';
import { sendMessageNotification, sendCallNotification, sendCallEndedNotification, initializeFirebaseOnStartup } from './fcm.js';

// Helper function to normalize phone (same logic as in auth.js)
// Always returns "+<digits>"
const normalizePhone = (phone) => {
  if (!phone) return '';
  const raw = phone.toString().trim();
  const digits = raw.replace(/\D/g, '');
  if (!digits) return '';
  return `+${digits}`;
};

dotenv.config();

const MONGODB_URI = process.env.MONGODB_URI || 'mongodb://127.0.0.1:27017/messaging';

// MongoDB connection with error handling
try {
await mongoose.connect(MONGODB_URI);
console.log('✅ MongoDB connected:', MONGODB_URI);
  
  // Verify connection
  const dbState = mongoose.connection.readyState;
  const states = { 0: 'disconnected', 1: 'connected', 2: 'connecting', 3: 'disconnecting' };
  console.log('📊 MongoDB state:', states[dbState] || 'unknown');
  
  // Test query to verify database is accessible
  const testUser = await User.findOne().limit(1).lean();
  console.log('✅ Database query test successful');
} catch (error) {
  console.error('❌ MongoDB connection error:', error);
  console.error('Please ensure MongoDB is running and accessible at:', MONGODB_URI);
  process.exit(1);
}

// Handle connection events
mongoose.connection.on('error', (err) => {
  console.error('❌ MongoDB connection error:', err);
});

mongoose.connection.on('disconnected', () => {
  console.warn('⚠️ MongoDB disconnected');
});

mongoose.connection.on('reconnected', () => {
  console.log('✅ MongoDB reconnected');
});

// Initialize Firebase Admin SDK on server startup
console.log('🔥 Initializing Firebase Admin SDK...');
initializeFirebaseOnStartup();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Create uploads directory if it doesn't exist
const uploadsDir = path.join(__dirname, '../uploads');
if (!fs.existsSync(uploadsDir)) {
  fs.mkdirSync(uploadsDir, { recursive: true });
}

// Configure multer for file uploads
const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    cb(null, uploadsDir);
  },
  filename: (req, file, cb) => {
    const uniqueSuffix = Date.now() + '-' + Math.round(Math.random() * 1E9);
    cb(null, uniqueSuffix + path.extname(file.originalname));
  },
});

const upload = multer({
  storage: storage,
  limits: { fileSize: 50 * 1024 * 1024 }, // 50MB limit
});

const app = express();
app.use(cors());
app.use(express.json());
app.use('/auth', authRoutes);
// Serve uploaded files statically
app.use('/uploads', express.static(uploadsDir));

const server = http.createServer(app);
const io = new SocketIOServer(server, { cors: { origin: '*' } });
const JWT_SECRET = process.env.JWT_SECRET || 'devsecret';

// ---- helpers ----
const pair = (a, b) => {
  const A = String(a), B = String(b);
  return A < B ? [A, B] : [B, A];
};

async function recomputeLastMessageAt(conversationId) {
  if (!conversationId) return;
  const last = await Message.find(
    { conversation: conversationId, deleted: { $ne: true } },
    { _id: 1, createdAt: 1 }
  ).sort({ createdAt: -1 }).limit(1).lean();

  if (last.length) {
    await Conversation.updateOne(
      { _id: conversationId },
      { $max: { lastMessageAt: last[0].createdAt }, $set: { updatedAt: new Date() } }
    );
  } else {
    await Conversation.updateOne(
      { _id: conversationId },
      { $unset: { lastMessageAt: 1 }, $set: { updatedAt: new Date() } }
    );
  }
}


const requireAuth = (req, res, next) => {
  try {
    const raw = (req.headers.authorization || '').replace('Bearer ', '');
    const { uid } = jwt.verify(raw, JWT_SECRET);
    req.user = { uid: String(uid) };
    next();
  } catch {
    res.status(401).json({ error: 'invalid_token' });
  }
};

// Normalize phone number (same as in auth.js)
const normalizePhoneNumber = (phone) => {
  return phone.replace(/[^\d+]/g, '');
};

const uidByPhone = async (phone) => {
  const normalized = normalizePhoneNumber(phone);
  const u = await User.findOne({ phone: normalized }).select('_id').lean();
  return u?._id ? String(u._id) : null;
};

function setOnline(uid, isOnline) {
  const at = new Date();
  lastPresenceAt.set(String(uid), at);  // ✅ remember when it changed
  io.emit('presence', {
    uid: String(uid),
    online: !!isOnline,
    at: at.toISOString(),               // ✅ send timestamp to clients
  });
}
// ---- helpers: emit to a user's all sockets ----
function emitTo(uid, ev, payload) {
  io.to(String(uid)).emit(ev, payload);
}


// ---- helpers အောက်ဘက်ဘက် လားပတ်တစ်နေရာက ထည့်ပါ ----
async function catchupDelivered(uid) {
  try {
    const U = new mongoose.Types.ObjectId(uid);

    // receiver (uid) ဆီ သာရောက်မယ့် msg တွေနဲ့ per-conversation နောက်ဆုံးထိပ်ကို ယူ
    const groups = await Message.aggregate([
      { $match: { to: U, deleted: { $ne: true } } },
      { $sort: { createdAt: -1 } },
      { $group: {
          _id: '$conversation',
          lastId:  { $first: '$_id' },
          lastAt:  { $first: '$createdAt' },
          from:    { $first: '$from' },
        }
      },
    ]);

    if (!groups.length) return;

    const convIds = groups.map(g => g._id).filter(Boolean);
    const convs = await Conversation
      .find({ _id: { $in: convIds } })
      .select('deliveredUpTo')
      .lean();

    const deliveredMap = {};
    for (const c of convs) {
      const v = (c.deliveredUpTo || {})[uid];
      deliveredMap[String(c._id)] = v ? new Date(v) : null;
    }

    for (const g of groups) {
      if (!g || !g._id || !g.lastAt) continue;
      const cid = String(g._id);
      const prev = deliveredMap[cid];          // deliveredUpTo[uid] ရှိ/မရှိ
      const lastAt = new Date(g.lastAt);
      if (!prev || lastAt > prev) {
        // persist cursor
        await Conversation.updateOne(
          { _id: g._id },
          { $max: { [`deliveredUpTo.${uid}`]: lastAt }, $set: { updatedAt: new Date() } }
        );
        // notify sender (from)
        io.to(String(g.from)).emit('delivered', {
          messageId: String(g.lastId),
          conversationId: cid,
          by: String(uid),
          at: lastAt.toISOString(),
        });
      }
    }
  } catch (e) {
    console.error('catchupDelivered error:', e);
  }
 }


// ---- socket auth & presence ----
// ==== CALL state (TOP-LEVEL; NOT inside io.on) ====
const activeCalls = new Map(); // callId -> { a, b, startedAt }
const userToCall = new Map();  // uid -> callId (busy check)
const newCallId = () => Math.random().toString(36).slice(2, 10);

const onlineCounts = new Map();
const lastPresenceAt = new Map(); 
// function setOnline(uid, isOnline) {
//   io.emit('presence', { uid: String(uid), online: !!isOnline, at: new Date().toISOString() });
// }

io.use((socket, next) => {
  try {
    const { uid } = jwt.verify(socket.handshake.auth?.token, JWT_SECRET);
    socket.data.uid = String(uid);
    next();
  } catch {
    next(new Error('unauthorized'));
  }
});



io.on('connection', (socket) => {
  const uid = socket.data.uid;
  console.log('🔗 connected:', uid);
  socket.join(uid);

  // presence count
  const c = (onlineCounts.get(uid) || 0) + 1;
  onlineCounts.set(uid, c);
  if (c === 1) setOnline(uid, true);

  // ✅ offline အချိန်က ပို့ထားတာတွေကို delivered catch-up
  catchupDelivered(uid);

  // ========== Call helpers (in-connection only) ==========
  function cleanupCall(callId) {
    const s = activeCalls.get(callId);
    if (!s) return;
    if (s.timer) clearTimeout(s.timer);
    userToCall.delete(s.a);
    userToCall.delete(s.b);
    activeCalls.delete(callId);
  }

  // ========= Delivered (ရှိပီးသား) =========
  socket.on('delivered', async (data = {}) => {
    try {
      const { messageId } = data || {};
      if (!messageId) return;
      const msg = await Message.findById(messageId)
        .select('_id from to conversation createdAt')
        .lean();
      if (!msg) return;
      const by = String(msg.to); // receiver
      const ts = msg.createdAt;
      await Conversation.updateOne(
        { _id: msg.conversation },
        { $max: { [`deliveredUpTo.${by}`]: ts }, $set: { updatedAt: new Date() } }
      );
      io.to(String(msg.from)).emit('delivered', {
        messageId: String(msg._id),
        conversationId: String(msg.conversation || ''),
        by,
        at: ts.toISOString(),
      });
    } catch (e) {
      console.error('delivered err', e);
    }
  });

  // ========= Typing (ရှိပီးသား) =========
  socket.on('typing', async (data = {}) => {
    try {
      const from = String(socket.data.uid);
      const to = (data.to ?? '').toString();           // ✅ receiver uid (peer)
      const typing = data.typing === true;             // true/false
      const conversationId = (data.conversationId ?? '').toString();
      if (!to) return;

      io.to(to).emit('typing', {
        from,
        conversationId: conversationId || null,
        typing,
        at: new Date().toISOString(),
      });
    } catch (e) {
      console.error('typing err', e);
    }
  });

  // ========= Read up to (ရှိပီးသား) =========
  socket.on('read_up_to', async (data = {}) => {
    try {
      const { conversationId, by, at } = data || {};
      if (!conversationId || !by) return;
      const ts = at ? new Date(at) : new Date();
      await Conversation.updateOne(
        { _id: conversationId },
        { $max: { [`readUpTo.${String(by)}`]: ts }, $set: { updatedAt: new Date() } }
      );
      const convo = await Conversation.findById(conversationId).select('participants').lean();
      if (!convo) return;
      for (const p of convo.participants) {
        const pid = String(p);
        if (pid !== String(by)) {
          io.to(pid).emit('read_up_to', {
            conversationId: String(conversationId),
            by: String(by),
            at: ts.toISOString(),
          });
        }
      }
    } catch (e) {
      console.error('read_up_to err', e);
    }
  });

  // ========== NEW: WebRTC voice call (call:* events) ==========
// ========== WebRTC voice/video call (call:* events) ==========
socket.on('call:invite', async (data = {}) => {
  try {
    console.log(`📞 call:invite received from ${uid}:`, { to: data.to, kind: data.kind });
    
    const from = String(uid);
    const to   = (data.to || '').toString();
    const sdp  = data.sdp; // { type, sdp }
    const kind = (data.kind || 'audio'); // 👈 'audio' | 'video'
    
    if (!to || !sdp?.type || !sdp?.sdp) {
      console.log(`⚠️ call:invite rejected - missing fields: to=${to}, hasSdp=${!!sdp}`);
      return;
    }

    if (userToCall.has(from) || userToCall.has(to)) {
      console.log(`⚠️ call:invite rejected - user busy: from=${userToCall.has(from)}, to=${userToCall.has(to)}`);
      // Use volatile for call:busy - drop if client is not connected
      io.to(from).volatile.emit('call:busy', { to });
      return;
    }

    const callId = newCallId();
    console.log(`📞 Creating call session: callId=${callId}, from=${from}, to=${to}, kind=${kind}`);
    
    const session = {
      callId, a: from, b: to,
      state: 'ringing',
      kind,                        // 👈 store the mode
      startedAt: new Date(),
      timer: null,
    };
    activeCalls.set(callId, session);
    userToCall.set(from, callId);
    userToCall.set(to, callId);

    // CRITICAL: Use volatile.emit for call:incoming event
    // Volatile messages are NOT queued by Socket.io - they are discarded if the client is offline
    // This is crucial because:
    // 1. Old call events should NOT be buffered and delivered late when user reconnects
    // 2. If user is offline, the message is dropped (not stored for later delivery)
    // 3. This prevents stale call notifications when app resumes from background
    // 4. FCM push notifications handle calls when socket is disconnected
    // 
    // Without volatile.emit, Socket.io would buffer the message and deliver it when user reconnects,
    // causing ghost UI issues where old calls appear after they've already ended
    const callTimestamp = Date.now(); // Timestamp when call was initiated
    io.to(to).volatile.emit('call:incoming', { 
      callId, 
      from, 
      sdp, 
      kind,
      timestamp: callTimestamp  // Timestamp for frontend to check when call was initiated
    });
    io.to(from).volatile.emit('call:ringing', { 
      callId, 
      to, 
      kind,
      timestamp: callTimestamp  // Include timestamp in ringing event too
    });
    console.log(`✅ Socket events sent (volatile): call:incoming to ${to}, call:ringing to ${from}, timestamp=${callTimestamp}`);

    // Send FCM notification for incoming call
    try {
      console.log(`📱 Attempting to send FCM call notification to ${to}...`);
      const caller = await User.findById(from).select('name email').lean();
      const callerName = caller?.name || caller?.email || 'Unknown Caller';
      console.log(`📱 Caller info retrieved: name="${callerName}"`);
      
      await sendCallNotification(to, {
        callId: callId,
        from: from,
        to: to,
        kind: kind,
        isVideoCall: kind === 'video',
        sdp: sdp,
        timestamp: callTimestamp, // Pass timestamp to FCM notification
      }, callerName);
      console.log(`✅ FCM call notification sent to ${to} for incoming call ${callId}`);
    } catch (fcmError) {
      console.error(`❌ Failed to send FCM call notification: ${fcmError.message}`);
      console.error(`❌ FCM error stack:`, fcmError.stack);
      // Don't fail the call if FCM fails - socket event was already sent
    }

    session.timer = setTimeout(() => {
      const s = activeCalls.get(callId);
      if (s && s.state === 'ringing') {
        // Use volatile for call timeout - drop if client is not connected
        io.to(s.a).volatile.emit('call:ended', { callId, by: 'timeout' });
        io.to(s.b).volatile.emit('call:ended', { callId, by: 'timeout' });
        cleanupCall(callId);
      }
    }, 40000);
  } catch (_) {}
});

socket.on('call:answer', (data = {}) => {
  try {
    const who = String(uid);
    const callId = (data.callId || '').toString();
    const accept = !!data.accept;
    const sdp = data.sdp;
    const s = activeCalls.get(callId);
    if (!callId || !s) return;
    const { a: caller, b: callee, kind } = s;

    if (!accept) {
      // Use volatile for call decline - drop if client is not connected
      io.to(caller).volatile.emit('call:declined', { callId, from: who });
      io.to(callee).volatile.emit('call:declined', { callId, from: who });
      cleanupCall(callId);
      return;
    }
    if (!sdp?.type || !sdp?.sdp) return;

    s.state = 'answered';
    if (s.timer) clearTimeout(s.timer);

    // Use volatile for call answer - drop if client is not connected (real-time only)
    io.to(caller).volatile.emit('call:answer', { callId, from: callee, sdp, kind }); // 👈 echo kind (optional but handy)
  } catch (_) {}
});

  // Either side → ICE candidate relay
  socket.on('call:candidate', (data = {}) => {
    try {
      const who = String(uid);
      const callId = (data.callId || '').toString();
      const candidate = data.candidate;
      if (!callId || !candidate) return;
      const s = activeCalls.get(callId);
      if (!s) return;
      const peer = who === s.a ? s.b : s.a;
      // Use volatile for ICE candidates - real-time only, drop if client is not connected
      io.to(peer).volatile.emit('call:candidate', { callId, from: who, candidate });
    } catch (_) {}
  });

  // Either side → hangup
  // CRITICAL: Proper call termination signaling
  socket.on('call:hangup', async (data = {}) => {
    try {
      const who = String(uid);
      const callId = (data.callId || '').toString();
      if (!callId) return;
      const s = activeCalls.get(callId);
      if (!s) return;
      const peer = who === s.a ? s.b : s.a;
      
      const endTimestamp = Date.now(); // Timestamp when call ended
      const isCaller = who === s.a;
      
      console.log(`📞 Call hangup: callId=${callId}, who=${who}, isCaller=${isCaller}, state=${s.state}`);
      
      // CRITICAL: Emit callEnded signal to peer (receiver)
      // Use volatile to prevent queuing - if peer is offline, message is dropped
      io.to(peer).volatile.emit('callEnded', { 
        callId, 
        by: who,
        timestamp: endTimestamp, // Timestamp when call ended
        state: s.state, // Call state when ended
      });
      
      // CRITICAL: Emit CANCEL signal when caller hangs up
      if (isCaller) {
        // Emit CANCEL signal via socket (volatile - won't queue if peer is offline)
        io.to(peer).volatile.emit('CANCEL', { 
          callId, 
          by: who,
          timestamp: endTimestamp,
          state: s.state,
          reason: 'caller_hung_up',
        });
        
        // Also emit callCancelled for backward compatibility
        io.to(peer).volatile.emit('callCancelled', { 
          callId, 
          by: who,
          timestamp: endTimestamp,
        });
      }
      
      // Always emit call:ended for both parties (legacy support)
      io.to(peer).volatile.emit('call:ended', { 
        callId, 
        by: who,
        timestamp: endTimestamp,
      });
      io.to(who).volatile.emit('call:ended', { 
        callId, 
        by: who,
        timestamp: endTimestamp,
      });
      
      // CRITICAL: Send FCM notification if peer is offline/background
      // Check if peer is connected via socket
      const peerRoom = io.sockets.adapter.rooms.get(peer);
      const isPeerConnected = peerRoom && peerRoom.size > 0;
      
      // Always send FCM CANCEL notification when caller ends the call
      // This ensures User B receives the cancellation even if they're in background or socket disconnects
      if (isCaller) {
        try {
          const caller = await User.findById(who).select('name email').lean();
          const callerName = caller?.name || caller?.email || 'Unknown Caller';
          await sendCallEndedNotification(peer, callId, callerName, endTimestamp);
          console.log(`✅ FCM CANCEL notification sent to ${peer} for call ${callId} (caller ended call)`);
        } catch (fcmError) {
          console.error(`❌ Failed to send FCM CANCEL notification: ${fcmError.message}`);
          // Don't fail the call hangup if FCM fails
        }
      } else if (!isPeerConnected) {
        // Receiver ended the call but peer is offline - still send notification
        try {
          const receiver = await User.findById(who).select('name email').lean();
          const receiverName = receiver?.name || receiver?.email || 'Unknown';
          await sendCallEndedNotification(peer, callId, receiverName, endTimestamp);
          console.log(`✅ FCM call ended notification sent to ${peer} for call ${callId} (receiver ended, peer offline)`);
        } catch (fcmError) {
          console.error(`❌ Failed to send FCM notification: ${fcmError.message}`);
        }
      }
      
      // Clean up call state
      cleanupCall(callId);
      console.log(`✅ Call ${callId} cleaned up and terminated`);
    } catch (error) {
      console.error(`❌ Error in call:hangup handler: ${error.message}`);
    }
  });

  // ========= Legacy signaling (လက်ရှိရှိပြီးသားကို ထိန်းသိမ်း) =========
  socket.on('call_offer', ({ to, sdp }) => {
    const from = uid;
    if (userToCall.has(from) || userToCall.has(to)) {
      return socket.emit('call_error', { error: 'busy' });
    }
    const callId = newCallId();
    activeCalls.set(callId, { a: from, b: to, startedAt: new Date() });
    userToCall.set(from, callId);
    userToCall.set(to, callId);
    io.to(to).emit('call_offer', { from, callId, sdp });
  });

  socket.on('call_answer', ({ callId, sdp }) => {
    const call = activeCalls.get(callId);
    if (!call) return;
    const partner = call.a === uid ? call.b : call.a;
    io.to(partner).emit('call_answer', { from: uid, callId, sdp });
  });

  socket.on('ice_candidate', ({ callId, candidate }) => {
    const call = activeCalls.get(callId);
    if (!call) return;
    const partner = call.a === uid ? call.b : call.a;
    io.to(partner).emit('ice_candidate', { from: uid, candidate });
  });

socket.on('call_end', ({ callId }) => {
  const call = activeCalls.get(callId);
  if (!call) return;
  activeCalls.delete(callId);
  userToCall.delete(call.a);
  userToCall.delete(call.b);
  const partner = call.a === uid ? call.b : call.a;
  io.to(partner).emit('call_end', { from: uid, callId });
});
  // ========= Disconnect =========
  socket.on('disconnect', () => {
    // presence
    const left = (onlineCounts.get(uid) || 1) - 1;
    if (left <= 0) {
      onlineCounts.delete(uid);
      setOnline(uid, false);
    } else {
      onlineCounts.set(uid, left);
    }
    console.log('❌ disconnected:', uid);

    // if in-call, end it for both
    const callId = userToCall.get(uid);
    if (callId) {
      const s = activeCalls.get(callId);
      if (s) {
        const peer = uid === s.a ? s.b : s.a;
        // Use volatile for disconnect - drop if client is not connected
        io.to(peer).volatile.emit('call:ended', { callId, by: 'disconnect' });
      }
      cleanupCall(callId);
    }
  });
});


/* ================= Conversations / Requests ================= */

app.post('/chat-requests', requireAuth, async (req, res) => {
  try {
    const { from, toPhone } = req.body || {};
    if (!from || !toPhone) return res.status(400).json({ error: 'missing_fields' });
    if (String(from) !== req.user.uid) return res.status(403).json({ error: 'forbidden' });

    const to = await uidByPhone(toPhone);
    if (!to) return res.status(404).json({ error: 'no_user_for_phone', phone: toPhone });

    const participants = pair(from, to);
    let convo = await Conversation.findOne({
      participants: { $all: participants, $size: 2 },
      status: { $in: ['pending', 'active'] }
    });

    if (!convo) {
      convo = await Conversation.create({
        participants, status: 'pending', createdBy: from, lastMessageAt: null
      });
    }

    io.to(String(to)).emit('chat_request', {
      _id: String(convo._id),
      from: String(from),
      to: String(to),
      status: convo.status,
      createdAt: convo.createdAt,
    });

    res.json({ ok: true, conversation: convo });
  } catch (e) { console.error(e); res.status(500).json({ error: 'server_error' }); }
});

app.get('/chat-requests', requireAuth, async (req, res) => {
  try {
    const { me, status = 'pending' } = req.query;
    if (!me) return res.status(400).json({ error: 'missing_me' });
    if (String(me) !== req.user.uid) return res.status(403).json({ error: 'forbidden' });

    const items = await Conversation.find({ participants: me, status })
      .sort({ createdAt: -1 })
      .lean();
    res.json(items);
  } catch (e) { res.status(500).json({ error: 'server_error' }); }
});

// ✅ GET /conversations with lastPreview/lastFrom fix
app.get('/conversations', requireAuth, async (req, res) => {
  try {
    const { me, status = 'active' } = req.query;
    if (!me) return res.status(400).json({ error: 'missing_me' });
    if (String(me) !== req.user.uid) return res.status(403).json({ error: 'forbidden' });

    const items = await Conversation.find({ participants: me, status })
      .sort({ lastMessageAt: -1, updatedAt: -1 })
      .lean();

    const ids = items.map(c => c._id);

    const outLast = await Message.aggregate([
      { $match: { conversation: { $in: ids }, from: new mongoose.Types.ObjectId(me), deleted: { $ne: true } } },
      { $group: { _id: '$conversation', lastOutgoingAt: { $max: '$createdAt' } } },
    ]);
    const outMap = {}; for (const r of outLast) outMap[String(r._id)] = r.lastOutgoingAt;

    const previews = await Message.aggregate([
      { $match: { conversation: { $in: ids }, deleted: { $ne: true } } },
      { $sort: { createdAt: -1 } },
      { $group: {
          _id: '$conversation',
          text: { $first: '$text' },
          from: { $first: '$from' },
          at:   { $first: '$createdAt' },
      }},
    ]);
    const prevTextMap = {};
    const prevFromMap = {};
    for (const p of previews) {
      const k = String(p._id);
      prevTextMap[k] = p.text || '';
      prevFromMap[k] = p.from ? String(p.from) : '';
    }

    res.json(items.map(c => ({
      ...c,
      lastPreview:    prevTextMap[String(c._id)] || '',
      lastFrom:       prevFromMap[String(c._id)] || '',
      lastOutgoingAt: outMap[String(c._id)] || null,
      deliveredUpTo:  c.deliveredUpTo || {},
      readUpTo:       c.readUpTo || {},
    })));
  } catch (e) {
    console.error('GET /conversations error', e);
    res.status(500).json({ error: 'server_error' });
  }
});

app.post('/chat-requests/:id/accept', requireAuth, async (req, res) => {
  try {
    const { id } = req.params;
    const me = req.body?.me;
    if (!me) return res.status(400).json({ error: 'missing_me' });
    if (String(me) !== req.user.uid) return res.status(403).json({ error: 'forbidden' });

    const convo = await Conversation.findById(id);
    if (!convo) return res.status(404).json({ error: 'not_found' });
    if (!convo.participants.map(String).includes(String(me)))
      return res.status(403).json({ error: 'forbidden' });

    convo.status = 'active';
    if (!convo.lastMessageAt) convo.lastMessageAt = new Date();
    await convo.save();

    for (const p of convo.participants) {
      const partner = convo.participants.find(x => String(x) !== String(p));
      io.to(String(p)).emit('chat_request_accepted', {
        conversationId: String(convo._id),
        partnerId: String(partner),
      });
    }
    res.json({ ok: true, conversation: convo });
  } catch (e) { console.error(e); res.status(500).json({ error: 'server_error' }); }
});

app.post('/chat-requests/:id/decline', requireAuth, async (req, res) => {
  try {
    const { id } = req.params;
    const me = req.body?.me;
    if (!me) return res.status(400).json({ error: 'missing_me' });
    if (String(me) !== req.user.uid) return res.status(403).json({ error: 'forbidden' });

    const convo = await Conversation.findById(id);
    if (!convo) return res.status(404).json({ error: 'not_found' });
    if (!convo.participants.map(String).includes(String(me)))
      return res.status(403).json({ error: 'forbidden' });

    convo.status = 'declined';
    await convo.save();

    io.to(String(convo.createdBy)).emit('chat_request_declined', {
      conversationId: String(convo._id),
      by: String(me),
    });
    res.json({ ok: true, conversation: convo });
  } catch (e) { res.status(500).json({ error: 'server_error' }); }
});

/* ===================== Messages ===================== */

// --- ADD THIS under your other /messages routes in backend/src/index.js ---
app.patch('/messages/:id', requireAuth, async (req, res) => {
  try {
    const { id } = req.params;
    const { text } = req.body || {};
    const me = req.user.uid;

    const newText = (text ?? '').toString().trim();
    if (!newText) return res.status(400).json({ error: 'empty_text' });
    if (newText.length > 4000) return res.status(413).json({ error: 'too_long' });

    const msg = await Message.findById(id);
    if (!msg) return res.status(404).json({ error: 'not_found' });

    // only sender can edit & not deleted
    if (String(msg.from) !== String(me)) {
      return res.status(403).json({ error: 'only_sender_can_edit' });
    }
    if (msg.deleted) {
      return res.status(400).json({ error: 'cannot_edit_deleted' });
    }

    // update content (do NOT change createdAt; do NOT reorder list)
    msg.text = newText;
    msg.edited = true;
    msg.editedAt = new Date();
    await msg.save();

    const payload = {
      _id: String(msg._id),
      conversationId: msg.conversation ? String(msg.conversation) : undefined,
      from: String(msg.from),
      to: String(msg.to),
      text: msg.text,
      edited: true,
      editedAt: msg.editedAt.toISOString(),
      createdAt: msg.createdAt.toISOString(),
    };

    // socket → both participants
    io.to(String(msg.to)).emit('message_edited', payload);
    io.to(String(msg.from)).emit('message_edited', payload);

    return res.json({ ok: true, message: payload });
  } catch (e) {
    console.error('edit message error:', e);
    return res.status(500).json({ error: 'server_error' });
  }
});



// File upload endpoint
app.post('/upload', requireAuth, upload.single('file'), (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({ error: 'no_file' });
    }
    // Use the request host to construct the URL
    const protocol = req.protocol || 'http';
    const host = req.get('host') || 'localhost:3000';
    const fileUrl = `${protocol}://${host}/uploads/${req.file.filename}`;
    return res.json({ 
      url: fileUrl,
      fileName: req.file.originalname,
      fileSize: req.file.size,
    });
  } catch (err) {
    console.error('Upload error:', err);
    return res.status(500).json({ error: 'upload_failed' });
  }
});

// ✅ single-response /messages (fixes ERR_HTTP_HEADERS_SENT)
app.post('/messages', requireAuth, async (req, res, next) => {
  try {
    const { from, toPhone, text, fileUrl, fileName, fileType, audioDuration: audioDurationStr, 
            messageType, callActivity, callType, callStatus, isVideoCall, callStartTime, callDuration,
            replyTo, replyToMessage } = req.body || {};
    const audioDuration = audioDurationStr ? parseInt(audioDurationStr, 10) : null;
    if (!from || !toPhone) return res.status(400).json({ error: 'missing_fields' });
    if (String(from) !== req.user.uid) return res.status(403).json({ error: 'forbidden' });

    const normText = (text ?? '').toString().trim();
    // Check if this is a voice message
    const isVoice = fileType === 'audio' || fileType === 'voice' || 
                    (fileName && (fileName.endsWith('.m4a') || fileName.endsWith('.mp3') || fileName.startsWith('voice_')));
    // Allow empty text for call activity messages and voice messages
    if (!normText && !fileUrl && !callActivity) return res.status(400).json({ error: 'empty_text' });
    if (normText.length > 4000) return res.status(413).json({ error: 'too_long' });

    const to = await uidByPhone(toPhone);
    if (!to) return res.status(404).json({ error: 'no_user_for_phone', phone: toPhone });

    const [A, B] = pair(from, to);
    const convo = await Conversation.findOne({
      participants: { $all: [A, B], $size: 2 },
      status: 'active',
    });
    if (!convo) return res.status(403).json({ error: 'not_accepted' });

    // For voice messages, use a minimal placeholder (frontend will hide it)
    // For other files, add default text if no text provided
    // For call activity, add call text
    let messageText = normText;
    if (!messageText && fileUrl && !isVoice) {
      messageText = `📎 ${fileName || 'File'}`;
    } else if (!messageText && callActivity) {
      messageText = '📞 Call';
    } else if (!messageText && isVoice) {
      // Use a minimal placeholder for voice messages (frontend will detect and hide it)
      messageText = 'Voice Message';
    }
    
    const msgData = {
      from, 
      to, 
      text: messageText || ' ', // Ensure text is never empty (schema requires it)
      conversation: convo._id, 
      deleted: false,
    };
    
    if (fileUrl) {
      msgData.fileUrl = fileUrl;
      msgData.fileName = fileName;
      msgData.fileType = fileType;
      if (audioDuration != null) {
        msgData.audioDuration = audioDuration;
      }
    }
    
    // Add call activity metadata if present
    if (callActivity || messageType === 'call_activity') {
      msgData.messageType = 'call_activity';
      msgData.callActivity = true;
      if (callType) msgData.callType = callType;
      if (callStatus) msgData.callStatus = callStatus;
      if (isVideoCall !== undefined) msgData.isVideoCall = isVideoCall;
      if (callStartTime) {
        const startTime = new Date(callStartTime);
        if (!isNaN(startTime.getTime())) msgData.callStartTime = startTime;
      }
      if (callDuration) {
        const duration = parseInt(callDuration, 10);
        if (!isNaN(duration)) msgData.callDuration = duration;
      }
    }
    
    // Add reply data if present
    if (replyTo) {
      // Convert replyTo string to ObjectId if it's a valid ObjectId string
      try {
        msgData.replyTo = new mongoose.Types.ObjectId(replyTo);
        console.log(`💾 [POST /messages] Saving replyTo: ${replyTo} (converted to ObjectId)`);
      } catch (e) {
        console.error(`❌ [POST /messages] Invalid replyTo ObjectId: ${replyTo}`, e);
        // If conversion fails, try to save as string (Mongoose might auto-convert)
        msgData.replyTo = replyTo;
      }
    }
    if (replyToMessage) {
      msgData.replyToMessage = replyToMessage;
      console.log(`💾 [POST /messages] Saving replyToMessage: ${JSON.stringify(replyToMessage)}`);
    }

    const msg = await Message.create(msgData);
    
    // Verify reply data was saved
    if (msg.replyTo || msg.replyToMessage) {
      console.log(`✅ [POST /messages] Reply data saved successfully: replyTo=${msg.replyTo}, replyToMessage=${JSON.stringify(msg.replyToMessage)}`);
    } else if (replyTo || replyToMessage) {
      console.error(`❌ [POST /messages] WARNING: Reply data was provided but not saved! replyTo=${replyTo}, replyToMessage=${JSON.stringify(replyToMessage)}`);
    }

    await Conversation.updateOne(
      { _id: convo._id },
      { $max: { lastMessageAt: msg.createdAt }, $set: { updatedAt: new Date() } },
    );

    const payload = {
      _id: String(msg._id),
      conversationId: String(convo._id),
      from: String(from),
      to: String(to),
      text: msgData.text,
      deleted: false,
      createdAt: msg.createdAt.toISOString(),
      lastMessageAt: msg.createdAt.toISOString(),
    };
    
    if (fileUrl) {
      payload.fileUrl = fileUrl;
      payload.fileName = fileName;
      payload.fileType = fileType;
      if (audioDuration != null) {
        payload.audioDuration = audioDuration;
      }
    }
    
    // Include call activity metadata in response
    if (msg.messageType === 'call_activity' || msg.callActivity) {
      payload.messageType = 'call_activity';
      payload.callActivity = true;
      if (msg.callType) payload.callType = msg.callType;
      if (msg.callStatus) payload.callStatus = msg.callStatus;
      if (msg.isVideoCall !== undefined) payload.isVideoCall = msg.isVideoCall;
      if (msg.callStartTime) payload.callStartTime = msg.callStartTime.toISOString();
      if (msg.callDuration !== undefined) payload.callDuration = msg.callDuration.toString();
    }
    
    // Include reply data in response and socket broadcast
    if (msg.replyTo) {
      payload.replyTo = String(msg.replyTo);
    }
    if (msg.replyToMessage) {
      payload.replyToMessage = msg.replyToMessage;
    }

    // sockets (no res touch)
    io.to(String(to)).emit('message', payload);
    io.to(String(from)).emit('message', payload);

    // Send FCM notification if recipient is not connected via socket
    // Check if recipient has any active socket connections
    const recipientRoom = io.sockets.adapter.rooms.get(String(to));
    const isRecipientConnected = recipientRoom && recipientRoom.size > 0;
    
    // Skip FCM notification for call activity messages
    // Call notifications are handled separately via sendCallNotification
    const isCallActivity = payload.callActivity || payload.messageType === 'call_activity';
    
    if (!isRecipientConnected && !isCallActivity) {
      // Recipient is not connected via socket - send FCM notification
      // But skip if this is a call activity (call notification already sent)
      try {
        const sender = await User.findById(from).select('name').lean();
        const senderName = sender?.name || 'Someone';
        await sendMessageNotification(to, payload, senderName);
        console.log(`📱 FCM notification sent to user ${to} (not connected via socket)`);
      } catch (fcmError) {
        console.error('❌ Error sending FCM notification:', fcmError.message);
        // Don't fail the request if FCM fails
      }
    } else if (isCallActivity) {
      console.log(`ℹ️ Skipping FCM message notification for call activity (call notification already sent)`);
    }

    // single final response
    return res.json({ ok: true, message: payload });
  } catch (err) {
    console.error('Message error (POST /messages):', err);
    return next(err);
  }
});

// Check if a call is still active
app.get('/calls/:callId/status', requireAuth, async (req, res) => {
  try {
    const callId = req.params.callId;
    const session = activeCalls.get(callId);
    
    if (!session) {
      return res.json({ 
        active: false, 
        callId: callId,
        message: 'Call not found or already ended'
      });
    }
    
    return res.json({ 
      active: true,
      callId: callId,
      state: session.state || 'unknown',
      startedAt: session.startedAt?.toISOString() || null,
      kind: session.kind || 'audio',
    });
  } catch (error) {
    console.error('Error checking call status:', error);
    return res.status(500).json({ error: 'server_error' });
  }
});

app.patch('/users/me', requireAuth, async (req, res) => {
  try {
    const { name, avatarUrl, bio, fcmToken } = req.body || {};
    const u = await User.findById(req.user.uid);
    if (!u) return res.status(404).json({ error: 'not_found' });

    if (typeof name === 'string' && name.trim().length > 0) {
      u.name = name.trim();
    }

    // Handle avatarUrl: can be a string (new URL) or null (remove avatar)
    if (avatarUrl === null) {
      u.avatarUrl = null;
    } else if (typeof avatarUrl === 'string') {
      u.avatarUrl = avatarUrl.trim() || null;
    }

    if (typeof bio === 'string') {
      u.bio = bio.trim() || null;
    }

    // Handle FCM token: can be a string (new token) or null (remove token)
    if (fcmToken === null) {
      u.fcmToken = null;
    } else if (typeof fcmToken === 'string' && fcmToken.trim().length > 0) {
      u.fcmToken = fcmToken.trim();
      console.log('✅ FCM token updated for user:', String(u._id));
    }

    await u.save();
    
    // Emit profile update event to all connected clients
    console.log('📸 Emitting user_profile_updated for user:', String(u._id));
    io.emit('user_profile_updated', {
      userId: String(u._id),
      user: {
        id: String(u._id),
        name: u.name,
        phone: u.phone || null,
        avatarUrl: u.avatarUrl || null,
        bio: u.bio || null,
      }
    });
    console.log('✅ Profile update event emitted');
    
    return res.json({ 
      user: { 
        id: String(u._id), 
        name: u.name, 
        phone: u.phone || null,
        avatarUrl: u.avatarUrl || null,
        bio: u.bio || null,
      } 
    });
  } catch (e) {
    console.error('update profile error:', e);
    return res.status(500).json({ error: 'server_error' });
  }
});

app.delete('/messages/:id', requireAuth, async (req, res) => {
  try {
    const { id } = req.params;
    const me = req.user.uid;

    const msg = await Message.findById(id);
    if (!msg) return res.status(404).json({ error: 'not_found' });

    if (String(msg.from) !== String(me)) {
      return res.status(403).json({ error: 'only_sender_can_delete' });
    }
    if (msg.deleted) {
      return res.json({ ok: true, message: { _id: String(msg._id), deleted: true } });
    }

    msg.deleted = true;
    msg.deletedAt = new Date();
    await msg.save();

    const payload = {
      _id: String(msg._id),
      conversationId: msg.conversation ? String(msg.conversation) : (
        (await Conversation.findOne({
          participants: { $all: pair(msg.from, msg.to), $size: 2 },
          status: { $in: ['pending','active','declined','blocked'] },
        }))?._id?.toString()
      ),
      from: String(msg.from),
      to: String(msg.to),
      deleted: true,
      deletedAt: msg.deletedAt.toISOString(),
    };

    io.to(String(msg.to)).emit('message_deleted', payload);
    io.to(String(msg.from)).emit('message_deleted', payload);

    if (msg.conversation) {
      await recomputeLastMessageAt(msg.conversation);
    } else {
      await recomputeLastMessageAt(
        (await Conversation.findOne({
          participants: { $all: pair(msg.from, msg.to), $size: 2 },
        }))?._id,
      );
    }

    res.json({ ok: true, message: payload });
  } catch (e) {
    console.error('Delete message error:', e);
    res.status(500).json({ error: 'server_error' });
  }
});

app.get('/messages', requireAuth, async (req, res) => {
  try {
    const me = req.user.uid;
    const { conversation, userA, userB } = req.query || {};
    let query = {};

    if (conversation) {
      const convo = await Conversation.findById(conversation).lean();
      if (!convo) return res.status(404).json({ error: 'not_found' });
      if (!convo.participants.map(String).includes(String(me))) {
        return res.status(403).json({ error: 'forbidden' });
      }
      query = { conversation };
    } else if (userA && userB) {
      if (![String(userA), String(userB)].includes(String(me))) {
        return res.status(403).json({ error: 'forbidden' });
      }
      query = { $or: [{ from: userA, to: userB }, { from: userB, to: userA }] };
    } else {
      return res.status(400).json({ error: 'missing_query' });
    }

    const items = await Message.find(query).sort({ createdAt: 1 }).lean();
    
    // Debug: Count messages with reply data and log all message IDs
    let replyCount = 0;
    console.log(`📚 [GET /messages] Loading ${items.length} messages for conversation/user query`);
    items.forEach(m => {
      const msgId = String(m._id);
      // Check if reply data exists in the raw database document
      const hasReplyTo = m.replyTo != null;
      const hasReplyToMessage = m.replyToMessage != null;
      
      if (hasReplyTo || hasReplyToMessage) {
        replyCount++;
        console.log(`📚 [GET /messages] ✅ Found message with reply data: ${msgId}`);
        console.log(`   replyTo: ${m.replyTo} (type: ${typeof m.replyTo})`);
        console.log(`   replyToMessage: ${JSON.stringify(m.replyToMessage)} (type: ${typeof m.replyToMessage})`);
      } else {
        // Log a few messages without reply data for debugging
        if (replyCount === 0 && items.indexOf(m) < 3) {
          console.log(`📚 [GET /messages] ❌ Message ${msgId} has no reply data (replyTo=${m.replyTo}, replyToMessage=${m.replyToMessage})`);
        }
      }
    });
    if (replyCount > 0) {
      console.log(`📚 [GET /messages] ✅ Total messages with reply data: ${replyCount} out of ${items.length}`);
    } else {
      console.log(`📚 [GET /messages] ⚠️ WARNING: No messages found with reply data out of ${items.length} total messages`);
    }
    
    res.json(items.map(m => {
      const msg = {
        _id: String(m._id),
        from: String(m.from),
        to: String(m.to),
        text: m.deleted ? '' : (m.text || ''),
        conversation: m.conversation ? String(m.conversation) : undefined,
        deleted: !!m.deleted,
        deletedAt: m.deletedAt || undefined,
        createdAt: m.createdAt?.toISOString?.() || undefined,
        // Include file metadata for proper display
        fileUrl: m.fileUrl || undefined,
        fileName: m.fileName || undefined,
        fileType: m.fileType || undefined,
        audioDuration: m.audioDuration || undefined,
        edited: m.edited || false,
        editedAt: m.editedAt?.toISOString?.() || undefined,
      };
      
      // Include call activity metadata if present
      if (m.messageType === 'call_activity' || m.callActivity) {
        msg.messageType = 'call_activity';
        msg.callActivity = true;
        if (m.callType) msg.callType = m.callType;
        if (m.callStatus) msg.callStatus = m.callStatus;
        if (m.isVideoCall !== undefined) msg.isVideoCall = m.isVideoCall;
        if (m.callStartTime) msg.callStartTime = m.callStartTime.toISOString();
        if (m.callDuration !== undefined) msg.callDuration = m.callDuration.toString();
      }
      
      // Include reply data if present (always include, even if null, to ensure frontend can check)
      if (m.replyTo != null) {
        msg.replyTo = String(m.replyTo);
        console.log(`📚 [GET /messages] Adding replyTo to message ${msg._id}: ${msg.replyTo}`);
      }
      if (m.replyToMessage != null) {
        // replyToMessage is stored as Mixed type, so it can be an object
        // Ensure it's properly serialized as a plain object
        if (typeof m.replyToMessage === 'object' && m.replyToMessage !== null) {
          // Convert to plain object to ensure proper JSON serialization
          try {
            msg.replyToMessage = JSON.parse(JSON.stringify(m.replyToMessage));
          } catch (e) {
            console.error(`❌ [GET /messages] Error serializing replyToMessage for ${msg._id}:`, e);
            // Fallback: try to convert to plain object manually
            msg.replyToMessage = m.replyToMessage;
          }
        } else {
          msg.replyToMessage = m.replyToMessage;
        }
        console.log(`📚 [GET /messages] Adding replyToMessage to message ${msg._id}: ${JSON.stringify(msg.replyToMessage)}`);
      } else {
        // Log when replyToMessage is missing but we expected it
        if (m.replyTo) {
          console.log(`⚠️ [GET /messages] Message ${msg._id} has replyTo (${m.replyTo}) but no replyToMessage`);
        }
      }
      
      return msg;
    }));
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'server_error' });
  }
});

app.get('/presence', requireAuth, async (req, res) => {
  const ids = (req.query.ids || '').toString().split(',').filter(Boolean).map(String);
  const verbose = req.query.verbose === '1' || req.query.verbose === 'true';

  // ids မပေးရင် – default behavior ထိန်းထား
  if (ids.length === 0) {
    if (!verbose) {
      const all = Array.from(onlineCounts.keys()).map(String);
      return res.json({ online: all });
    } else {
      const all = Array.from(new Set([
        ...Array.from(onlineCounts.keys()).map(String),
        ...Array.from(lastPresenceAt.keys()).map(String),
      ]));
      const map = {};
      for (const id of all) {
        map[id] = {
          online: (onlineCounts.get(id) || 0) > 0,
          at: (lastPresenceAt.get(id) || new Date()).toISOString(),
        };
      }
      return res.json(map);
    }
  }
  if (!verbose) {
    const map = {};
    for (const id of ids) map[id] = (onlineCounts.get(id) || 0) > 0;
    return res.json(map);
  } else {
    const map = {};
    for (const id of ids) {
      map[id] = {
        online: (onlineCounts.get(id) || 0) > 0,
        at: (lastPresenceAt.get(id) || null)?.toISOString?.() || null,
      };
    }
    return res.json(map);
  }
});


app.get('/users/by-ids', requireAuth, async (req, res) => {
  try {
    const ids = (req.query.ids || '').toString().split(',').filter(Boolean);
    const users = await User.find({ _id: { $in: ids } }).select('_id phone name avatarUrl email lastSeen').lean();
    const map = {}; for (const u of users) map[String(u._id)] = { 
      phone: u.phone || null, 
      name: u.name,
      email: u.email || null,
      avatarUrl: u.avatarUrl || null,
      lastSeen: u.lastSeen ? u.lastSeen.toISOString() : null,
    };
    res.json(map);
  } catch (e) { res.status(500).json({ error: 'server_error' }); }
});

app.get('/ping', (_req, res) => res.json({ pong: true }));

// Development endpoint to list all users (for testing only)
app.get('/test/list-all-users', async (req, res) => {
  try {
    const users = await User.find({}).select('_id name phone').lean();
    const allUsers = users.map(u => ({
      id: String(u._id),
      name: u.name,
      phone: u.phone,
      normalized: normalizePhoneNumber(u.phone || ''),
      phoneLength: u.phone?.length,
      phoneBytes: Buffer.from(u.phone || '').toString('hex'),
    }));
    res.json({ 
      count: allUsers.length,
      users: allUsers 
    });
  } catch (e) {
    console.error('List users error:', e);
    res.status(500).json({ error: 'server_error', message: e.message });
  }
});

// Development endpoint to check if a specific phone exists
app.get('/test/check-phone', async (req, res) => {
  try {
    const { phone } = req.query || {};
    if (!phone) return res.status(400).json({ error: 'missing_phone' });
    
    const normalized = normalizePhoneNumber(phone);
    const user = await User.findOne({ phone: normalized });
    const allUsers = await User.find({}).select('phone name').lean();
    
    res.json({
      searchedPhone: phone,
      normalizedPhone: normalized,
      exists: !!user,
      foundUser: user ? {
        id: String(user._id),
        name: user.name,
        phone: user.phone
      } : null,
      allUsers: allUsers.map(u => ({ phone: u.phone, name: u.name }))
    });
  } catch (e) {
    console.error('Check phone error:', e);
    res.status(500).json({ error: 'server_error', message: e.message });
  }
});

// Sync contacts - find which phone numbers are registered users
app.post('/contacts/sync', requireAuth, async (req, res) => {
  try {
    const { contacts } = req.body || {}; // Array of { phone: string, name?: string } or plain strings
    if (!Array.isArray(contacts)) {
      return res.status(400).json({ error: 'invalid_format', message: 'contacts must be an array' });
    }

    const myId = req.user.uid;
    const normalizedPhones = contacts
      .map((c) => {
        const phone = (c && typeof c === 'object' ? c.phone : c)?.toString().trim();
        return phone ? normalizePhoneNumber(phone) : null;
      })
      .filter(Boolean)
      .filter((phone, index, self) => self.indexOf(phone) === index); // Remove duplicates

    if (normalizedPhones.length === 0) {
      return res.json({ matches: [] });
    }

    // Find users with matching phone numbers
    const users = await User.find({
      phone: { $in: normalizedPhones },
      _id: { $ne: myId }, // Exclude self
    })
      .select('_id name phone avatarUrl')
      .lean();

    // Build response with contact info
    const matches = users.map((u) => ({
      id: String(u._id),
      name: u.name,
      phone: u.phone,
      avatarUrl: u.avatarUrl || null,
    }));

    console.log(
      `📱 Contact sync: ${normalizedPhones.length} contacts checked, ${matches.length} matches found`,
    );

    res.json({ matches });
  } catch (e) {
    console.error('Contact sync error:', e);
    res.status(500).json({ error: 'server_error', message: e.message });
  }
});

// Ensure an active conversation between two users by phone (no request flow)
app.post('/contacts/start-chat', requireAuth, async (req, res) => {
  try {
    const { from, toPhone } = req.body || {};
    if (!from || !toPhone) {
      return res.status(400).json({ error: 'missing_fields' });
    }
    if (String(from) !== req.user.uid) {
      return res.status(403).json({ error: 'forbidden' });
    }

    const to = await uidByPhone(toPhone);
    if (!to) {
      return res.status(404).json({ error: 'no_user_for_phone', phone: toPhone });
    }

    const participants = pair(from, to);

    // Find existing conversation, any status
    let convo = await Conversation.findOne({
      participants: { $all: participants, $size: 2 },
    });

    if (!convo) {
      // Create a new active conversation
      convo = await Conversation.create({
        participants,
        status: 'active',
        createdBy: from,
        lastMessageAt: null,
      });
    } else if (convo.status !== 'active') {
      // Upgrade any existing convo (pending/declined) to active, like Telegram contact auto-chat
      convo.status = 'active';
      await convo.save();
    }

    return res.json({
      ok: true,
      conversation: {
        _id: String(convo._id),
        participants: convo.participants.map((p) => String(p)),
        status: convo.status,
        createdBy: String(convo.createdBy),
        lastMessageAt: convo.lastMessageAt,
        createdAt: convo.createdAt,
        updatedAt: convo.updatedAt,
      },
    });
  } catch (e) {
    console.error('start-chat error:', e);
    res.status(500).json({ error: 'server_error', message: e.message });
  }
});

// Development endpoint to delete user by phone (for testing only)
// Usage: DELETE /test/delete-user-by-phone?phone=+1111111111
app.delete('/test/delete-user-by-phone', async (req, res) => {
  try {
    const { phone } = req.query || {};
    if (!phone) return res.status(400).json({ error: 'missing_phone' });
    
    const normalizedPhone = normalizePhoneNumber(phone);
    const user = await User.findOne({ phone: normalizedPhone });
    
    if (!user) {
      // Return all users for debugging
      const allUsers = await User.find({}).select('name phone').lean();
      return res.status(404).json({ 
        error: 'user_not_found', 
        searchedPhone: phone,
        normalizedPhone: normalizedPhone,
        allUsers: allUsers.map(u => ({ phone: u.phone, name: u.name }))
      });
    }
    
    const userId = user._id;
    
    // Delete user and related data
    await User.deleteOne({ _id: userId });
    await Conversation.deleteMany({ participants: userId });
    await Message.deleteMany({ $or: [{ from: userId }, { to: userId }] });
    
    console.log('✅ Test user deleted:', {
      phone: normalizedPhone,
      userId: String(userId),
      name: user.name
    });
    
    res.json({ 
      ok: true, 
      message: 'User deleted successfully',
      phone: normalizedPhone,
      deletedUserId: String(userId)
    });
  } catch (e) {
    console.error('Delete user error:', e);
    res.status(500).json({ error: 'server_error', message: e.message });
  }
});

// Database test endpoint
app.get('/test-db', async (_req, res) => {
  try {
    const dbState = mongoose.connection.readyState;
    const states = { 0: 'disconnected', 1: 'connected', 2: 'connecting', 3: 'disconnecting' };
    
    // Try to query the database
    const userCount = await User.countDocuments();
    const testUser = await User.findOne().lean();
    
    res.json({
      status: 'ok',
      dbState: states[dbState] || 'unknown',
      dbStateCode: dbState,
      userCount: userCount,
      sampleUser: testUser ? { id: String(testUser._id), name: testUser.name, phone: testUser.phone || null } : null,
      mongodbUri: MONGODB_URI.replace(/\/\/.*@/, '//***:***@'), // Hide credentials
    });
  } catch (error) {
    res.status(500).json({
      status: 'error',
      error: error.message,
      stack: error.stack,
    });
  }
});

// ✅ global error handler (prevents double-send)
app.use((err, req, res, next) => {
  if (res.headersSent) {
    console.error('Unhandled after headersSent:', err);
    return;
  }
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'server_error' });
});

const PORT = process.env.PORT || 3000;
// Listen on 0.0.0.0 to accept connections from any network interface (for real devices)
server.listen(PORT, '0.0.0.0', () => {
  console.log(`🚀 API + WS server listening on http://0.0.0.0:${PORT}`);
  console.log(`📱 Accessible from network at: http://<YOUR-IP>:${PORT}`);
  console.log(`💻 Accessible locally at: http://localhost:${PORT}`);
});
