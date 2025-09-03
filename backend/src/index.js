import express from 'express';
import mongoose from 'mongoose';
import cors from 'cors';
import dotenv from 'dotenv';
import http from 'http';
import jwt from 'jsonwebtoken';
import { Server as SocketIOServer } from 'socket.io';
import bcrypt from 'bcrypt'; // (အခု name သာ update ရုံဆိုရင် မလိုပါ—password ထည့်ချင်ရင်လို)

import User from './models/User.js';
import Message from './models/Message.js';
import Conversation from './models/Conversation.js';
import authRoutes from './auth.js';

dotenv.config();

const MONGODB_URI = process.env.MONGODB_URI || 'mongodb://127.0.0.1:27017/messaging';
await mongoose.connect(MONGODB_URI, { useNewUrlParser: true, useUnifiedTopology: true });
console.log('✅ MongoDB connected:', MONGODB_URI);

const app = express();
app.use(cors());
app.use(express.json());
app.use('/auth', authRoutes);

const server = http.createServer(app);
const io = new SocketIOServer(server, { cors: { origin: '*' } });
const JWT_SECRET = process.env.JWT_SECRET || 'devsecret';

// ---------------- Helpers ----------------
const requireAuth = (req,res,next)=>{
  try{
    const token = (req.headers.authorization||'').replace('Bearer ','');
    const {uid} = jwt.verify(token, JWT_SECRET);
    req.user = { uid: String(uid) };
    next();
  }catch{ res.status(401).json({error:'invalid_token'}); }
};
const uidByEmail = async (email)=>{
  const u = await User.findOne({email}).select('_id email').lean();
  return u?._id? String(u._id): null;
};

// participants pair helper (sorted)
const pair = (a,b) => {
  const A = String(a), B = String(b);
  return A < B ? [A,B] : [B,A];
};

// ---------------- Socket auth ----------------
io.use((socket,next)=>{
  try{
    const {uid} = jwt.verify(socket.handshake.auth?.token, JWT_SECRET);
    socket.data.uid = String(uid);
    next();
  }catch{ next(new Error('unauthorized')); }
});
io.on('connection',(socket)=>{
  const uid = socket.data.uid;
  console.log('🔗 connected:', uid);
  socket.join(uid);
  socket.on('disconnect',()=>console.log('❌ disconnected:', uid));
});

/* =============== Conversations / Requests =============== */

// Create request (email-based)
app.post('/chat-requests', requireAuth, async (req,res)=>{
  try{
    const { from, toEmail } = req.body||{};
    if(!from || !toEmail) return res.status(400).json({error:'missing_fields'});
    if(String(from)!==req.user.uid) return res.status(403).json({error:'forbidden'});

    const to = await uidByEmail(toEmail);
    if(!to) return res.status(404).json({error:'no_user_for_email', email:toEmail});

    const participants = pair(from, to);
    let convo = await Conversation.findOne({
      participants: { $all: participants, $size: 2 },
      status: { $in: ['pending','active'] }
    });

    if(!convo){
      convo = await Conversation.create({
        participants, status:'pending', createdBy: from, lastMessageAt: null
      });
    }

    // notify receiver
    io.to(String(to)).emit('chat_request', {
      _id: String(convo._id),
      from: String(from),
      to: String(to),
      status: convo.status,
      createdAt: convo.createdAt,
    });

    res.json({ ok:true, conversation: convo });
  }catch(e){ console.error(e); res.status(500).json({error:'server_error'}); }
});

// List requests (pending/active/declined)
app.get('/chat-requests', requireAuth, async (req,res)=>{
  try{
    const { me, status='pending' } = req.query;
    if(!me) return res.status(400).json({error:'missing_me'});
    if(String(me)!==req.user.uid) return res.status(403).json({error:'forbidden'});

    // pending/declined တွေကို createdAt desc နဲ့
    const items = await Conversation.find({ participants: me, status })
      .sort({ createdAt: -1 })
      .lean();
    res.json(items);
  }catch(e){ res.status(500).json({error:'server_error'}); }
});

// Active conversations list (✅ lastMessageAt desc → updatedAt desc)
app.get('/conversations', requireAuth, async (req,res)=>{
  try{
    const { me, status='active' } = req.query;
    if(!me) return res.status(400).json({error:'missing_me'});
    if(String(me)!==req.user.uid) return res.status(403).json({error:'forbidden'});

    const items = await Conversation.find({ participants: me, status })
      .sort({ lastMessageAt: -1, updatedAt: -1 })
      .lean();
    res.json(items);
  }catch(e){ res.status(500).json({error:'server_error'}); }
});

// Accept request (✅ initialize lastMessageAt)
app.post('/chat-requests/:id/accept', requireAuth, async (req,res)=>{
  try{
    const { id } = req.params;
    const me = req.body?.me;
    if(!me) return res.status(400).json({error:'missing_me'});
    if(String(me)!==req.user.uid) return res.status(403).json({error:'forbidden'});

    const convo = await Conversation.findById(id);
    if(!convo) return res.status(404).json({error:'not_found'});
    if(!convo.participants.map(String).includes(String(me)))
      return res.status(403).json({error:'forbidden'});

    convo.status = 'active';
    // ❗ accept တုန်းက ယာယီ bump — first message မတိုင်ခင် UI ထိန်းညှိ
    if (!convo.lastMessageAt) convo.lastMessageAt = new Date();
    await convo.save();

    // tell both who their partner is
    for(const p of convo.participants){
      const partner = convo.participants.find(x=> String(x)!==String(p));
      io.to(String(p)).emit('chat_request_accepted', {
        conversationId: String(convo._id),
        partnerId: String(partner),
      });
    }
    res.json({ ok:true, conversation: convo });
  }catch(e){ console.error(e); res.status(500).json({error:'server_error'}); }
});

// Decline request
app.post('/chat-requests/:id/decline', requireAuth, async (req,res)=>{
  try{
    const { id } = req.params;
    const me = req.body?.me;
    if(!me) return res.status(400).json({error:'missing_me'});
    if(String(me)!==req.user.uid) return res.status(403).json({error:'forbidden'});

    const convo = await Conversation.findById(id);
    if(!convo) return res.status(404).json({error:'not_found'});
    if(!convo.participants.map(String).includes(String(me)))
      return res.status(403).json({error:'forbidden'});

    convo.status = 'declined';
    await convo.save();

    io.to(String(convo.createdBy)).emit('chat_request_declined', {
      conversationId: String(convo._id),
      by: String(me),
    });
    res.json({ ok:true, conversation: convo });
  }catch(e){ res.status(500).json({error:'server_error'}); }
});

/* ===================== Messages ===================== */

// Send message (✅ bump lastMessageAt by server time)
app.post('/messages', requireAuth, async (req, res) => {
  try {
    const { from, toEmail, text } = req.body || {};
    if (!from || !toEmail || !text) return res.status(400).json({ error: 'missing_fields' });
    if (String(from) !== req.user.uid) return res.status(403).json({ error: 'forbidden' });

    const to = await uidByEmail(toEmail);
    if (!to) return res.status(404).json({ error: 'no_user_for_email', email: toEmail });

    // active conversation ရှိနေလာမလား စစ်
    const [A,B] = pair(from, to);
    const convo = await Conversation.findOne({
      participants: { $all: [A,B], $size: 2 },
      status: 'active',
    });
    if (!convo) return res.status(403).json({ error: 'not_accepted' });

    // create message
    const msg = await Message.create({ from, to, text, conversation: convo._id });

    // ✅ bump lastMessageAt (monotonic)
    await Conversation.updateOne(
      { _id: convo._id },
      { $max: { lastMessageAt: msg.createdAt }, $set: { updatedAt: new Date() } },
    );

    const payload = {
      _id: String(msg._id),
      conversationId: String(convo._id),
      from: String(from),
      to: String(to),
      text,
      createdAt: msg.createdAt.toISOString(),
      lastMessageAt: msg.createdAt.toISOString(), // convenience for client
    };

    // echo to both (frontend already de-dupes)
    io.to(String(to)).emit('message', payload);
    io.to(String(from)).emit('message', payload);

    res.json({ ok: true, message: payload });
  } catch (e) {
    console.error('Message error:', e);
    res.status(500).json({ error: 'server_error' });
  }
});
// Update my profile (name / password optional)
app.patch('/users/me', requireAuth, async (req, res) => {
  try {
    const { name, password } = req.body || {};
    const update = {};
    if (typeof name === 'string' && name.trim().length > 0) {
      update.name = name.trim();
    }
    if (typeof password === 'string' && password.length >= 6) {
      update.passwordHash = await bcrypt.hash(password, 10);
    }
    if (Object.keys(update).length === 0) {
      return res.status(400).json({ error: 'nothing_to_update' });
    }
    const u = await User.findByIdAndUpdate(req.user.uid, update, { new: true });
    return res.json({ user: { id: String(u._id), name: u.name, email: u.email } });
  } catch (e) {
    console.error('update profile error:', e);
    return res.status(500).json({ error: 'server_error' });
  }
});


// History
app.get('/messages', requireAuth, async (req,res)=>{
  try{
    const { userA, userB } = req.query;
    const items = await Message.find({
      $or:[ {from:userA, to:userB}, {from:userB, to:userA} ]
    }).sort({createdAt:1});
    res.json(items);
  }catch(e){ res.status(500).json({error:'server_error'}); }
});

// IDs -> profile map (for email display)
app.get('/users/by-ids', requireAuth, async (req,res)=>{
  try{
    const ids = (req.query.ids||'').toString().split(',').filter(Boolean);
    const users = await User.find({ _id: { $in: ids } }).select('_id email name').lean();
    const map = {}; for(const u of users) map[String(u._id)] = { email:u.email, name:u.name };
    res.json(map);
  }catch(e){ res.status(500).json({error:'server_error'}); }
});

app.get('/ping', (_req,res)=> res.json({ pong:true }));

const PORT = process.env.PORT || 3000;
server.listen(PORT, ()=> console.log(`🚀 API + WS on http://localhost:${PORT}`));
