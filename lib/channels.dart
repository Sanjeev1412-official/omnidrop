import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:typed_data';
import 'package:omnidrop/core/p2p_manager.dart';

// ─── Design Tokens (Cream × Black editorial palette) ─────────────────────────
class _C {
  static const bg = Color(0xFFF5F0E8);
  static const surface = Color(0xFFEDE8DF);
  static const ink = Color(0xFF0A0A0A);
  static const border = Color(0xFFD4CEC4);
  static const borderDk = Color(0xFFB8B0A4);
  static const grey60 = Color(0xFF8A8278);
  static const grey30 = Color(0xFFB8B2A8);
  static const white = Color(0xFFFFFFFF);
  static const exitdelete = Color.fromARGB(255, 255, 50, 50);
}

class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({super.key});

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  List<Map<String, dynamic>> _pairedDevices = [];
  bool _isLoading = true;
  StreamSubscription<P2PMessageEvent>? _p2pSubscription;

  @override
  void initState() {
    super.initState();
    _loadPairedDevices();
    _p2pSubscription = P2PManager().eventStream.listen((event) {
      if (event.isProfileUpdate || event.isConnectionStatusUpdate) {
        if (mounted) _loadPairedDevices();
      }
    });
  }

  @override
  void dispose() {
    _p2pSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadPairedDevices() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final localPaired = prefs.getStringList('local_paired_devices') ?? [];
      final registryStr = prefs.getString('paired_devices_registry') ?? '{}';
      final registry = jsonDecode(registryStr) as Map<String, dynamic>;
      final namesStr = prefs.getString('paired_devices_names') ?? '{}';
      final namesMap = jsonDecode(namesStr) as Map<String, dynamic>;
      final modelsStr = prefs.getString('paired_devices_models') ?? '{}';
      final modelsMap = jsonDecode(modelsStr) as Map<String, dynamic>;

      setState(() {
        _pairedDevices = localPaired
            .map(
              (peer) => {
                'username': peer,
                'display_name': namesMap[peer] ?? peer,
                'profile_image': registry[peer] as String?,
                'device_model': modelsMap[peer] as String?,
              },
            )
            .toList();
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading devices: $e');
      setState(() => _isLoading = false);
    }
  }

  Widget _buildAvatar(String? base64Str, String fallbackName) {
    if (base64Str != null && base64Str.isNotEmpty) {
      try {
        final Uint8List bytes = base64Decode(base64Str);
        return ClipOval(
          child: Image.memory(
            bytes,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        );
      } catch (_) {}
    }
    
    // Fallback initials
    final initial = fallbackName.isNotEmpty ? fallbackName[0].toUpperCase() : '?';
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: _C.surface,
        shape: BoxShape.circle,
        border: Border.all(color: _C.border, width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w900,
          color: _C.ink,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: _C.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _C.border),
                      ),
                      child: const Icon(LucideIcons.arrowLeft, size: 20, color: _C.ink),
                    ),
                  ),
                  const SizedBox(width: 24),
                  const Text(
                    'Device Details.',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      color: _C.ink,
                      letterSpacing: -1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: _C.ink))
                  : _pairedDevices.isEmpty
                      ? _buildEmptyState()
                      : _buildListView(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.radio, size: 64, color: _C.borderDk),
          const SizedBox(height: 16),
          const Text(
            'No Channels',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: _C.ink,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'You have not paired with any devices yet.',
            style: TextStyle(color: _C.grey60, fontSize: 16),
          ),
        ],
      ),
    );
  }

  void _showDeviceDetails(BuildContext context, String displayName, Map<String, dynamic> details) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
        decoration: const BoxDecoration(
          color: _C.bg,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(40),
            topRight: Radius.circular(40),
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: _C.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(
                    details['type'] == 'Desktop' ? LucideIcons.monitor : LucideIcons.smartphone,
                    size: 28,
                    color: _C.ink,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      '$displayName\'s Device',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: _C.ink,
                        letterSpacing: -1,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              ...details.entries.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(
                        '${e.key.toUpperCase()}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          color: _C.grey60,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${e.value}',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: _C.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              )),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _C.ink,
                    foregroundColor: _C.bg,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('Close', style: const TextStyle(fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildListView() {
    return ListView.separated(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      itemCount: _pairedDevices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 20),
      itemBuilder: (context, index) {
        final device = _pairedDevices[index];
        final username = device['username'] as String;
        final displayName = device['display_name'] as String;
        final profileImage = device['profile_image'] as String?;
        final rawDeviceModel = device['device_model'] as String?;

        String? displayModelName = rawDeviceModel;
        Map<String, dynamic>? parsedDetails;
        String deviceType = 'Mobile';
        
        if (rawDeviceModel != null && rawDeviceModel.startsWith('{')) {
          try {
            parsedDetails = jsonDecode(rawDeviceModel);
            displayModelName = parsedDetails?['name'] as String?;
            deviceType = parsedDetails?['type'] as String? ?? 'Mobile';
          } catch (_) {}
        } else {
          deviceType = (rawDeviceModel?.toLowerCase().contains('windows') == true || rawDeviceModel?.toLowerCase().contains('mac') == true) 
              ? 'Desktop' 
              : 'Mobile';
        }

        return GestureDetector(
          onTap: parsedDetails != null ? () => _showDeviceDetails(context, displayName, parsedDetails!) : null,
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _C.surface,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: _C.border, width: 1),
              boxShadow: [
                BoxShadow(
                  color: _C.ink.withOpacity(0.03),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: _C.ink, width: 1.5),
                  ),
                  child: _buildAvatar(profileImage, displayName),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: _C.ink,
                          letterSpacing: -0.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '@$username',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _C.grey60,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (displayModelName != null && displayModelName.isNotEmpty && displayModelName != 'Unknown Device') ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: _C.bg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _C.border),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                deviceType == 'Desktop' ? LucideIcons.monitor : LucideIcons.smartphone, 
                                size: 12, 
                                color: _C.ink,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  displayModelName,
                                  style: const TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w900,
                                    color: _C.ink,
                                    letterSpacing: 0.5,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (parsedDetails != null)
                  Container(
                    margin: const EdgeInsets.only(left: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _C.bg,
                      shape: BoxShape.circle,
                      border: Border.all(color: _C.border),
                    ),
                    child: const Icon(LucideIcons.chevronRight, size: 18, color: _C.ink),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
