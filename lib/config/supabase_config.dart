import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  static const String supabaseUrl = 'https://yylffuwhmkbhurkyszgf.supabase.co';
  static const String supabaseAnonKey = 'sb_publishable_YQAw2qO7E7bSRhVJBZk6sw_oUDpVNy-';
  
  static Future<void> init() async {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );
  }

  static SupabaseClient get client => Supabase.instance.client;
}