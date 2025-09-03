import 'dart:convert';
import 'package:http/http.dart' as http;
import 'auth_store.dart';

/// Emulator -> http://10.0.2.2:3000
/// Real device -> http://<PC-LAN-IP>:3000
const apiBase = 'http://192.168.2.249:3000';

Future<Map<String, String>> authHeaders() async {
  final t = await AuthStore.getToken(); // <- change if your method name differs
  return {
    'Content-Type': 'application/json',
    if (t != null) 'Authorization': 'Bearer $t',
  };
}

Future<http.Response> getJson(String path) async =>
    http.get(Uri.parse('$apiBase$path'), headers: await authHeaders());

Future<http.Response> postJson(String path, Map<String, dynamic> body) async =>
    http.post(
      Uri.parse('$apiBase$path'),
      headers: await authHeaders(),
      body: jsonEncode(body),
    );
