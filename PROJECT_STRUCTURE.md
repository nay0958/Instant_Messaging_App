# 📱 Messaging App - Project Structure
## Architecture Overview for Presentation

---

## 🏗️ System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLIENT-SERVER ARCHITECTURE                │
└─────────────────────────────────────────────────────────────────┘

    ┌──────────────────────┐              ┌──────────────────────┐
    │   CLIENT (Flutter)    │              │   SERVER (Node.js)   │
    │                       │              │                      │
    │  • Mobile App         │◄──HTTP/REST──►│  • Express Server    │
    │  • Real-time UI       │              │  • RESTful API       │
    │  • Local Storage      │◄──WebSocket──►│  • Socket.io         │
    │  • State Management   │              │  • JWT Auth          │
    └──────────────────────┘              └──────────────────────┘
```

---

## 📂 Frontend Structure (Flutter/Dart)

### **Core Application Layer**

```
lib/
│
├── 🚀 Entry Point
│   ├── main.dart                    # Application bootstrap
│   └── splash_gate.dart             # Authentication router
│
├── 🔐 Authentication Layer
│   ├── login_page.dart               # User login UI
│   ├── login_otp_page.dart           # OTP verification
│   ├── register_page.dart            # User registration
│   └── auth_store.dart               # ⭐ Auth state management
│
├── 🏠 Presentation Layer (Pages)
│   ├── home_page.dart                # ⭐ Main navigation hub
│   │   ├── Chats Tab
│   │   ├── Contacts Tab
│   │   └── Call History Tab
│   │
│   ├── chat_page.dart                # ⭐ Real-time chat interface
│   │   ├── Message list
│   │   ├── Message composer
│   │   └── Media sharing
│   │
│   ├── call_page.dart                # ⭐ Voice/Video call screen
│   ├── call_history_screen.dart      # Call logs display
│   ├── profile.dart                  # User profile management
│   └── Friends_page.dart             # Contacts list
│
├── 📞 Call Management Layer
│   ├── call_page.dart                # Active call UI
│   ├── call_manager.dart             # ⭐ Call state management
│   ├── call_signal.dart              # ⭐ WebRTC signaling
│   └── call_history_screen.dart      # Call history
│
├── 📦 Data Models Layer
│   ├── call_log.dart                 # Call data structure
│   ├── user_profile.dart             # User profile model
│   ├── user_preferences.dart         # Settings model
│   └── storage_info.dart             # Storage metadata
│
├── 🔧 Business Logic Layer (Services)
│   ├── socket_service.dart           # ⭐ WebSocket connection
│   ├── api.dart                      # ⭐ REST API client
│   ├── call_log_service.dart         # Call history persistence
│   ├── theme_service.dart            # Theme management
│   ├── file_service.dart             # ⭐ File upload/download
│   ├── voice_message_service.dart    # Voice message handling
│   └── notifications.dart            # Push notifications
│
├── 🎨 UI Components Layer (Widgets)
│   ├── avatar_with_status.dart       # User avatar + online status
│   ├── call_activity_message.dart    # Call history in chat
│   ├── call_log_item.dart            # Call list item
│   ├── flexible_app_bar.dart         # Custom app bar
│   ├── flexible_chat_list.dart       # Message list view
│   ├── flexible_composer.dart        # Message input field
│   ├── reply_bubble.dart             # Message reply UI
│   └── voice_recording_ui.dart       # Voice recorder
│
├── ⚙️ Configuration Layer
│   ├── config/
│   │   └── app_config.dart           # App settings & constants
│   └── nav.dart                      # Navigation utilities
│
└── 🛠️ Utilities Layer
    ├── connection_helper.dart        # Network utilities
    ├── flexible_message_builder.dart # Message builder
    └── responsive.dart               # Responsive design
```

---

## 🖥️ Backend Structure (Node.js/Express)

### **Server Architecture**

```
backend/
│
├── src/
│   ├── index.js                      # ⭐ Main server entry
│   │   ├── Express setup
│   │   ├── Socket.io setup
│   │   ├── Middleware
│   │   └── Route handlers
│   │
│   ├── auth.js                       # ⭐ Authentication routes
│   │   ├── POST /auth/register
│   │   ├── POST /auth/login
│   │   ├── POST /auth/verify-otp
│   │   └── GET  /auth/me
│   │
│   └── models/                       # Database models
│       ├── User.js                   # User schema
│       ├── Message.js                # Message schema
│       └── Conversation.js           # Conversation schema
│
└── uploads/                          # File storage
    ├── images/
    ├── videos/
    └── audio/
```

---

## 🔄 Data Flow Architecture

### **Real-time Communication Flow**

```
┌──────────────────────────────────────────────────────────────┐
│                    FRONTEND (Flutter App)                     │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌─────────────┐         ┌──────────────┐                   │
│  │   UI Layer  │────────▶│ Service Layer│                   │
│  │             │         │              │                   │
│  │ • Pages     │         │ • Socket     │                   │
│  │ • Widgets   │         │ • API        │                   │
│  └─────────────┘         │ • Storage    │                   │
│         │                └──────┬───────┘                   │
│         │                       │                            │
│         └───────────────────────┼───────────────────────────┤
│                                 │                            │
│                    ┌────────────▼────────────┐              │
│                    │   SocketService         │              │
│                    │   (WebSocket Client)    │              │
│                    └────────────┬────────────┘              │
└─────────────────────────────────┼────────────────────────────┘
                                  │
                    ┌─────────────▼─────────────┐
                    │   BACKEND SERVER          │
                    │   (Node.js + Socket.io)   │
                    │                           │
                    │  • REST API Endpoints     │
                    │  • WebSocket Events       │
                    │  • File Upload Handler    │
                    │  • JWT Authentication     │
                    └───────────────────────────┘
```

---

## 🎯 Key Features & Components

### **1. Real-time Messaging System** ⭐
```
User A                    Server                    User B
  │                         │                         │
  │─── Send Message ────────▶│                         │
  │                         │─── Broadcast ──────────▶│
  │                         │                         │
  │◀── Delivery Status ──────│                         │
  │                         │◀── Read Receipt ────────│
  │                         │                         │
  │◀── Read Confirmation ────│                         │
```

**Components:**
- `socket_service.dart` - WebSocket connection manager
- `chat_page.dart` - Message UI
- Backend Socket.io handlers

### **2. Voice/Video Call System** ⭐
```
User A                    Server                    User B
  │                         │                         │
  │─── Call Request ────────▶│                         │
  │                         │─── Incoming Call ───────▶│
  │                         │                         │
  │◀── WebRTC Offer ─────────│                         │
  │                         │◀── WebRTC Answer ───────│
  │                         │                         │
  │◀── P2P Connection ──────┼────────────────────────▶│
```

**Components:**
- `call_manager.dart` - Call state management
- `call_signal.dart` - WebRTC signaling
- `call_page.dart` - Call UI
- Backend call signaling handlers

### **3. File Sharing System** ⭐
```
Client                          Server
  │                               │
  │─── Upload Request ───────────▶│
  │                               │
  │◀── Upload URL ────────────────│
  │                               │
  │─── Upload File ──────────────▶│
  │                               │
  │◀── File URL ──────────────────│
```

**Components:**
- `file_service.dart` - File upload/download
- Backend file upload handler
- `uploads/` directory

---

## 📊 Component Interaction Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    APPLICATION FLOW                           │
└─────────────────────────────────────────────────────────────┘

main.dart
    │
    ▼
splash_gate.dart
    │
    ├─── [Not Authenticated] ──▶ login_page.dart
    │                                │
    │                                ▼
    │                            auth_store.dart ◀───┐
    │                                │              │
    │                                └──────────────┘
    │
    └─── [Authenticated] ──▶ home_page.dart
                                │
                ┌───────────────┼───────────────┐
                │               │               │
                ▼               ▼               ▼
        chat_page.dart    call_page.dart   profile.dart
                │               │               │
                │               │               │
        ┌───────┼───────┐       │       ┌───────┼───────┐
        │       │       │       │       │       │       │
        ▼       ▼       ▼       ▼       ▼       ▼       ▼
    Socket  File   Voice   Call   Call   Theme  User
    Service Service Service Manager Signal Service Profile
        │       │       │       │       │       │       │
        └───────┴───────┴───────┴───────┴───────┴───────┘
                            │
                            ▼
                    Backend Server
                    (REST + WebSocket)
```

---

## 🔌 API Endpoints Overview

### **Authentication APIs**
```
POST   /auth/register          - User registration
POST   /auth/login             - User login
POST   /auth/verify-otp        - OTP verification
GET    /auth/me                - Get current user
```

### **Messaging APIs**
```
GET    /messages               - Get message history
POST   /messages               - Send new message
GET    /conversations           - Get conversations list
POST   /conversations           - Create conversation
```

### **WebSocket Events**
```
Client → Server:
  • message              - Send message
  • typing               - Typing indicator
  • presence             - Online status

Server → Client:
  • message              - Receive message
  • message:delivered    - Delivery confirmation
  • message:read         - Read receipt
  • typing               - Typing indicator
  • presence             - User status update
  • call:incoming        - Incoming call
```

---

## 💾 Data Storage Architecture

### **Frontend (Local Storage)**
```
SharedPreferences
├── auth_token           - JWT token
├── user_id              - Current user ID
├── user_profile         - User profile data
├── call_logs            - Call history
├── theme_preferences    - Theme settings
└── app_settings         - App configuration
```

### **Backend (Database)**
```
MongoDB Collections
├── users                - User accounts
├── messages             - Chat messages
├── conversations        - Chat conversations
└── call_logs            - Call history
```

---

## 🎨 UI Component Hierarchy

```
MaterialApp
└── SplashGate
    └── HomePage
        ├── TabBar (Chats/Contacts/Calls)
        │
        ├── ChatsTab
        │   └── ChatList
        │       └── ChatItem
        │
        ├── ContactsTab
        │   └── ContactList
        │       └── ContactItem
        │
        └── CallHistoryTab
            └── CallLogList
                └── CallLogItem
```

---

## 🔑 Key Technologies

### **Frontend**
- **Flutter** - Cross-platform framework
- **Dart** - Programming language
- **WebSocket** - Real-time communication
- **WebRTC** - Voice/Video calls
- **SharedPreferences** - Local storage

### **Backend**
- **Node.js** - Runtime environment
- **Express.js** - Web framework
- **Socket.io** - WebSocket library
- **MongoDB** - Database
- **JWT** - Authentication
- **Multer** - File upload handling

---

## 📈 Scalability Considerations

### **Current Architecture**
- Single server instance
- Direct WebSocket connections
- File storage on server

### **Future Enhancements**
- Load balancing for multiple servers
- Redis for session management
- CDN for file storage
- Message queue for async processing

---

## 🎯 Summary

**This messaging app follows a modern client-server architecture with:**

1. **Frontend**: Flutter-based mobile app with real-time capabilities
2. **Backend**: Node.js server with REST API and WebSocket support
3. **Communication**: WebSocket for real-time, HTTP for standard requests
4. **Features**: Messaging, Voice/Video calls, File sharing, User management
5. **Storage**: Local storage (client) + Database (server)

**Key Strengths:**
- ✅ Real-time bidirectional communication
- ✅ Modular and maintainable code structure
- ✅ Separation of concerns (UI, Business Logic, Data)
- ✅ Scalable architecture design
