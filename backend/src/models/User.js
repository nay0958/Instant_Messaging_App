import mongoose from 'mongoose';

// Normalize phone number (same as backend helpers; always "+<digits>")
const normalizePhone = (phone) => {
  if (!phone) return phone;
  const raw = phone.toString().trim();
  const digits = raw.replace(/\D/g, '');
  if (!digits) return phone;
  return `+${digits}`;
};

const UserSchema = new mongoose.Schema({
  name: {
    type: String,
    required: [true, 'Name is required'],
    trim: true,
    minlength: [1, 'Name cannot be empty'],
  },
  phone: {
    type: String,
    required: [true, 'Phone number is required'],
    trim: true,
    // Custom setter to normalize phone number
    set: (value) => {
      return normalizePhone(value);
    },
  },
  passwordHash: {
    type: String,
    required: false, // Optional - only for users who set password during registration
  },
  googleSub: {
    type: String,
    sparse: true, // Allows multiple null values but enforces uniqueness for non-null
  },
  avatarUrl: {
    type: String,
    default: null,
  },
  bio: {
    type: String,
    default: null,
    maxlength: [500, 'Bio cannot exceed 500 characters'],
  },
  fcmToken: {
    type: String,
    default: null,
    sparse: true, // Allow multiple null values
  },
}, {
  timestamps: true,
  collection: 'users', // Explicitly set collection name
});

// Pre-save hook to ensure phone is always normalized
UserSchema.pre('save', function(next) {
  if (this.phone) {
    this.phone = normalizePhone(this.phone);
  }
  next();
});

// Pre-update hook to ensure phone is normalized on updates
UserSchema.pre(['updateOne', 'findOneAndUpdate', 'updateMany'], function(next) {
  const update = this.getUpdate();
  if (update && update.phone) {
    update.phone = normalizePhone(update.phone);
  }
  if (update && update.$set && update.$set.phone) {
    update.$set.phone = normalizePhone(update.$set.phone);
  }
  next();
});

// Ensure index is created
UserSchema.index({ phone: 1 }, { unique: true });

// Export model (handle both Next.js and regular Node.js)
let User;
try {
  // Try to get existing model (for Next.js hot reload)
  User = mongoose.models.User || mongoose.model('User', UserSchema);
} catch (error) {
  // If model doesn't exist, create it
  User = mongoose.model('User', UserSchema);
}

// Clean up legacy indexes that referenced email (from old schema)
// This prevents duplicate key errors like:
// E11000 duplicate key error collection: messaging.users index: email_1 dup key: { email: null }
try {
  // Drop the old email index if it exists. Ignore "Index not found" errors.
  User.collection
    .dropIndex('email_1')
    .then(() => {
      console.log('✅ Dropped legacy index email_1 from users collection');
    })
    .catch((err) => {
      if (err && err.codeName !== 'IndexNotFound' && err.code !== 27) {
        console.error('⚠️ Failed to drop legacy email_1 index:', err.message || err);
      }
    });
} catch (err) {
  // Non-fatal – just log and continue
  console.error('⚠️ Error while attempting to drop legacy email_1 index:', err.message || err);
}

export default User;
