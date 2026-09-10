import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class LoteriaVideosScreen extends StatefulWidget {
  const LoteriaVideosScreen({super.key});

  @override
  State<LoteriaVideosScreen> createState() => _LoteriaVideosScreenState();
}

class _LoteriaVideosScreenState extends State<LoteriaVideosScreen> {
  WebViewController? _controller;
  bool _isLoading = true;
  String _selectedCategory = "TODOS"; // "TODOS", "GEORGIA", "FLORIDA"
  final bool _isSupported = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  String _getDynamicUrl(String category) {
    // sp=CAI%253D ordena los vídeos estrictamente por fecha de publicación (Más recientes primero)
    if (category == "GEORGIA") {
      return 'https://www.youtube.com/results?search_query=%22Georgia+Lottery%22+Cash+3+Cash+4+results&sp=CAI%253D';
    } else if (category == "FLORIDA") {
      return 'https://www.youtube.com/results?search_query=%22Florida+Lottery%22+Pick+3+Pick+4+results&sp=CAI%253D';
    } else {
      // TODOS: Solo Georgia y Florida combinados, ordenados por más reciente
      return 'https://www.youtube.com/results?search_query=%22Florida+Lottery%22+OR+%22Georgia+Lottery%22+results+today&sp=CAI%253D';
    }
  }

  @override
  void initState() {
    super.initState();
    _initWebViewController(_getDynamicUrl(_selectedCategory));
  }

  void _initWebViewController(String url) {
    if (_isSupported) {
      setState(() => _isLoading = true);
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0x00000000))
        ..setNavigationDelegate(
          NavigationDelegate(
            onProgress: (int progress) {},
            onPageStarted: (String url) {
              if (mounted) setState(() { _isLoading = true; });
            },
            onPageFinished: (String url) {
              if (mounted) setState(() { _isLoading = false; });
            },
            onWebResourceError: (WebResourceError error) {},
            onNavigationRequest: (NavigationRequest request) {
              return NavigationDecision.navigate;
            },
          ),
        )
        ..loadRequest(Uri.parse(url));
    } else {
      _isLoading = false;
    }
  }

  void _switchCategory(String category) {
    if (_selectedCategory == category) return;
    setState(() {
      _selectedCategory = category;
    });
    final url = _getDynamicUrl(category);
    if (_controller != null) {
      setState(() => _isLoading = true);
      _controller!.loadRequest(Uri.parse(url));
    }
  }

  Future<void> _launchURL() async {
    final Uri url = Uri.parse(_getDynamicUrl(_selectedCategory));
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No se pudo abrir el navegador")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("VÍDEOS DE LOTERÍA", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            onPressed: _launchURL,
            tooltip: "Abrir en navegador",
          )
        ],
      ),
      body: Column(
        children: [
          // BARRA DE FILTROS: SOLO GEORGIA Y FLORIDA (MÁS RECIENTES ENCABEZANDO)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            color: Colors.blue.shade900,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _filterChip("MÁS RECIENTES", "TODOS"),
                _filterChip("GEORGIA", "GEORGIA"),
                _filterChip("FLORIDA", "FLORIDA"),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                if (_isSupported && _controller != null)
                  WebViewWidget(controller: _controller!)
                else
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.video_library, size: 64, color: Colors.grey),
                        const SizedBox(height: 20),
                        const Text(
                          "Vista previa no disponible en esta plataforma",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: _launchURL,
                          icon: const Icon(Icons.play_circle_fill),
                          label: const Text("VER EN YOUTUBE"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_isLoading)
                  const Center(
                    child: CircularProgressIndicator(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String category) {
    final bool isSelected = _selectedCategory == category;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          color: isSelected ? Colors.blue.shade900 : Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 11,
        ),
      ),
      selected: isSelected,
      selectedColor: Colors.amber,
      backgroundColor: Colors.white24,
      onSelected: (_) => _switchCategory(category),
    );
  }
}
