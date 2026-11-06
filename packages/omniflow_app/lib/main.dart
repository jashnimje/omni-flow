import 'package:flutter/material.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

void main() => runApp(const OmniFlowApp());

class OmniFlowApp extends StatelessWidget {
  const OmniFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OmniFlow',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00F5D4),
          brightness: Brightness.dark,
        ),
      ),
      home: const Scaffold(
        body: Center(child: Text('OmniFlow engine $omniflowEngineVersion')),
      ),
    );
  }
}
