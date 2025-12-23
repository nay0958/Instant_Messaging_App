import mongoose from 'mongoose';

const ConversationSchema = new mongoose.Schema({
  participants: [{ type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true }],
  status: { type: String, enum: ['pending','active','declined','blocked'], default: 'pending' },
  createdBy: { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true },
 
  lastMessageAt: { type: Date },
  deliveredUpTo: { type: Map, of: Date, default: {} }, 
  readUpTo:      { type: Map, of: Date, default: {} }, 


}, { timestamps: true });

// helpful indexes (optional but good)
ConversationSchema.index({ participants: 1, status: 1 });
ConversationSchema.index({ status: 1, lastMessageAt: -1, updatedAt: -1 });

export default mongoose.models.Conversation ||
  mongoose.model('Conversation', ConversationSchema);
