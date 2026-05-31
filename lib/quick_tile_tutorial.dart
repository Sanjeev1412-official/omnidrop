import 'package:google_fonts/google_fonts.dart';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class _C {
  static const bg = Color(0xFFF5F0E8);
  static const surface = Color(0xFFEDE8DF);
  static const ink = Color(0xFF0A0A0A);
  static const grey60 = Color(0xFF8A8278);
  static const border = Color(0xFFD4CEC4);
}

class QuickTileTutorialDialog extends StatelessWidget {
  const QuickTileTutorialDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32), // More margin on mobile
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 360),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _C.bg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: _C.ink, width: 2),
            boxShadow: const [
              BoxShadow(
                color: _C.ink,
                offset: Offset(4, 4),
                blurRadius: 0,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Lottie Animation Canvas
              Container(
                constraints: const BoxConstraints(maxHeight: 180), // Prevents massive videos from blowing up the dialog
                decoration: BoxDecoration(
                  color: _C.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _C.ink, width: 2),
                ),
                clipBehavior: Clip.hardEdge,
                child: Lottie.asset(
                  'assets/quicktile.json',
                  fit: BoxFit.contain, // Keep contain so it respects the 180 height without cropping
                  frameBuilder: (context, child, composition) {
                    if (composition == null) {
                      return const Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _C.ink,
                        ),
                      );
                    }
                    return child;
                  },
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Quick Settings',
                textAlign: TextAlign.center,
                style: GoogleFonts.montserrat(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: _C.ink,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Swipe down your notification shade and edit your Quick Settings to add the OmniDrop tile. Use it to instantly turn on sharing from anywhere!',
                textAlign: TextAlign.center,
                style: GoogleFonts.montserrat(
                  fontSize: 13,
                  color: _C.grey60,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: _C.ink,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _C.ink, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'Got it!',
                    style: GoogleFonts.montserrat(
                      color: _C.bg,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
