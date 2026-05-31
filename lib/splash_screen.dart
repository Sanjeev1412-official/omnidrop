import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class SplashScreen extends StatefulWidget {
  final Widget nextScreen;
  
  const SplashScreen({super.key, required this.nextScreen});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _navigateToNext() {
    if (!_navigated && mounted) {
      _navigated = true;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) => widget.nextScreen,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 800),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      //gradient bg colours corner
      backgroundColor: Color(0xFFF5F0E8),
      body: Center(
        child: Lottie.asset(
          'assets/splash.json',
          controller: _controller,
          height: 230,
          onLoaded: (composition) {
            _controller
              ..duration = composition.duration
              ..forward().whenComplete(() {
                _navigateToNext();
              });
          },
          errorBuilder: (context, error, stackTrace) {
            // Fallback in case the json is missing or invalid
            Future.delayed(const Duration(seconds: 2), () {
              _navigateToNext();
            });
            return const CircularProgressIndicator(color: Colors.blue);
          },
        ),
      ),
    );
  }
}
