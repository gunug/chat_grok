// Supabase client lifecycle + Google authentication.
// Anonymous sign-in has been removed: the app now requires a real Google
// account so credits are tied to the account (not the device).

import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'debug_log.dart';

bool _inited = false;
bool get supabaseInited => _inited;

/// Initialise the Supabase client once (no-op if already done).
Future<void> initSupabase(String url, String anonKey) async {
  if (_inited) return;
  // ignore: deprecated_member_use
  await Supabase.initialize(url: url, anonKey: anonKey);
  _inited = true;
}

bool _googleInited = false;
Future<void> _ensureGoogleInit() async {
  if (_googleInited) return;
  // serverClientId = Web client ID so the ID token audience matches Supabase.
  await GoogleSignIn.instance.initialize(serverClientId: kGoogleWebClientId);
  _googleInited = true;
}

/// Current signed-in (non-anonymous) user, or null.
User? get currentUser {
  final u = Supabase.instance.client.auth.currentUser;
  if (u == null || u.isAnonymous) return null;
  return u;
}

bool get isLoggedIn => currentUser != null;

/// Access token for the current session (used as the Edge Function Bearer).
String? currentAccessToken() =>
    Supabase.instance.client.auth.currentSession?.accessToken;

/// Native Google sign-in -> exchange the ID token for a Supabase session.
/// Throws GoogleSignInException (e.g. code == canceled) if the user backs out.
Future<void> signInWithGoogle() async {
  logD('signInWithGoogle: start');
  await _ensureGoogleInit();
  logD('google init done; supportsAuthenticate='
      '${GoogleSignIn.instance.supportsAuthenticate()}');
  final account = await GoogleSignIn.instance.authenticate();
  logD('google account: ${account.email}');
  final idToken = account.authentication.idToken;
  logD('idToken: ${idToken == null ? "NULL" : "len ${idToken.length}"}');
  if (idToken == null) {
    throw 'Google ID 토큰을 받지 못했습니다.';
  }
  logD('supabase.signInWithIdToken ...');
  final res = await Supabase.instance.client.auth.signInWithIdToken(
    provider: OAuthProvider.google,
    idToken: idToken,
  );
  logD('signInWithIdToken ok: user=${res.user?.id} email=${res.user?.email} '
      'anon=${res.user?.isAnonymous}');
}

/// Sign out of both Google and Supabase.
Future<void> signOut() async {
  try {
    await _ensureGoogleInit();
    await GoogleSignIn.instance.signOut();
  } catch (_) {
    // ignore Google sign-out issues
  }
  await Supabase.instance.client.auth.signOut();
}
