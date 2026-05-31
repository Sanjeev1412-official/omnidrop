class SupabaseConfig {
  /// TODO: Insert your actual Supabase project URL here.
  /// Example: 'https://xyzcompany.supabase.co'
  static const String supabaseUrl = 'https://ytzhxueaqkbiuakfftdk.supabase.co';

  /// TODO: Insert your actual Supabase public anon key here.
  /// Example: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIs...'
  static const String supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl0emh4dWVhcWtiaXVha2ZmdGRrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk1MzQ2MDksImV4cCI6MjA5NTExMDYwOX0.xJLYC5Fe4Xgu4KTN7AevC5B9NoBjsC0yReJu31-wdfo';

  /// Helper to check if the user has replaced the default placeholders
  static bool get isSupabaseConfigured {
    return supabaseUrl.isNotEmpty &&
        supabaseAnonKey.isNotEmpty &&
        supabaseUrl != 'YOUR_SUPABASE_URL' &&
        supabaseAnonKey != 'YOUR_SUPABASE_ANON_KEY';
  }
}
