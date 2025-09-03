// import 'dart:convert';
// import 'package:flutter/material.dart';
// import 'package:http/http.dart' as http;

// import 'api.dart' hide apiBase;
// import 'auth_store.dart';
// import 'chats_page.dart';
// import 'register_page.dart'; // remove if unused

// class LoginPage extends StatefulWidget {
//   const LoginPage({super.key});
//   @override
//   State<LoginPage> createState() => _LoginPageState();
// }

// class _LoginPageState extends State<LoginPage> {
//   final email = TextEditingController();
//   final pass = TextEditingController();
//   bool loading = false;
//   bool obscure = true;

//   Future<void> _login() async {
//     if (loading) return;
//     setState(() => loading = true);

//     try {
//       final res = await http.post(
//         Uri.parse('$apiBase/auth/login'),
//         headers: {'Content-Type': 'application/json'},
//         body: jsonEncode({'email': email.text.trim(), 'password': pass.text}),
//       );

//       if (res.statusCode == 200) {
//         final p = jsonDecode(res.body);
//         await AuthStore.save(p['token'], Map<String, dynamic>.from(p['user']));
//         if (!mounted) return;
//         Navigator.pushReplacement(
//           context,
//           MaterialPageRoute(builder: (_) => const ChatsPage()),
//         );
//       } else if (res.statusCode == 401) {
//         _toast('Invalid email or password');
//       } else {
//         _toast('Login failed (${res.statusCode})');
//       }
//     } catch (e) {
//       _toast('Network error: $e');
//     } finally {
//       if (mounted) setState(() => loading = false);
//     }
//   }

//   void _toast(String m) =>
//       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(title: const Text('Login')),
//       body: SafeArea(
//         child: Padding(
//           padding: const EdgeInsets.all(16),
//           child: Column(
//             children: [
//               TextField(
//                 controller: email,
//                 keyboardType: TextInputType.emailAddress,
//                 decoration: const InputDecoration(labelText: 'Email'),
//               ),
//               const SizedBox(height: 12),
//               TextField(
//                 controller: pass,
//                 obscureText: obscure,
//                 decoration: InputDecoration(
//                   labelText: 'Password',
//                   suffixIcon: IconButton(
//                     onPressed: () => setState(() => obscure = !obscure),
//                     icon: Icon(
//                       obscure ? Icons.visibility : Icons.visibility_off,
//                     ),
//                   ),
//                 ),
//                 onSubmitted: (_) => _login(),
//               ),
//               const SizedBox(height: 20),
//               SizedBox(
//                 width: double.infinity,
//                 child: ElevatedButton.icon(
//                   onPressed: loading ? null : _login,
//                   icon: loading
//                       ? const SizedBox(
//                           width: 18,
//                           height: 18,
//                           child: CircularProgressIndicator(strokeWidth: 2),
//                         )
//                       : const Icon(Icons.login),
//                   label: const Text('Sign in'),
//                 ),
//               ),
//               const SizedBox(height: 8),
//               TextButton(
//                 onPressed: () {
//                   Navigator.push(
//                     context,
//                     MaterialPageRoute(builder: (_) => const RegisterPage()),
//                   );
//                 },
//                 child: const Text('Create an account'),
//               ),
//             ],
//           ),
//         ),
//       ),
//     );
//   }
// }
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api.dart'; // apiBase
import 'auth_store.dart'; // save(), clear()
import 'home_page.dart';
import 'register_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final pass = TextEditingController();
  bool loading = false;
  bool obscure = true;

  @override
  void dispose() {
    email.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (loading) return;
    setState(() => loading = true);

    try {
      final res = await http.post(
        Uri.parse('$apiBase/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email.text.trim(), 'password': pass.text}),
      );

      if (res.statusCode == 200) {
        final p = jsonDecode(res.body) as Map<String, dynamic>;
        final token = p['token'];
        final user = Map<String, dynamic>.from(p['user'] ?? {});
        if (token == null || user.isEmpty)
          throw Exception('Malformed response');
        await AuthStore.save(token, user);

        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomePage()),
        );
      } else if (res.statusCode == 401) {
        _toast('Invalid email or password');
      } else {
        _toast('Login failed (${res.statusCode})');
      }
    } catch (e) {
      _toast('Network error: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SizedBox(height: 12),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'you@example.com',
                prefixIcon: Icon(Icons.email),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pass,
              obscureText: obscure,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => obscure = !obscure),
                  icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                ),
              ),
              onSubmitted: (_) => _login(),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: loading ? null : _login,
                icon: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login),
                label: const Text('Sign in'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("Don't have an account? "),
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const RegisterPage()),
                    );
                  },
                  child: const Text('Create one'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
