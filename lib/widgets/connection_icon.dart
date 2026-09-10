import 'dart:async';
import 'package:flutter/material.dart';
import 'package:srecord/services/core_network.dart';

class ConnectionIcon extends StatefulWidget {
  final Color? color;
  const ConnectionIcon({super.key, this.color});

  @override
  State<ConnectionIcon> createState() => _ConnectionIconState();
}

class _ConnectionIconState extends State<ConnectionIcon> with SingleTickerProviderStateMixin {
  bool _isOnline = CoreNetwork().isConnected;
  late StreamSubscription<bool> _subscription;
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    
    if (!_isOnline) _controller.repeat(reverse: true);

    _subscription = CoreNetwork().onConnectionChanged.listen((online) {
      if (mounted) {
        setState(() {
          _isOnline = online;
          if (_isOnline) {
            _controller.stop();
          } else {
            _controller.repeat(reverse: true);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _isOnline ? const AlwaysStoppedAnimation(1.0) : Tween<double>(begin: 0.3, end: 1.0).animate(_controller),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Icon(
          _isOnline ? Icons.wifi_tethering : Icons.wifi_tethering_off,
          size: 18,
          color: _isOnline ? (widget.color ?? Colors.greenAccent) : Colors.redAccent,
        ),
      ),
    );
  }
}
