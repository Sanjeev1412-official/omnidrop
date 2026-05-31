import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// Neo-Brutalist Colors
class _C {
  static const Color surface = Color(0xFFEDE8DF);
  static const Color ink = Color(0xFF0A0A0A);
  static const Color onlineDot = Color(0xFF2ECC71);
}

class ToastUtils {
  static void showCustomToast(BuildContext context, String message, {IconData icon = LucideIcons.check}) {
    // If widget is not mounted, ScaffoldMessenger won't work perfectly, but
    // we assume the caller passes a valid context.
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 24, left: 16, right: 16),
        duration: const Duration(seconds: 4),
        content: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _C.surface,
            border: Border.all(color: _C.ink, width: 2),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: _C.ink,
                offset: Offset(4, 4),
                blurRadius: 0,
              )
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: _C.onlineDot,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: _C.ink, size: 16),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: GoogleFonts.montserrat(
                    color: _C.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    height: 1.3,
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
