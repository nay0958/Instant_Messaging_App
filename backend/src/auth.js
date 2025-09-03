import express from 'express';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import User from './models/User.js';

const router = express.Router();
const JWT_SECRET = process.env.JWT_SECRET || 'devsecret';

const sign = (uid) => jwt.sign({ uid: String(uid) }, JWT_SECRET, { expiresIn: '7d' });

router.post('/register', async (req,res)=>{
  const {name,email,password} = req.body||{};
  if(!name||!email||!password) return res.status(400).json({error:'missing'});
  const exists = await User.findOne({email});
  if(exists) return res.status(409).json({error:'email_taken'});
  const user = await User.create({name,email,passwordHash: await bcrypt.hash(password,10)});
  res.status(201).json({ token: sign(user._id), user: {id:user._id, name:user.name, email:user.email} });
});

router.post('/login', async (req,res)=>{
  const {email,password} = req.body||{};
  if(!email||!password) return res.status(400).json({error:'missing'});
  const user = await User.findOne({email});
  if(!user) return res.status(401).json({error:'invalid_credentials'});
  const ok = await bcrypt.compare(password, user.passwordHash||'');
  if(!ok) return res.status(401).json({error:'invalid_credentials'});
  res.json({ token: sign(user._id), user: {id:user._id, name:user.name, email:user.email} });
});

router.get('/me', async (req,res)=>{
  try{
    const raw = (req.headers.authorization||'').replace('Bearer ','');
    const { uid } = jwt.verify(raw, JWT_SECRET);
    const u = await User.findById(uid).lean();
    if(!u) return res.status(401).json({error:'bad_token'});
    res.json({ user: {id:u._id, name:u.name, email:u.email} });
  }catch{ res.status(401).json({error:'bad_token'}); }
});

export default router;
