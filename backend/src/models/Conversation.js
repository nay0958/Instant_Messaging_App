import mongoose from 'mongoose';

const ConversationSchema = new mongoose.Schema({
  participants: [
    { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true },
  ], // [A,B] (sorted)
  status: {
    type: String,
    enum: ['pending', 'active', 'declined', 'blocked'],
    default: 'pending',
  },
  createdBy: { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true },

  // ✅ NEW: last message time (server-managed)
  lastMessageAt: { type: Date, default: null },
}, { timestamps: true });

// ✅ Active ကို အပေါ်စီ — status + lastMessageAt desc + updatedAt desc
ConversationSchema.index({ status: 1, lastMessageAt: -1, updatedAt: -1 });

export default mongoose.models.Conversation ||
  mongoose.model('Conversation', ConversationSchema);
