import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

class AuthService {
  static const String _tokenKey = 'auth_token';
  static const _storage = FlutterSecureStorage();

  // Must match FRONTEND_URL in backend .env
  static const String backendUrl = 'http://localhost:8000';

  static Future<String?> getToken() async {
    return _storage.read(key: _tokenKey);
  }

  static Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  static Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
  }

  static Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
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
