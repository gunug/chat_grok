// Public Supabase project values — safe to ship inside the client app.
// They only identify the project and allow anonymous sign-in; they are NOT
// secrets. The xAI API key is NOT here — it lives only as a Supabase secret
// and is used by the Edge Function server-side.
//
// Baking these in means the app works with zero setup: it auto-connects and
// signs in anonymously on first launch.

const String kSupabaseUrl = 'https://oerrgsanrnelhvgikgkv.supabase.co';

const String kSupabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9lcnJnc2Fucm5lbGh2Z2lrZ2t2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5ODgzOTIsImV4cCI6MjA5NjU2NDM5Mn0.LWJiSUQY_R0gkNb93f_186NatET9YlkfS0DeItjdbVY';

// Google OAuth **Web** client ID — used as serverClientId so the returned ID
// token's audience matches what Supabase's Google provider expects. This is
// public (not a secret). The client *secret* is NOT here — it lives only in the
// Supabase dashboard (Authentication > Providers > Google).
const String kGoogleWebClientId =
    '273772108097-01ltg5r6hmtlu4its1htoq9j95mj6duc.apps.googleusercontent.com';
