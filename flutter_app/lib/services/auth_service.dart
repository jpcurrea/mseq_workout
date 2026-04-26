import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

class AuthService {
  static const String _tokenKey = 'auth_token';
  static const String _rememberMeKey = 'remember_me';
  static const _storage = FlutterSecureStorage();

  // Must match FRONTEND_URL in backend .env
  static const String backendUrl = 'https://workout-backend-h6pd.onrender.com'; // production
  // static const String backendUrl = 'https://workout-backend-h6pd.onrender.com'; // local dev

  static Future<String?> getToken() async {
    return _storage.read(key: _tokenKey);
  }

  static Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  static Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
  }

  static Future<void> setRememberMe(bool value) async {
    await _storage.write(key: _rememberMeKey, value: value.toString());
  }

  static Future<bool> getRememberMe() async {
    final v = await _storage.read(key: _rememberMeKey);
    return v == 'true';
  }

  /// Decodes a JWT and returns its payload map.
  static Map<String, dynamic>? _decodeJwt(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(payload));
      return json.decode(decoded) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Returns true if the stored token is missing or expired.
  static Future<bool> isTokenExpired() async {
    final token = await getToken();
    if (token == null || token.isEmpty) return true;
    final payload = _decodeJwt(token);
    if (payload == null) return true;
    final exp = payload['exp'] as int?;
    if (exp == null) return true;
    return DateTime.now()
        .isAfter(DateTime.fromMillisecondsSinceEpoch(exp * 1000));
  }

  static Future<bool> isLoggedIn() async {
    return !(await isTokenExpired());
  }

  static Future<void> logout() async {
    await clearToken();
  }

  /// Opens the Google OAuth login URL.
  /// On web, navigates the current tab (full-page redirect).
  /// On desktop/mobile, opens in the default browser.
  static Future<void> signInWithGoogle() async {
    final uri = Uri.parse('$backendUrl/auth/google/login');
    if (kIsWeb) {
      await launchUrl(uri, webOnlyWindowName: '_self');
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Call this on app startup to capture a token passed back via URL query param.
  /// Returns the token if found in the URL, null otherwise.
  static String? extractTokenFromUrl() {
    if (!kIsWeb) return null;
    final uri = Uri.base;
    return uri.queryParameters['token'];
  }
}
