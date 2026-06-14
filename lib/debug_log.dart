// Lightweight in-app log: append messages from anywhere, view them on a screen,
// copy to clipboard. Useful on release/Play builds where there's no console.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DebugLog {
  static final ValueNotifier<List<String>> lines =
      ValueNotifier<List<String>>(<String>[]);

  static void add(String msg) {
    final now = DateTime.now().toIso8601String();
    final ts = now.length >= 23 ? now.substring(11, 23) : now; // HH:mm:ss.SSS
    final next = List<String>.from(lines.value)..add('[$ts] $msg');
    if (next.length > 800) next.removeRange(0, next.length - 800);
    lines.value = next;
    debugPrint('LOG $msg');
  }

  static void clear() => lines.value = <String>[];
  static String asText() => lines.value.join('\n');
}

/// Short alias used throughout the app.
void logD(String msg) => DebugLog.add(msg);

class DebugLogScreen extends StatelessWidget {
  const DebugLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('로그'),
        actions: [
          IconButton(
            tooltip: '복사',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: DebugLog.asText()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('로그를 클립보드에 복사했습니다.')),
                );
              }
            },
          ),
          IconButton(
            tooltip: '지우기',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => DebugLog.clear(),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<String>>(
        valueListenable: DebugLog.lines,
        builder: (_, lines, _) {
          if (lines.isEmpty) {
            return const Center(
              child: Text('로그 없음', style: TextStyle(color: Color(0xFF9AA3B2))),
            );
          }
          return Scrollbar(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: lines.length,
              itemBuilder: (_, i) => SelectableText(
                lines[i],
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12, height: 1.4),
              ),
            ),
          );
        },
      ),
    );
  }
}
