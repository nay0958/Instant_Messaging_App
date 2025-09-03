import mongoose from 'mongoose';

const MessageSchema = new mongoose.Schema({
  from: { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true },
  to:   { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true },
  text: { type: String, required: true },

  // ✅ NEW: link to conversation (backfill မလိုရင် null ဖြစ်နိုင်)
  conversation: { type: mongoose.Schema.Types.ObjectId, ref: 'Conversation' },
}, { timestamps: true });

// အလွယ်တကူ query ပြုလုပ်ဖို့ index (optional)
MessageSchema.index({ from: 1, to: 1, createdAt: 1 });

export default mongoose.models.Message ||
  mongoose.model('Message', MessageSchema);
