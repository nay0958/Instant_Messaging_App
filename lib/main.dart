import 'package:flutter/material.dart';
import 'splash_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,

      // SplashGate ကနေ login/requests တစ်ခုခုဆီ auto-route
      home: const SplashGate(),

      // ⬇️ named routes table
      // routes: {
      //   '/login': (_) => const LoginPage(),
      //   '/register': (_) => const RegisterPage(),
      //   // '/requests': (_) => const RequestsPage(),
      // },
    );
  }
}

// import 'package:flutter/material.dart';
// import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// final FlutterLocalNotificationsPlugin _notifications =
//     FlutterLocalNotificationsPlugin();

// Future<void> _initNotifications() async {
//   // 1) Platform init (Android)
//   const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
//   const initSettings = InitializationSettings(android: androidInit);
//   await _notifications.initialize(initSettings);

//   // 2) Android-specific APIs
//   final android = _notifications
//       .resolvePlatformSpecificImplementation<
//         AndroidFlutterLocalNotificationsPlugin
//       >();

//   // 3) Android 13+ (API 33+) runtime permission (if not granted, ask)
//   final canPost = await android?.areNotificationsEnabled();
//   if (canPost != true) {
//     await android?.requestNotificationsPermission(); // returns bool
//   }

//   // 4) Ensure a channel exists (Android 8.0+)
//   const channel = AndroidNotificationChannel(
//     'basic_channel', // MUST match the channel id below
//     'Basic Notifications',
//     description: 'Default channel for basic notifications',
//     importance: Importance.high,
//   );
//   await android?.createNotificationChannel(channel);
// }

// Future<void> _showBasicNotification() async {
//   const androidDetails = AndroidNotificationDetails(
//     'basic_channel', // must be same as channel id created above
//     'Basic Notifications',
//     channelDescription: 'Default channel for basic notifications',
//     importance: Importance.high,
//     priority: Priority.high,
//   );
//   const details = NotificationDetails(android: androidDetails);

//   await _notifications.show(
//     0, // notification id
//     'မင်္ဂလာပါ 👋',
//     'This is a local notification!',
//     details,
//     payload: 'from_button',
//   );
// }

// void main() async {
//   WidgetsFlutterBinding.ensureInitialized();
//   await _initNotifications();
//   runApp(const MyApp());
// }

// class MyApp extends StatelessWidget {
//   const MyApp({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return const MaterialApp(
//       debugShowCheckedModeBanner: false,
//       home: HomePage(),
//     );
//   }
// }

// class HomePage extends StatelessWidget {
//   const HomePage({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(title: const Text('Local Notification (Android)')),
//       body: Center(
//         child: ElevatedButton(
//           onPressed: _showBasicNotification,
//           child: const Text('Show Notification'),
//         ),
//       ),
//     );
//   }
// }
