import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'supa.dart';

// Shown when there is no (non-anonymous) session. Google login is required so
// credits attach to the account.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;

  Future<void> _login() async {
    setState(() => _busy = true);
    try {
      await signInWithGoogle();
      // 성공하면 AuthGate가 onAuthStateChange로 ChatScreen으로 전환.
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled && mounted) {
        _snack('로그인 실패: ${e.code.name}');
      }
    } catch (e) {
      if (mounted) _snack('로그인 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), backgroundColor: Colors.red[900]));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0F14),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('✦',
                  style: TextStyle(fontSize: 48, color: Color(0xFF6C8CFF))),
              const SizedBox(height: 12),
              const Text('Grok Chat',
                  style:
                      TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('계속하려면 Google 계정으로 로그인하세요.',
                  style: TextStyle(color: Color(0xFF9AA3B2))),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _login,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.login),
                  label: Text(_busy ? '로그인 중…' : 'Google로 로그인'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF6C8CFF),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('크레딧은 로그인한 계정에 귀속됩니다.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF5A6373))),
            ],
          ),
        ),
      ),
    );
  }
}
