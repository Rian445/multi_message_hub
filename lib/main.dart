import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set system UI overlay style matching Google Messages Dark
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF131314),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const MultiMessageHubApp());
}

class MultiMessageHubApp extends StatelessWidget {
  const MultiMessageHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Google Messages Dark Theme Colors
    const darkSurface = Color(0xFF1E1F22);
    const darkBackground = Color(0xFF131314);
    const googleBlueAccent = Color(0xFF8AB4F8);

    return MaterialApp(
      title: 'Multi-Message Hub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: darkBackground,
        colorScheme: const ColorScheme.dark(
          primary: googleBlueAccent,
          surface: darkSurface,
          surfaceContainer: darkSurface,
          surfaceContainerHighest: Color(0xFF2B2D31),
          onSurface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          backgroundColor: darkSurface,
          foregroundColor: Colors.white,
          iconTheme: IconThemeData(color: Colors.white),
        ),
        drawerTheme: const DrawerThemeData(
          backgroundColor: darkSurface,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
