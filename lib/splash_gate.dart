// import 'dart:convert';
// import 'package:flutter/material.dart';
// import 'package:http/http.dart' as http;

// import 'api.dart';
// import 'auth_store.dart';
// import 'login_page.dart';
// import 'chats_page.dart';

// class SplashGate extends StatefulWidget {
//   const SplashGate({super.key});
//   @override
//   State<SplashGate> createState() => _SplashGateState();
// }

// class _SplashGateState extends State<SplashGate> {
//   @override
//   void initState() {
//     super.initState();
//     _decide();
//   }

//   Future<void> _decide() async {
//     try {
//       final t = await AuthStore.token();
//       if (t == null) {
//         _go(const LoginPage());
//         return;
//       }

//       final r = await http.get(
//         Uri.parse('$apiBase/auth/me'),
//         headers: {'Authorization': 'Bearer $t'},
//       );

//       if (r.statusCode == 200) {
//         _go(const ChatsPage());
//       } else {
//         await AuthStore.clear();
//         _go(const LoginPage());
//       }
//     } catch (_) {
//       await AuthStore.clear();
//       _go(const LoginPage());
//     }
//   }

//   void _go(Widget w) {
//     if (!mounted) return;
//     Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => w));
//   }

//   @override
//   Widget build(BuildContext context) =>
//       const Scaffold(body: Center(child: CircularProgressIndicator()));
// }
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api.dart'; // apiBase
import 'auth_store.dart'; // getToken(), clear()
import 'login_page.dart';
import 'home_page.dart'; // inbox (Chats/Home)

class SplashGate extends StatefulWidget {
  const SplashGate({super.key});
  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    try {
      final t = await AuthStore.getToken();
      if (t == null) return _go(const LoginPage());

      final r = await http.get(
        Uri.parse('$apiBase/auth/me'),
        headers: {'Authorization': 'Bearer $t'},
      );

      if (r.statusCode == 200) {
        _go(const HomePage());
      } else {
        await AuthStore.clear();
        _go(const LoginPage());
      }
    } catch (_) {
      await AuthStore.clear();
      _go(const LoginPage());
    }
  }

  void _go(Widget w) {
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => w));
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
