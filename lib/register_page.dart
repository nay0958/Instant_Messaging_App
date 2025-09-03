// import 'dart:convert';
// import 'package:flutter/material.dart';
// import 'package:http/http.dart' as http;
// import 'package:study1/chats_page.dart';
// import 'auth_store.dart';
// import 'requests_page.dart';

// const apiBase = 'http://192.168.2.249:3000'; //

// class RegisterPage extends StatefulWidget {
//   const RegisterPage({super.key});
//   @override
//   State<RegisterPage> createState() => _RegisterPageState();
// }

// class _RegisterPageState extends State<RegisterPage> {
//   final name = TextEditingController();
//   final email = TextEditingController();
//   final pass = TextEditingController();
//   bool loading = false;

//   Future<void> _register() async {
//     if (loading) return;
//     setState(() => loading = true);
//     try {
//       final r = await http.post(
//         Uri.parse('$apiBase/auth/register'),
//         headers: {'Content-Type': 'application/json'},
//         body: jsonEncode({
//           'name': name.text.trim(),
//           'email': email.text.trim(),
//           'password': pass.text,
//         }),
//       );
//       if (r.statusCode == 201) {
//         final p = jsonDecode(r.body);
//         await AuthStore.save(p['token'], p['user']);
//         if (!mounted) return;
//         Navigator.pushAndRemoveUntil(
//           context,
//           MaterialPageRoute(builder: (_) => const ChatsPage()),
//           (_) => false,
//         );
//       } else if (r.statusCode == 409) {
//         _toast('Email already in use');
//       } else {
//         _toast('Register failed (${r.statusCode})');
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
//       appBar: AppBar(title: const Text('Create account')),
//       body: Padding(
//         padding: const EdgeInsets.all(16),
//         child: Column(
//           children: [
//             TextField(
//               controller: name,
//               decoration: const InputDecoration(labelText: 'Name'),
//             ),
//             const SizedBox(height: 12),
//             TextField(
//               controller: email,
//               decoration: const InputDecoration(labelText: 'Email'),
//             ),
//             const SizedBox(height: 12),
//             TextField(
//               controller: pass,
//               obscureText: true,
//               decoration: const InputDecoration(labelText: 'Password'),
//             ),
//             const SizedBox(height: 20),
//             SizedBox(
//               width: double.infinity,
//               child: ElevatedButton(
//                 onPressed: loading ? null : _register,
//                 child: loading
//                     ? const SizedBox(
//                         width: 18,
//                         height: 18,
//                         child: CircularProgressIndicator(strokeWidth: 2),
//                       )
//                     : const Text('Sign up'),
//               ),
//             ),
//             TextButton(
//               onPressed: () => Navigator.pop(context),
//               child: const Text('Back to login'),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api.dart'; // apiBase
import 'auth_store.dart'; // save()
import 'home_page.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});
  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _form = GlobalKey<FormState>();
  final name = TextEditingController();
  final email = TextEditingController();
  final pass = TextEditingController();
  bool loading = false;
  bool obscure = true;

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (loading) return;
    setState(() => loading = true);

    try {
      final res = await http.post(
        Uri.parse('$apiBase/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name.text.trim(),
          'email': email.text.trim(),
          'password': pass.text,
        }),
      );

      if (res.statusCode == 201 || res.statusCode == 200) {
        final p = jsonDecode(res.body) as Map<String, dynamic>;
        final token = p['token'];
        final user = Map<String, dynamic>.from(p['user'] ?? {});
        if (token == null || user.isEmpty)
          throw Exception('Malformed response');
        await AuthStore.save(token, user);

        if (!mounted) return;
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const HomePage()),
          (_) => false,
        );
      } else if (res.statusCode == 409) {
        _toast('Email already taken');
      } else {
        _toast('Register failed (${res.statusCode})');
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
      appBar: AppBar(title: const Text('Create account')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Form(
              key: _form,
              child: Column(
                children: [
                  TextFormField(
                    controller: name,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      prefixIcon: Icon(Icons.person),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Enter name' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Enter email' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: pass,
                    obscureText: obscure,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => obscure = !obscure),
                        icon: Icon(
                          obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                      ),
                    ),
                    validator: (v) =>
                        (v == null || v.length < 6) ? 'Min 6 chars' : null,
                    onFieldSubmitted: (_) => _register(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: loading ? null : _register,
                icon: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: const Text('Create account'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
