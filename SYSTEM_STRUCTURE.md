# 🏗️ Messaging App - Complete System Structure
## Clean Architecture Documentation

---

## 📐 1. High-Level System Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                    MESSAGING APPLICATION SYSTEM                        │
└──────────────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────┐
    │         CLIENT LAYER                  │
    │         (Flutter Mobile App)          │
    │                                       │
    │  ┌─────────────────────────────────┐ │
    │  │   Presentation Layer            │ │
    │  │   • UI Pages                    │ │
    │  │   • Reusable Widgets            │ │
    │  └──────────────┬──────────────────┘ │
    │                 │                     │
    │  ┌──────────────▼──────────────────┐ │
    │  │   Business Logic Layer         │ │
    │  │   • Services                    │ │
    │  │   • State Management            │ │
    │  └──────────────┬──────────────────┘ │
    │                 │                     │
    │  ┌──────────────▼──────────────────┐ │
    │  │   Data Layer                    │ │
    │  │   • Data Models                 │ │
    │  │   • Local Storage               │ │
    │  └─────────────────────────────────┘ │
    └───────────────────┬───────────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
    ┌───▼───┐       ┌───▼───┐       ┌───▼───┐
    │ HTTP  │       │ WebSocket│     │ File  │
    │ REST  │       │ Socket.io│     │ Upload│
    └───┬───┘       └───┬───┘       └───┬───┘
        │               │               │
        └───────────────┼───────────────┘
                        │
    ┌───────────────────▼───────────────────┐
    │         SERVER LAYER                    │
    │         (Node.js + Express)            │
    │                                        │
    │  ┌──────────────────────────────────┐ │
    │  │   API Layer                      │ │
    │  │   • REST Endpoints               │ │
    │  │   • Route Handlers               │ │
    │  └──────────────┬───────────────────┘ │
    │                 │                      │
    │  ┌──────────────▼───────────────────┐ │
    │  │   Real-time Layer                │ │
    │  │   • Socket.io Events             │ │
    │  │   • WebRTC Signaling             │ │
    │  └──────────────┬───────────────────┘ │
    │                 │                      │
    │  ┌──────────────▼───────────────────┐ │
    │  │   Business Logic                 │ │
    │  │   • Authentication                │ │
    │  │   • Message Processing            │ │
    │  │   • Call Management               │ │
    │  └──────────────┬───────────────────┘ │
    │                 │                      │
    │  ┌──────────────▼───────────────────┐ │
    │  │   Data Access Layer              │ │
    │  │   • MongoDB Database             │ │
    │  │   • File System Storage          │ │
    │  └──────────────────────────────────┘ │
    └────────────────────────────────────────┘
```

---

## 🎯 2. Frontend System Structure (Flutter)

### **2.1 Application Entry & Routing**

```
main.dart
  │
  └──► MaterialApp
         │
         └──► ThemeService (Light/Dark Theme)
                │
                └──► splash_gate.dart
                       │
                       ├──► [Not Authenticated]
                       │    └──► login_page.dart
                       │         └──► auth_store.dart
                       │
                       └──► [Authenticated]
                            └──► home_page.dart
```

### **2.2 Presentation Layer (UI Pages)**

```
home_page.dart (Main Navigation Hub)
  │
  ├──► ChatsTab
  │    ├──► ChatList
  │    │    └──► ChatItem (with unread badges)
  │    └──► SearchBar
  │
  ├──► ContactsTab
  │    ├──► ContactList
  │    │    └──► ContactItem (with online status)
  │    └──► AddContactButton
  │
  └──► CallHistoryTab
       ├──► CallLogList
       │    └──► CallLogItem
       └──► FilterChips (All/Outgoing/Incoming)

chat_page.dart (Real-time Chat Interface)
  │
  ├──► AppBar (with peer info & actions)
  ├──► MessageList (flexible_chat_list.dart)
  │    ├──► TextMessage
  │    ├──► ImageMessage
  │    ├──► VideoMessage
  │    ├──► VoiceMessage
  │    └──► CallActivityMessage
  │
  ├──► MessageComposer (flexible_composer.dart)
  │    ├──► TextInput
  │    ├──► EmojiPicker
  │    ├──► AttachmentButton
  │    └──► VoiceRecordButton
  │
  └──► MediaViewer (for images/videos)

call_page.dart (Voice/Video Call Screen)
  │
  ├──► CallUI
  │    ├──► VideoView (local & remote)
  │    ├──► CallControls
  │    │    ├──► Mute/Unmute
  │    │    ├──► Video On/Off
  │    │    └──► End Call
  │    └──► CallInfo (duration, status)
  │
  └──► CallManager Integration

profile.dart (User Profile Management)
  │
  ├──► ProfileHeader (avatar, name, status)
  ├──► ProfileDetails
  ├──► SettingsSection
  └──► ThemeCustomization
```

### **2.3 Business Logic Layer (Services)**

```
socket_service.dart (WebSocket Communication)
  ├──► Connection Management
  ├──► Event Handlers
  │    ├──► message
  │    ├──► message:delivered
  │    ├──► message:read
  │    ├──► typing
  │    ├──► presence
  │    └──► call:incoming
  └──► Event Emitters

api.dart (REST API Client)
  ├──► HTTP Client Setup
  ├──► Request Builder
  ├──► Response Handler
  └──► Error Handling

call_manager.dart (Call State Management)
  ├──► Call State Machine
  ├──► WebRTC Setup
  ├──► Media Stream Management
  └──► Call Signaling

call_signal.dart (WebRTC Signaling)
  ├──► Offer/Answer Exchange
  ├──► ICE Candidate Handling
  └──► Connection Management

file_service.dart (File Operations)
  ├──► Image Upload
  ├──► Video Upload
  ├──► Audio Upload
  └──► File Download

voice_message_service.dart (Voice Messages)
  ├──► Audio Recording
  ├──► Audio Playback
  └──► Audio Processing

call_log_service.dart (Call History)
  ├──► Save Call Log
  ├──► Retrieve Call Logs
  └──► Filter Call Logs

theme_service.dart (Theme Management)
  ├──► Theme Mode (Light/Dark)
  ├──► Color Scheme
  └──► Chat Wallpaper

notifications.dart (Push Notifications)
  ├──► Notification Setup
  ├──► Show Notification
  └──► Handle Notification Tap
```

### **2.4 Data Models Layer**

```
models/
  │
  ├──► call_log.dart
  │    ├──► CallLog class
  │    ├──► CallType enum (incoming/outgoing)
  │    ├──► CallStatus enum (completed/missed/rejected)
  │    └──► Methods (formatDuration, formatTime)
  │
  ├──► user_profile.dart
  │    ├──► UserProfile class
  │    └──► fromJson/toJson methods
  │
  ├──► user_preferences.dart
  │    └──► UserPreferences class
  │
  └──► storage_info.dart
       └──► StorageInfo class
```

### **2.5 UI Components Layer (Widgets)**

```
widgets/
  │
  ├──► avatar_with_status.dart
  │    └──► Avatar with online/offline indicator
  │
  ├──► call_activity_message.dart
  │    └──► Call history display in chat
  │
  ├──► call_log_item.dart
  │    └──► Individual call log entry
  │
  ├──► call_status_banner.dart
  │    └──► Active call status indicator
  │
  ├──► flexible_app_bar.dart
  │    └──► Custom app bar component
  │
  ├──► flexible_chat_list.dart
  │    └──► Message list view
  │
  ├──► flexible_composer.dart
  │    └──► Message input composer
  │
  ├──► reply_bubble.dart
  │    └──► Message reply UI
  │
  ├──► voice_recording_ui.dart
  │    └──► Voice recording interface
  │
  ├──► setting_item.dart
  │    └──► Settings list item
  │
  └──► settings_section.dart
       └──► Settings section wrapper
```

### **2.6 Configuration & Utilities**

```
config/
  └──► app_config.dart
       ├──► Network Configuration
       ├──► UI Settings
       ├──► Feature Flags
       └──► Color Schemes

utils/
  ├──► connection_helper.dart
  │    └──► Network utilities
  │
  ├──► flexible_message_builder.dart
  │    └──► Message builder helper
  │
  └──► responsive.dart
       └──► Responsive design helpers
```

### **2.7 Local Storage Structure**

```
SharedPreferences (Flutter)
  │
  ├──► Authentication
  │    ├──► auth_token (JWT)
  │    ├──► user_id
  │    └──► refresh_token
  │
  ├──► User Data
  │    ├──► user_profile (JSON)
  │    └──► user_preferences (JSON)
  │
  ├──► Call History
  │    └──► call_logs_[userId] (JSON array)
  │
  └──► App Settings
       ├──► theme_mode
       ├──► primary_color
       ├──► chat_wallpaper
       └──► app_settings (JSON)
```

---

## 🖥️ 3. Backend System Structure (Node.js)

### **3.1 Server Setup & Configuration**

```
backend/src/index.js (Main Server Entry)
  │
  ├──► Express App Initialization
  │    ├──► CORS Configuration
  │    ├──► Body Parser Middleware
  │    ├──► File Upload (Multer)
  │    └──► Static File Serving
  │
  ├──► Socket.io Setup
  │    ├──► CORS Configuration
  │    ├──► Authentication Middleware
  │    └──► Connection Handler
  │
  ├──► MongoDB Connection
  │    └──► Database Models Registration
  │
  └──► Route Registration
       ├──► /auth routes
       ├──► /messages routes
       ├──► /conversations routes
       └──► /users routes
```

### **3.2 API Routes Layer**

```
auth.js (Authentication Routes)
  │
  ├──► POST /auth/register
  │    └──► User registration with email
  │
  ├──► POST /auth/login
  │    └──► User login, returns JWT
  │
  ├──► POST /auth/verify-otp
  │    └──► OTP verification
  │
  └──► GET  /auth/me
       └──► Get current user profile

index.js (Message & Conversation Routes)
  │
  ├──► GET  /messages
  │    └──► Get message history
  │
  ├──► POST /messages
  │    └──► Send new message
  │
  ├──► GET  /conversations
  │    └──► Get conversations list
  │
  ├──► POST /conversations
  │    └──► Create/accept conversation
  │
  └──► GET  /users/by-ids
       └──► Get user profiles by IDs
```

### **3.3 WebSocket Events (Socket.io)**

```
Socket.io Event Handlers
  │
  ├──► connection
  │    └──► Authenticate user, join rooms
  │
  ├──► message
  │    └──► Broadcast message to recipient
  │
  ├──► message:delivered
  │    └──► Update delivery status
  │
  ├──► message:read
  │    └──► Update read status
  │
  ├──► typing
  │    └──► Broadcast typing indicator
  │
  ├──► presence
  │    └──► Update online/offline status
  │
  ├──► call:incoming
  │    └──► Signal incoming call
  │
  ├──► call:ringing
  │    └──► Call ringing status
  │
  ├──► call:answer
  │    └──► Call answered
  │
  ├──► call:declined
  │    └──► Call declined
  │
  └──► call:ended
       └──► Call ended
```

### **3.4 Data Models (MongoDB Schemas)**

```
models/
  │
  ├──► User.js
  │    ├──► Schema
  │    │    ├──► name, email, password
  │    │    ├──► avatarUrl
  │    │    └──► createdAt, updatedAt
  │    ├──► Methods
  │    │    └──► Password hashing
  │    └──► Indexes
  │
  ├──► Message.js
  │    ├──► Schema
  │    │    ├──► from, to, text
  │    │    ├──► fileUrl, fileType
  │    │    ├──► conversationId
  │    │    ├──► deliveredAt, readAt
  │    │    └──► createdAt
  │    ├──► Methods
  │    └──► Indexes (from, to, conversationId)
  │
  └──► Conversation.js
       ├──► Schema
       │    ├──► participants (array)
       │    ├──► status (pending/active)
       │    ├──► lastMessageAt
       │    └──► createdAt, updatedAt
       ├──► Methods
       └──► Indexes (participants)
```

### **3.5 File Storage Structure**

```
backend/uploads/
  │
  ├──► images/
  │    ├──► profile_pictures/
  │    └──► chat_images/
  │
  ├──► videos/
  │    └──► video_messages/
  │
  └──► audio/
       └──► voice_messages/
```

---

## 🔄 4. System Communication Flow

### **4.1 Authentication Flow**

```
Client                          Server
  │                               │
  │─── POST /auth/login ─────────▶│
  │                               │─── Validate Credentials
  │                               │─── Generate JWT
  │◀── JWT Token ─────────────────│
  │                               │
  │─── Connect WebSocket (with JWT)▶│
  │                               │─── Authenticate Socket
  │◀── Socket Connected ──────────│
```

### **4.2 Real-time Messaging Flow**

```
User A                    Server                    User B
  │                         │                         │
  │─── Send Message ────────▶│                         │
  │                         │─── Save to DB ────────▶│
  │                         │                         │
  │                         │◀── Message Saved ──────│
  │                         │                         │
  │                         │─── Broadcast ───────────▶│
  │                         │                         │
  │◀── Delivery Status ──────│                         │
  │                         │◀── Read Receipt ────────│
  │                         │                         │
  │◀── Read Confirmation ────│                         │
```

### **4.3 Call Flow**

```
User A                    Server                    User B
  │                         │                         │
  │─── Call Request ────────▶│                         │
  │                         │─── Incoming Call ───────▶│
  │                         │                         │
  │                         │◀── Accept Call ─────────│
  │                         │                         │
  │◀── WebRTC Offer ─────────│                         │
  │                         │◀── WebRTC Answer ───────│
  │                         │                         │
  │◀── ICE Candidates ──────┼────────────────────────▶│
  │                         │                         │
  │◀── P2P Connection ──────┼────────────────────────▶│
```

---

## 📊 5. Complete Component Interaction

```
┌─────────────────────────────────────────────────────────────┐
│                    APPLICATION FLOW                          │
└─────────────────────────────────────────────────────────────┘

main.dart
  │
  └──► splash_gate.dart
         │
         ├──► [Not Authenticated]
         │    └──► login_page.dart
         │         │
         │         └──► auth_store.dart
         │              │
         │              └──► api.dart ──► POST /auth/login
         │
         └──► [Authenticated]
              └──► home_page.dart
                   │
                   ├──► ChatsTab
                   │    │
                   │    └──► chat_page.dart
                   │         │
                   │         ├──► socket_service.dart
                   │         │    └──► WebSocket ──► Server
                   │         │
                   │         ├──► file_service.dart
                   │         │    └──► POST /upload ──► Server
                   │         │
                   │         └──► voice_message_service.dart
                   │
                   ├──► ContactsTab
                   │    │
                   │    └──► Friends_page.dart
                   │         │
                   │         └──► api.dart ──► GET /conversations
                   │
                   └──► CallHistoryTab
                        │
                        └──► call_history_screen.dart
                             │
                             └──► call_log_service.dart
                                  │
                                  └──► SharedPreferences
```

---

## 🔌 6. API Endpoints Summary

### **6.1 Authentication Endpoints**

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/auth/register` | Register new user |
| POST | `/auth/login` | User login |
| POST | `/auth/verify-otp` | Verify OTP code |
| GET | `/auth/me` | Get current user |

### **6.2 Messaging Endpoints**

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/messages` | Get message history |
| POST | `/messages` | Send new message |
| DELETE | `/messages/:id` | Delete message |

### **6.3 Conversation Endpoints**

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/conversations` | Get conversations list |
| POST | `/conversations` | Create conversation |
| PUT | `/conversations/:id` | Update conversation |

### **6.4 User Endpoints**

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/users/by-ids` | Get user profiles |
| PUT | `/users/me` | Update profile |
| POST | `/users/upload-avatar` | Upload avatar |

### **6.5 WebSocket Events**

**Client → Server:**
- `message` - Send message
- `typing` - Typing indicator
- `presence` - Update online status
- `call:incoming` - Initiate call
- `call:answer` - Answer call
- `call:declined` - Decline call

**Server → Client:**
- `message` - Receive message
- `message:delivered` - Delivery confirmation
- `message:read` - Read receipt
- `typing` - Typing indicator
- `presence` - User status update
- `call:incoming` - Incoming call notification
- `call:ringing` - Call ringing
- `call:ended` - Call ended

---

## 💾 7. Data Storage Architecture

### **7.1 Frontend Storage (Local)**

```
SharedPreferences
  │
  ├──► Authentication Data
  │    ├──► auth_token: String
  │    ├──► user_id: String
  │    └──► refresh_token: String
  │
  ├──► User Profile
  │    └──► user_profile: JSON String
  │
  ├──► Call Logs
  │    └──► call_logs_[userId]: JSON Array
  │
  ├──► Theme Settings
  │    ├──► theme_mode: String
  │    ├──► primary_color: String
  │    ├──► secondary_color: String
  │    └──► chat_wallpaper: String
  │
  └──► App Preferences
       └──► app_settings: JSON String
```

### **7.2 Backend Storage (Database)**

```
MongoDB Database: messaging_app
  │
  ├──► users Collection
  │    ├──► _id: ObjectId
  │    ├──► name: String
  │    ├──► email: String (unique, indexed)
  │    ├──► password: String (hashed)
  │    ├──► avatarUrl: String
  │    └──► createdAt, updatedAt: Date
  │
  ├──► messages Collection
  │    ├──► _id: ObjectId
  │    ├──► from: ObjectId (ref: users)
  │    ├──► to: ObjectId (ref: users)
  │    ├──► text: String
  │    ├──► fileUrl: String
  │    ├──► fileType: String
  │    ├──► conversationId: ObjectId
  │    ├──► deliveredAt: Date
  │    ├──► readAt: Date
  │    └──► createdAt: Date (indexed)
  │
  ├──► conversations Collection
  │    ├──► _id: ObjectId
  │    ├──► participants: [ObjectId] (indexed)
  │    ├──► status: String (pending/active)
  │    ├──► lastMessageAt: Date
  │    └──► createdAt, updatedAt: Date
  │
  └──► call_logs Collection
       ├──► _id: ObjectId
       ├──► from: ObjectId (ref: users)
       ├──► to: ObjectId (ref: users)
       ├──► type: String (incoming/outgoing)
       ├──► status: String (completed/missed/rejected)
       ├──► duration: Number (seconds)
       ├──► isVideoCall: Boolean
       └──► startTime, endTime: Date
```

---

## 🎨 8. UI Component Hierarchy

```
MaterialApp
  │
  └──► ThemeService
       │
       └──► SplashGate
            │
            ├──► LoginPage
            │    ├──► EmailInput
            │    ├──► PasswordInput
            │    └──► LoginButton
            │
            └──► HomePage
                 │
                 ├──► CustomAppBar
                 │    ├──► Title
                 │    ├──► SearchBar
                 │    └──► ProfileButton
                 │
                 ├──► TabBar
                 │    ├──► ChatsTab
                 │    ├──► ContactsTab
                 │    └──► CallHistoryTab
                 │
                 └──► BottomNavigationBar
                      ├──► ChatsIcon
                      ├──► ContactsIcon
                      └──► CallsIcon
```

---

## 🔑 9. Technology Stack

### **Frontend Technologies**
- **Framework**: Flutter 3.x
- **Language**: Dart
- **State Management**: StatefulWidget (setState)
- **Networking**: 
  - `http` package (REST API)
  - `socket_io_client` (WebSocket)
- **Real-time Communication**: WebSocket (Socket.io)
- **Voice/Video Calls**: WebRTC
- **Local Storage**: SharedPreferences
- **Image Handling**: cached_network_image
- **File Operations**: image_picker, file_picker

### **Backend Technologies**
- **Runtime**: Node.js
- **Framework**: Express.js
- **Real-time**: Socket.io
- **Database**: MongoDB (Mongoose)
- **Authentication**: JWT (jsonwebtoken)
- **File Upload**: Multer
- **Password Hashing**: bcrypt
- **Validation**: Express validators

---

## 📈 10. System Flow Summary

### **10.1 User Registration Flow**

```
1. User enters email → POST /auth/register
2. Server sends OTP → Email service
3. User enters OTP → POST /auth/verify-otp
4. Server creates user → MongoDB
5. Server returns JWT → Client stores token
6. Client connects WebSocket → Real-time ready
```

### **10.2 Message Sending Flow**

```
1. User types message → UI updates
2. User sends → socket_service.emit('message')
3. Server receives → Save to MongoDB
4. Server broadcasts → Socket.io to recipient
5. Recipient receives → Update UI
6. Server sends delivery → Update status
7. Recipient reads → Send read receipt
8. Sender receives → Update read status
```

### **10.3 Call Initiation Flow**

```
1. User taps call → call_manager.initiateCall()
2. Client sends → socket.emit('call:incoming')
3. Server receives → Broadcast to recipient
4. Recipient receives → Show incoming call UI
5. Recipient accepts → WebRTC offer/answer exchange
6. P2P connection → Direct media stream
7. Call ends → Save to call_logs
```

---

## ✅ 11. Key Features Implementation

### **✅ Real-time Messaging**
- WebSocket bidirectional communication
- Message delivery status tracking
- Read receipts
- Typing indicators
- Online/offline presence

### **✅ Voice/Video Calls**
- WebRTC peer-to-peer connection
- Server-side signaling
- Call history tracking
- Call status management

### **✅ File Sharing**
- Image upload/download
- Video message support
- Voice message recording/playback
- File type validation

### **✅ User Management**
- JWT-based authentication
- Profile management
- Contact discovery
- Friend request system

### **✅ Theme Customization**
- Light/Dark mode
- Custom color schemes
- Chat wallpaper options
- Dynamic theme switching

---

## 🎯 12. System Architecture Principles

1. **Separation of Concerns**
   - UI Layer (Pages/Widgets)
   - Business Logic (Services)
   - Data Layer (Models/Storage)

2. **Modularity**
   - Independent services
   - Reusable components
   - Clear interfaces

3. **Scalability**
   - Stateless server design
   - Horizontal scaling ready
   - Efficient database queries

4. **Security**
   - JWT authentication
   - Password hashing
   - Input validation
   - CORS protection

5. **Real-time Capabilities**
   - WebSocket for instant updates
   - Event-driven architecture
   - Efficient message broadcasting

---

This complete system structure document provides a comprehensive overview of your messaging application architecture, ready for presentation and documentation purposes.
