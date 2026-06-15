import 'package:flutter/material.dart';
import '../../shared/services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoading = false;
  bool _rememberMe = false;
  bool _sessionExpired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['reason'] == 'session_expired') {
      _sessionExpired = true;
    }
  }

  Future<void> _handleSignIn() async {
    setState(() => _isLoading = true);
    try {
      await AuthService.setRememberMe(_rememberMe);
      await AuthService.signInWithGoogle();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sign-in failed: $e')),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.fitness_center,
                size: 80,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                'Workout Routine',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in to access your workouts',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey,
                    ),
              ),
              if (_sessionExpired)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.orange[50],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange[200]!),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info_outline, size: 20, color: Colors.orange[800]),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            'Your session expired. Please sign in again.',
                            style: TextStyle(color: Colors.orange[900]),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 48),
              _isLoading
                  ? const CircularProgressIndicator()
                  : OutlinedButton.icon(
                      onPressed: _handleSignIn,
                      icon: Image.network(
                        'https://developers.google.com/identity/images/g-logo.png',
                        height: 20,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.login, size: 20),
                      ),
                      label: const Text('Sign in with Google'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                        textStyle: const TextStyle(fontSize: 16),
                      ),
                    ),
              const SizedBox(height: 16),
              if (!_isLoading)
                CheckboxListTile(
                  value: _rememberMe,
                  onChanged: (v) => setState(() => _rememberMe = v ?? false),
                  title: const Text('Stay signed in on this device'),
                  subtitle: const Text(
                    'Automatically re-signs you in when your session expires.',
                    style: TextStyle(fontSize: 11),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
