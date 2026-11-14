import 'package:flutter/material.dart';

// e2e/run.sh rewrites this line to build the patch.
const marker = 'OPENBIRD BASE';

void main() => runApp(const SampleApp());

class SampleApp extends StatelessWidget {
  const SampleApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: Text(marker, style: TextStyle(fontSize: 32)))),
  );
}
