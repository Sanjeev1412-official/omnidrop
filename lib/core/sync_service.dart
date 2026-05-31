import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:omnidrop/supabase_config.dart';

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  /// Reads whether cloud backup is enabled locally
  Future<bool> isBackupEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('cloud_backup_enabled') ?? false;
  }

  /// Toggles backup setting and pushes local state to cloud immediately if enabled
  Future<void> setBackupEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('cloud_backup_enabled', enabled);
    
    final username = prefs.getString('username');
    if (username == null || !SupabaseConfig.isSupabaseConfigured) return;

    try {
      if (enabled) {
        // If they just turned it ON, immediately push the current local state up
        await pushPairedDevices();
        // Since chat history could be large and across multiple peers, 
        // we'll push all local chats that we know about.
        final localDevices = prefs.getStringList('local_paired_devices') ?? [];
        for (final peer in localDevices) {
          await pushChatHistory(peer);
        }
      }
      
      // Upsert the flag in supabase without overwriting the jsonb columns entirely
      // However, upserting replaces the row if we don't specify the other columns.
      // So we should fetch existing row first.
      final response = await Supabase.instance.client
          .from('cloud_backups')
          .select()
          .eq('username', username)
          .maybeSingle();
      
      final Map<String, dynamic> rowData = response ?? {
        'username': username,
        'paired_devices': {},
        'chat_history': {}
      };
      
      rowData['backup_enabled'] = enabled;

      await Supabase.instance.client.from('cloud_backups').upsert(rowData);
    } catch (e) {
      debugPrint('[SyncService] Error updating backup preference: $e');
    }
  }

  /// Triggered after successful login on onboarding screen
  Future<void> restoreBackup(String username) async {
    if (!SupabaseConfig.isSupabaseConfigured) return;

    try {
      final response = await Supabase.instance.client
          .from('cloud_backups')
          .select()
          .eq('username', username)
          .maybeSingle();

      if (response == null) return;

      final backupEnabled = response['backup_enabled'] as bool? ?? false;
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('cloud_backup_enabled', backupEnabled);

      if (backupEnabled) {
        // Restore paired devices
        if (response['paired_devices'] != null) {
          final pd = response['paired_devices'] as Map<String, dynamic>;
          final registry = pd['registry'] as Map<String, dynamic>? ?? {};
          final list = (pd['list'] as List<dynamic>? ?? []).cast<String>();

          await prefs.setStringList('local_paired_devices', list);
          await prefs.setString('paired_devices_registry', jsonEncode(registry));
        }

        // Restore chat history
        if (response['chat_history'] != null) {
          final ch = response['chat_history'] as Map<String, dynamic>;
          for (final entry in ch.entries) {
            final peerUsername = entry.key;
            final serializedMessages = (entry.value as List<dynamic>).cast<String>();
            await prefs.setStringList('chat_history_$peerUsername', serializedMessages);
          }
        }
        debugPrint('[SyncService] Successfully restored backup for $username');
      }
    } catch (e) {
      debugPrint('[SyncService] Error restoring backup: $e');
    }
  }

  Future<void> pushPairedDevices() async {
    if (!await isBackupEnabled() || !SupabaseConfig.isSupabaseConfigured) return;
    
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username');
    if (username == null) return;

    try {
      final list = prefs.getStringList('local_paired_devices') ?? [];
      final registryStr = prefs.getString('paired_devices_registry') ?? '{}';
      final registry = jsonDecode(registryStr);

      final payload = {
        'list': list,
        'registry': registry,
      };

      // Fetch row to avoid overwriting chats
      final response = await Supabase.instance.client
          .from('cloud_backups')
          .select()
          .eq('username', username)
          .maybeSingle();
          
      final Map<String, dynamic> rowData = response ?? {
        'username': username,
        'backup_enabled': true,
        'chat_history': {}
      };
      
      rowData['paired_devices'] = payload;

      await Supabase.instance.client.from('cloud_backups').upsert(rowData);
      debugPrint('[SyncService] Pushed paired devices to cloud');
    } catch (e) {
      debugPrint('[SyncService] Error pushing paired devices: $e');
    }
  }

  Future<void> pushChatHistory(String peerUsername) async {
    if (!await isBackupEnabled() || !SupabaseConfig.isSupabaseConfigured) return;

    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username');
    if (username == null) return;

    try {
      // First, get the existing chat_history jsonb blob
      final response = await Supabase.instance.client
          .from('cloud_backups')
          .select()
          .eq('username', username)
          .maybeSingle();

      final Map<String, dynamic> rowData = response ?? {
        'username': username,
        'backup_enabled': true,
        'paired_devices': {}
      };

      Map<String, dynamic> chatHistoryBlob = {};
      if (rowData['chat_history'] != null) {
        chatHistoryBlob = rowData['chat_history'] as Map<String, dynamic>;
      }

      // Update the specific peer's chat history
      final localHistory = prefs.getStringList('chat_history_$peerUsername') ?? [];
      chatHistoryBlob[peerUsername] = localHistory;
      
      rowData['chat_history'] = chatHistoryBlob;

      // Push back
      await Supabase.instance.client.from('cloud_backups').upsert(rowData);
      debugPrint('[SyncService] Pushed chat history for $peerUsername to cloud');
    } catch (e) {
      debugPrint('[SyncService] Error pushing chat history: $e');
    }
  }
}
