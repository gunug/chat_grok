// Supabase client lifecycle + anonymous auth.
// Anonymous sign-in now; Google OAuth can later upgrade the same identity via
// supabase.auth.linkIdentity(OAuthProvider.google).

import 'package:supabase_flutter/supabase_flutter.dart';

bool _inited = false;
bool get supabaseInited => _inited;

/// Initialise the Supabase client once (no-op if already done).
Future<void> initSupabase(String url, String anonKey) async {
  if (_inited) return;
  // Using the legacy anon (JWT) key; publishableKey is the newer format.
  // ignore: deprecated_member_use
  await Supabase.initialize(url: url, anonKey: anonKey);
  _inited = true;
}

/// Ensures a session exists (creating an anonymous one if needed) and returns
/// its access token to use as the Bearer for Edge Function calls.
Future<String?> ensureSession() async {
  final auth = Supabase.instance.client.auth;
  if (auth.currentSession == null) {
    await auth.signInAnonymously();
  }
  return auth.currentSession?.accessToken;
}

bool get isAnonymous =>
    _inited &&
    (Supabase.instance.client.auth.currentUser?.isAnonymous ?? false);
