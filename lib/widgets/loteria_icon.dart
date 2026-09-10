import 'package:flutter/material.dart';

class LoteriaIcon extends StatelessWidget {
  final String loteria;
  final double size;
  final double? width;
  final double? height;
  final double borderRadius;
  final bool showBorder;

  const LoteriaIcon({
    super.key,
    required this.loteria,
    this.size = 32.0,
    this.width,
    this.height,
    this.borderRadius = 8.0,
    this.showBorder = true,
  });

  static String getLabel(String loteria) {
    final clean = loteria.trim().toUpperCase();
    if (clean.contains("GEORGIA") || clean == "GA") {
      return "GA";
    }
    if (clean.contains("FLORIDA") || clean == "FL") {
      return "FL";
    }
    return "AMBAS";
  }

  @override
  Widget build(BuildContext context) {
    final clean = loteria.trim().toUpperCase();
    final isGeorgia = clean.contains("GEORGIA") || clean == "GA";
    final isFlorida = clean.contains("FLORIDA") || clean == "FL";

    final double effectiveWidth = width ?? (size * 1.35);
    final double effectiveHeight = height ?? size;

    if (isGeorgia || isFlorida) {
      final String assetPath = isGeorgia ? 'assets/georgia.jpeg' : 'assets/florida.jpeg';
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          border: showBorder ? Border.all(color: Colors.white70, width: 1.0) : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 3,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius > 1 ? borderRadius - 1 : 0),
          child: Image.asset(
            assetPath,
            width: effectiveWidth,
            height: effectiveHeight,
            fit: BoxFit.cover,
            errorBuilder: (ctx, err, stack) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                color: isGeorgia ? Colors.orange.shade800 : Colors.blue.shade900,
                child: Text(
                  isGeorgia ? "GA" : "FL",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: size * 0.5),
                ),
              );
            },
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.purple.shade900,
        borderRadius: BorderRadius.circular(borderRadius),
        border: showBorder ? Border.all(color: Colors.white38, width: 1.0) : null,
      ),
      child: Text(
        "AMBAS",
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: size * 0.5,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class LoteriaBadge extends StatelessWidget {
  final String loteria;
  final bool isSelected;
  final VoidCallback? onTap;

  const LoteriaBadge({
    super.key,
    required this.loteria,
    this.isSelected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final clean = loteria.trim().toUpperCase();
    final isGeorgia = clean.contains("GEORGIA") || clean == "GA";
    final label = isGeorgia ? "GEORGIA" : (clean == "AMBAS" ? "AMBAS" : "FLORIDA");

    Widget content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isSelected 
            ? (isGeorgia ? Colors.orange.shade800 : Colors.blue.shade900) 
            : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected ? (isGeorgia ? Colors.deepOrange : Colors.blue.shade300) : Colors.grey.shade400,
          width: 1.2,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isSelected ? Colors.white : Colors.black87,
          fontWeight: FontWeight.w900,
          fontSize: 11,
          letterSpacing: 0.5,
        ),
      ),
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: content);
    }
    return content;
  }
}
