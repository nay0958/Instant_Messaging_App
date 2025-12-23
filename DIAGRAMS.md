# Messaging App - Visual Diagrams

## System Architecture Diagram

```mermaid
graph LR
    A[Flutter Client] <-->|HTTP/REST| B[Node.js Server]
    A <-->|WebSocket| B
    B --> C[(MongoDB)]
    B --> D[File Storage]
```

## Application Flow Diagram

```mermaid
graph TD
    A[main.dart] --> B[splash_gate.dart]
    B -->|Not Auth| C[login_page.dart]
    B -->|Authenticated| D[home_page.dart]
    C --> E[auth_store.dart]
    D --> F[chat_page.dart]
    D --> G[call_page.dart]
    D --> H[profile.dart]
    F --> I[SocketService]
    F --> J[FileService]
    G --> K[CallManager]
    I --> L[Backend Server]
    J --> L
    K --> L
```

## Frontend Layer Architecture

```mermaid
graph TB
    subgraph "Frontend Layers"
        A[Entry Point<br/>main.dart, splash_gate.dart]
        B[Authentication<br/>login, register, auth_store]
        C[Presentation<br/>home, chat, call, profile]
        D[Services<br/>socket, api, file, theme]
        E[Models<br/>call_log, user_profile]
        F[Widgets<br/>avatar, bubble, composer]
    end
    
    A --> B
    B --> C
    C --> D
    D --> E
    C --> F
    D --> G[Backend Server]
```

## Real-time Messaging Flow

```mermaid
sequenceDiagram
    participant U1 as User A
    participant S as Server
    participant U2 as User B
    
    U1->>S: Send Message
    S->>U2: Broadcast Message
    S->>U1: Delivery Status
    U2->>S: Read Receipt
    S->>U1: Read Confirmation
```

## Call System Flow

```mermaid
sequenceDiagram
    participant U1 as User A
    participant S as Server
    participant U2 as User B
    
    U1->>S: Call Request
    S->>U2: Incoming Call
    U2->>S: Accept Call
    S->>U1: WebRTC Offer
    S->>U2: WebRTC Answer
    U1<->>U2: P2P Connection
```

## Component Structure

```mermaid
graph LR
    subgraph "Frontend"
        A[Pages]
        B[Services]
        C[Models]
        D[Widgets]
    end
    
    subgraph "Backend"
        E[API Routes]
        F[Socket.io]
        G[Database]
    end
    
    A --> B
    B --> C
    A --> D
    B --> E
    B --> F
    E --> G
    F --> G
```

## File Structure Tree

```mermaid
graph TD
    A[lib/] --> B[main.dart]
    A --> C[Authentication/]
    A --> D[Pages/]
    A --> E[Services/]
    A --> F[Models/]
    A --> G[Widgets/]
    
    C --> C1[login_page.dart]
    C --> C2[auth_store.dart]
    
    D --> D1[home_page.dart]
    D --> D2[chat_page.dart]
    D --> D3[call_page.dart]
    
    E --> E1[socket_service.dart]
    E --> E2[api.dart]
    E --> E3[file_service.dart]
    
    F --> F1[call_log.dart]
    F --> F2[user_profile.dart]
    
    G --> G1[avatar_with_status.dart]
    G --> G2[flexible_composer.dart]
```
