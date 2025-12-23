// C:\Users\ASUS\Desktop\mess\study1\backend\src\models\Message.js
import mongoose from 'mongoose';

const { Schema } = mongoose;

const MessageSchema = new Schema(
  {
    from: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    to:   { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },

    // message body
    text: { type: String, required: true, trim: true, maxlength: 4000 },

    // Link to a conversation (optional for older data)
    conversation: { type: Schema.Types.ObjectId, ref: 'Conversation', index: true },

    // Soft delete
    deleted:   { type: Boolean, default: false, index: true },
    deletedAt: { type: Date },
    edited: { type: Boolean, default: false },
    editedAt: { type: Date },
    
    // File attachments
    fileUrl: { type: String },
    fileName: { type: String },
    fileType: { type: String },
    audioDuration: { type: Number }, // Duration in seconds for voice messages
    
    // Call activity metadata
    messageType: { type: String }, // 'call_activity' for call history messages
    callActivity: { type: Boolean, default: false },
    callType: { type: String }, // 'outgoing' or 'incoming'
    callStatus: { type: String }, // 'completed', 'missed', 'rejected', 'cancelled'
    isVideoCall: { type: Boolean, default: false },
    callStartTime: { type: Date },
    callDuration: { type: Number }, // Duration in seconds
    
    // Reply/Quote functionality
    replyTo: { type: Schema.Types.ObjectId, ref: 'Message' }, // ID of the message being replied to
    replyToMessage: { type: Schema.Types.Mixed }, // Original message data for preview (text, from, fileType, etc.)
  },
  { timestamps: true }
);

/* ---------- Helpful indexes ---------- */
// Query by convo timeline
MessageSchema.index({ conversation: 1, createdAt: 1 });

// Direct A<->B timeline queries
MessageSchema.index({ from: 1, to: 1, createdAt: 1 });

// Fallback sort
MessageSchema.index({ createdAt: 1 });

export default mongoose.models.Message ||
  mongoose.model('Message', MessageSchema);
