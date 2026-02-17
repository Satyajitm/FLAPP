import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'core/services/foreground_service_manager.dart';
import 'features/chat/chat_screen.dart';
import 'features/location/location_screen.dart';
import 'features/emergency/emergency_screen.dart';
import 'features/group/create_group_screen.dart';
import 'features/group/join_group_screen.dart';

/// Root MaterialApp with bottom navigation between Chat, Map, and Emergency.
class FluxonApp extends StatelessWidget {
  const FluxonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
      title: 'FluxonApp',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3D5AFE),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF3D5AFE),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const _HomeScreen(),
      routes: {
        '/create-group': (_) => const CreateGroupScreen(),
        '/join-group': (_) => const JoinGroupScreen(),
      },
    ),
    );
  }
}

class _HomeScreen extends StatefulWidget {
  const _HomeScreen();

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Stop the foreground service only when the app process is being destroyed.
    // Do NOT stop on paused — backgrounding is exactly when it is needed.
    if (state == AppLifecycleState.detached) {
      ForegroundServiceManager.stop();
    }
  }

  static const _screens = [
    ChatScreen(),
    LocationScreen(),
    EmergencyScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_outlined),
            selectedIcon: Icon(Icons.chat),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.sos_outlined),
            selectedIcon: Icon(Icons.sos),
            label: 'SOS',
          ),
        ],
      ),
    );
  }
}
