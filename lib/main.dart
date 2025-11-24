import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;
  ThemeProvider() { _loadTheme(); }
  void toggleTheme(bool isDark) async {
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', isDark);
    notifyListeners();
  }
  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('isDarkMode') ?? false;
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, child) => MaterialApp(
          title: 'GeoAlert Earthquake Alert',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFF6D00)),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFF6D00),
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          themeMode: themeProvider.themeMode,
          home: const HomePage(),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  int _selectedIndex = 0;
  late AnimationController _fadeController;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    )..forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      extendBody: true,
      backgroundColor: isDark ? const Color(0xFF0A0E27) : const Color(0xFFF5F7FA),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFF6D00).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.waves, color: Color(0xFFFF6D00), size: 24),
            ),
            const SizedBox(width: 12),
            const Text(
              'GeoAlert',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 24,
              ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            onPressed: () {
              Provider.of<ThemeProvider>(context, listen: false)
                  .toggleTheme(!isDark);
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: FadeTransition(
        opacity: _fadeController,
        child: IndexedStack(
          index: _selectedIndex,
          children: const [RealTimePage(), MapPage(), AnalyticsPage()],
        ),
      ),
      bottomNavigationBar: Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1A1F3A) : Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (i) {
              setState(() => _selectedIndex = i);
              _fadeController.reset();
              _fadeController.forward();
            },
            backgroundColor: Colors.transparent,
            indicatorColor: const Color(0xFFFF6D00).withOpacity(0.2),
            height: 70,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.waves_outlined),
                selectedIcon: Icon(Icons.waves, color: Color(0xFFFF6D00)),
                label: 'Real Time',
              ),
              NavigationDestination(
                icon: Icon(Icons.map_outlined),
                selectedIcon: Icon(Icons.map, color: Color(0xFFFF6D00)),
                label: 'Map',
              ),
              NavigationDestination(
                icon: Icon(Icons.analytics_outlined),
                selectedIcon: Icon(Icons.analytics, color: Color(0xFFFF6D00)),
                label: 'Analytics',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RealTimePage extends StatefulWidget {
  const RealTimePage({super.key});
  @override State<RealTimePage> createState() => _RealTimePageState();
}

class _RealTimePageState extends State<RealTimePage> with TickerProviderStateMixin {
  final DatabaseReference _db = FirebaseDatabase.instance.ref('sensor/history');
  final List<FlSpot> _spots = [];
  double _currentPga = 0.0;
  String _intensity = "I – Scarcely Perceptible";
  double _pWaveTime = -1, _sWaveTime = -1;
  bool _pWaveDetected = false, _sWaveDetected = false;
  bool _isLoading = true;
  late AnimationController _pulseController;
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    
    _waveController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
    
    _listenToData();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  void _listenToData() {
    _db.onValue.listen((event) {
      if (!event.snapshot.exists) return;
      final map = event.snapshot.value as Map<dynamic, dynamic>;
      final List<Map<dynamic, dynamic>> list = [];
      map.forEach((_, v) => { if (v is Map) list.add(v.cast<dynamic, dynamic>()) });
      list.sort((a, b) => (a['timestamp'] ?? 0).compareTo(b['timestamp'] ?? 0));

      final newSpots = <FlSpot>[];
      for (int i = 0; i < list.length && i < 600; i++) {
        final pga = _calcPga(list[i]);
        newSpots.add(FlSpot(i.toDouble(), pga));

        if (!_pWaveDetected && pga > 0.05 && i > 10) {
          _pWaveDetected = true;
          _pWaveTime = i * 0.1;
        }
        if (_pWaveDetected && !_sWaveDetected && pga > 0.18) {
          _sWaveDetected = true;
          _sWaveTime = i * 0.1;
        }
      }

      setState(() {
        _isLoading = false;
        _spots.clear();
        final offset = max(0, newSpots.length - 120);
        for (int i = offset; i < newSpots.length; i++) {
          _spots.add(FlSpot(newSpots[i].x - offset, newSpots[i].y));
        }
        if (list.isNotEmpty) {
          _currentPga = _calcPga(list.last);
          _intensity = _getIntensity(_currentPga);
        }
      });
    });
  }

  double _calcPga(Map<dynamic, dynamic> d) => (d['pga'] as num?)?.toDouble() ?? 0.0;

  String _getIntensity(double pga) {
    if (pga < 0.0017) return "I – Scarcely Perceptible";
    if (pga < 0.014) return "II – Slightly Felt";
    if (pga < 0.039) return "III – Weak";
    if (pga < 0.092) return "IV – Moderately Strong";
    if (pga < 0.18) return "V – Strong";
    if (pga < 0.34) return "VI – Very Strong";
    if (pga < 0.65) return "VII – Destructive";
    if (pga < 1.24) return "VIII – Very Destructive";
    if (pga < 2.5) return "IX – Devastating";
    return "X – Completely Devastating";
  }

  Color _getColor(double pga) {
    if (pga < 0.039) return const Color(0xFF00E5FF);
    if (pga < 0.18) return const Color(0xFFFFAB00);
    return const Color(0xFFFF1744);
  }

  IconData _getIcon(double pga) {
    if (pga < 0.039) return Icons.radio_button_checked;
    if (pga < 0.18) return Icons.warning_rounded;
    return Icons.report_problem_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: screenWidth * 0.2,
              height: screenWidth * 0.2,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(
                  const Color(0xFFFF6D00).withOpacity(0.8),
                ),
              ),
            ),
            SizedBox(height: screenHeight * 0.03),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Connecting to seismic sensors...',
                style: TextStyle(
                  fontSize: screenWidth * 0.04,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        await Future.delayed(const Duration(seconds: 1));
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ListView(
            padding: EdgeInsets.symmetric(
              horizontal: constraints.maxWidth * 0.05,
              vertical: 16,
            ),
            children: [
          // Status Indicator
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: constraints.maxWidth * 0.04,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.green.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) => Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.green.withOpacity(_pulseController.value),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Live Monitoring',
                  style: TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.w600,
                    fontSize: constraints.maxWidth * 0.035,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: constraints.maxHeight * 0.02),

          // Main Intensity Card
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(constraints.maxWidth * 0.08),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _getColor(_currentPga).withOpacity(0.15),
                  _getColor(_currentPga).withOpacity(0.05),
                ],
              ),
              border: Border.all(
                color: _getColor(_currentPga).withOpacity(0.3),
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(constraints.maxWidth * 0.08),
              child: BackdropFilter(
                filter: isDark
                    ? ColorFilter.mode(Colors.black.withOpacity(0.2), BlendMode.darken)
                    : ColorFilter.mode(Colors.white.withOpacity(0.3), BlendMode.lighten),
                child: Padding(
                  padding: EdgeInsets.all(constraints.maxWidth * 0.08),
                  child: Column(
                    children: [
                      Container(
                        padding: EdgeInsets.all(constraints.maxWidth * 0.04),
                        decoration: BoxDecoration(
                          color: _getColor(_currentPga).withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _getIcon(_currentPga),
                          size: constraints.maxWidth * 0.12,
                          color: _getColor(_currentPga),
                        ),
                      ),
                      SizedBox(height: constraints.maxHeight * 0.015),
                      Text(
                        'Current Intensity',
                        style: TextStyle(
                          fontSize: constraints.maxWidth * 0.035,
                          color: isDark ? Colors.white70 : Colors.black54,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      SizedBox(height: constraints.maxHeight * 0.01),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _intensity.split('–')[0].trim(),
                          style: TextStyle(
                            fontSize: constraints.maxWidth * 0.16,
                            fontWeight: FontWeight.bold,
                            color: _getColor(_currentPga),
                            height: 1,
                          ),
                        ),
                      ),
                      SizedBox(height: constraints.maxHeight * 0.008),
                      Text(
                        _intensity.split('–').length > 1
                            ? _intensity.split('–')[1].trim()
                            : '',
                        style: TextStyle(
                          fontSize: constraints.maxWidth * 0.045,
                          color: isDark ? Colors.white70 : Colors.black54,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: constraints.maxHeight * 0.02),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: constraints.maxWidth * 0.05,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withOpacity(0.1)
                              : Colors.black.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'PGA',
                              style: TextStyle(
                                fontSize: constraints.maxWidth * 0.035,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1,
                              ),
                            ),
                            const SizedBox(width: 12),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '${_currentPga.toStringAsFixed(4)} g',
                                style: TextStyle(
                                  fontSize: constraints.maxWidth * 0.05,
                                  fontWeight: FontWeight.bold,
                                  color: _getColor(_currentPga),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          SizedBox(height: constraints.maxHeight * 0.02),

          // Wave Detection Cards
          if (_pWaveDetected || _sWaveDetected)
            Padding(
              padding: EdgeInsets.only(bottom: constraints.maxHeight * 0.02),
              child: LayoutBuilder(
                builder: (context, cardConstraints) {
                  return Row(
                    children: [
                      if (_pWaveDetected)
                        Expanded(
                          child: _WaveCard(
                            title: 'P-Wave',
                            time: _pWaveTime,
                            color: const Color(0xFF00E5FF),
                            icon: Icons.send_rounded,
                            maxWidth: cardConstraints.maxWidth,
                          ),
                        ),
                      if (_pWaveDetected && _sWaveDetected) const SizedBox(width: 12),
                      if (_sWaveDetected)
                        Expanded(
                          child: _WaveCard(
                            title: 'S-Wave',
                            time: _sWaveTime,
                            color: const Color(0xFFFF1744),
                            icon: Icons.waves_rounded,
                            maxWidth: cardConstraints.maxWidth,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),

          SizedBox(height: constraints.maxHeight * 0.025),

          // Seismogram Section
          Row(
            children: [
              Container(
                width: 4,
                height: 24,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6D00),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  'Live Seismogram',
                  style: TextStyle(
                    fontSize: constraints.maxWidth * 0.055,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: constraints.maxHeight * 0.015),

          Container(
            height: constraints.maxHeight * 0.35,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? [
                        const Color(0xFF1A1F3A),
                        const Color(0xFF0D1117),
                      ]
                    : [
                        Colors.white,
                        Colors.grey.shade50,
                      ],
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.1)
                    : Colors.black.withOpacity(0.1),
              ),
            ),
            padding: EdgeInsets.all(constraints.maxWidth * 0.04),
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 0.2,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: isDark
                        ? Colors.white.withOpacity(0.05)
                        : Colors.black.withOpacity(0.05),
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  show: true,
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 30,
                      reservedSize: 30,
                      getTitlesWidget: (value, meta) => Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${value.toInt()}s',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: constraints.maxWidth * 0.025,
                          ),
                        ),
                      ),
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (value, meta) => Text(
                        '${value.toStringAsFixed(1)}g',
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: constraints.maxWidth * 0.025,
                        ),
                      ),
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: _spots,
                    isCurved: true,
                    curveSmoothness: 0.35,
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFF00E5FF),
                        const Color(0xFF2962FF),
                        const Color(0xFFD500F9),
                      ],
                    ),
                    barWidth: 3,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          const Color(0xFF00E5FF).withOpacity(0.3),
                          const Color(0xFF2962FF).withOpacity(0.1),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ],
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    HorizontalLine(
                      y: 0.039,
                      color: Colors.green.withOpacity(0.6),
                      strokeWidth: 1.5,
                      dashArray: [5, 5],
                      label: HorizontalLineLabel(
                        show: true,
                        labelResolver: (line) => 'IV',
                        style: const TextStyle(
                          color: Colors.green,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    HorizontalLine(
                      y: 0.18,
                      color: Colors.orange.withOpacity(0.7),
                      strokeWidth: 1.5,
                      dashArray: [5, 5],
                      label: HorizontalLineLabel(
                        show: true,
                        labelResolver: (line) => 'V',
                        style: const TextStyle(
                          color: Colors.orange,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    HorizontalLine(
                      y: 0.34,
                      color: Colors.red.withOpacity(0.8),
                      strokeWidth: 1.5,
                      dashArray: [5, 5],
                      label: HorizontalLineLabel(
                        show: true,
                        labelResolver: (line) => 'VI',
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                minX: 0,
                maxX: 120,
                minY: -0.6,
                maxY: max(1.2, _currentPga * 1.8),
              ),
            ),
          ),

          SizedBox(height: constraints.maxHeight * 0.02),

          // Info Card
          // Container(
          //   padding: EdgeInsets.all(constraints.maxWidth * 0.05),
          //   decoration: BoxDecoration(
          //     color: const Color(0xFFFF6D00).withOpacity(0.1),
          //     borderRadius: BorderRadius.circular(20),
          //     border: Border.all(
          //       color: const Color(0xFFFF6D00).withOpacity(0.3),
          //     ),
          //   ),
          //   // child: Row(
          //   //   children: [
          //   //     Icon(
          //   //       Icons.info_outline,
          //   //       color: const Color(0xFFFF6D00),
          //   //       size: constraints.maxWidth * 0.06,
          //   //     ),
          //   //     SizedBox(width: constraints.maxWidth * 0.04),
          //   //     // Expanded(
          //   //     //   child: Text(
          //   //     //     'Data sourced from PHIVOLCS seismic network',
          //   //     //     style: TextStyle(
          //   //     //       fontSize: constraints.maxWidth * 0.035,
          //   //     //       color: isDark ? Colors.white70 : Colors.black87,
          //   //     //     ),
          //   //     //   ),
          //   //     // ),
          //   //   ],
          //   // ),
          // ),
          SizedBox(height: screenHeight * 0.12),
        ],
      );
    },
  ),
);
  }
}

class _WaveCard extends StatelessWidget {
  final String title;
  final double time;
  final Color color;
  final IconData icon;
  final double maxWidth;

  const _WaveCard({
    required this.title,
    required this.time,
    required this.color,
    required this.icon,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.all(maxWidth * 0.04),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: maxWidth * 0.045),
              SizedBox(width: maxWidth * 0.02),
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: maxWidth * 0.035,
                    letterSpacing: 0.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: maxWidth * 0.025),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '${time.toStringAsFixed(1)}s',
              style: TextStyle(
                fontSize: maxWidth * 0.07,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'ago',
            style: TextStyle(
              fontSize: maxWidth * 0.03,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
        ],
      ),
    );
  }
}

// MAP PAGE WITH REAL-TIME EARTHQUAKE TRACKING
class MapPage extends StatefulWidget {
  const MapPage({super.key});
  @override State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  List<EarthquakeData> _earthquakes = [];
  bool _isLoading = true;
  String _selectedRegion = 'Philippines';
  final List<String> _regions = ['Philippines', 'Southeast Asia', 'Global'];

  @override
  void initState() {
    super.initState();
    _loadEarthquakes();
  }

  Future<void> _loadEarthquakes() async {
    setState(() => _isLoading = true);
    
    try {
      // USGS Earthquake API - Last 7 days, magnitude 2.5+
      String url;
      if (_selectedRegion == 'Philippines') {
        // Philippines region: latitude 4-21°N, longitude 116-127°E
        url = 'https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson&starttime=${DateTime.now().subtract(const Duration(days: 7)).toIso8601String()}&minlatitude=4&maxlatitude=21&minlongitude=116&maxlongitude=127&minmagnitude=2.5';
      } else if (_selectedRegion == 'Southeast Asia') {
        url = 'https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson&starttime=${DateTime.now().subtract(const Duration(days: 7)).toIso8601String()}&minlatitude=-10&maxlatitude=25&minlongitude=95&maxlongitude=140&minmagnitude=3.0';
      } else {
        url = 'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_week.geojson';
      }

      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final features = data['features'] as List;
        
        setState(() {
          _earthquakes = features.map((f) {
            final props = f['properties'];
            final coords = f['geometry']['coordinates'];
            return EarthquakeData(
              magnitude: (props['mag'] as num?)?.toDouble() ?? 0.0,
              place: props['place'] ?? 'Unknown',
              time: DateTime.fromMillisecondsSinceEpoch(props['time'] ?? 0),
              latitude: (coords[1] as num?)?.toDouble() ?? 0.0,
              longitude: (coords[0] as num?)?.toDouble() ?? 0.0,
              depth: (coords[2] as num?)?.toDouble() ?? 0.0,
              url: props['url'] ?? '',
            );
          }).toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading earthquake data: $e')),
        );
      }
    }
  }

  Color _getMagnitudeColor(double mag) {
    if (mag < 3.0) return Colors.green;
    if (mag < 4.5) return Colors.yellow.shade700;
    if (mag < 6.0) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;

    return RefreshIndicator(
      onRefresh: _loadEarthquakes,
      child: Column(
        children: [
          // Region Filter
          Container(
            margin: EdgeInsets.all(screenWidth * 0.04),
            padding: EdgeInsets.symmetric(horizontal: screenWidth * 0.04, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1A1F3A) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.1)
                    : Colors.black.withOpacity(0.1),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.public, size: screenWidth * 0.05),
                SizedBox(width: screenWidth * 0.03),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedRegion,
                      isExpanded: true,
                      items: _regions.map((region) {
                        return DropdownMenuItem(
                          value: region,
                          child: Text(
                            region,
                            style: TextStyle(fontSize: screenWidth * 0.04),
                          ),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _selectedRegion = value);
                          _loadEarthquakes();
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Map View (Simulated)
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: EdgeInsets.symmetric(horizontal: screenWidth * 0.04),
                    itemCount: _earthquakes.length,
                    itemBuilder: (context, index) {
                      final eq = _earthquakes[index];
                      final timeAgo = _formatTimeAgo(eq.time);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF1A1F3A)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: _getMagnitudeColor(eq.magnitude)
                                .withOpacity(0.3),
                            width: 2,
                          ),
                        ),
                        child: ListTile(
                          contentPadding: EdgeInsets.all(screenWidth * 0.04),
                          leading: Container(
                            width: screenWidth * 0.14,
                            height: screenWidth * 0.14,
                            decoration: BoxDecoration(
                              color: _getMagnitudeColor(eq.magnitude)
                                  .withOpacity(0.2),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  eq.magnitude.toStringAsFixed(1),
                                  style: TextStyle(
                                    fontSize: screenWidth * 0.045,
                                    fontWeight: FontWeight.bold,
                                    color: _getMagnitudeColor(eq.magnitude),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          title: Text(
                            eq.place,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: screenWidth * 0.038,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(height: screenWidth * 0.02),
                              Row(
                                children: [
                                  Icon(
                                    Icons.access_time,
                                    size: screenWidth * 0.035,
                                    color: isDark
                                        ? Colors.white60
                                        : Colors.black54,
                                  ),
                                  SizedBox(width: screenWidth * 0.01),
                                  Flexible(
                                    child: Text(
                                      timeAgo,
                                      style: TextStyle(
                                        fontSize: screenWidth * 0.03,
                                        color: isDark
                                            ? Colors.white60
                                            : Colors.black54,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: screenWidth * 0.01),
                              Row(
                                children: [
                                  Icon(
                                    Icons.location_on,
                                    size: screenWidth * 0.035,
                                    color: isDark
                                        ? Colors.white60
                                        : Colors.black54,
                                  ),
                                  SizedBox(width: screenWidth * 0.01),
                                  Flexible(
                                    child: Text(
                                      '${eq.latitude.toStringAsFixed(2)}°, ${eq.longitude.toStringAsFixed(2)}°',
                                      style: TextStyle(
                                        fontSize: screenWidth * 0.03,
                                        color: isDark
                                            ? Colors.white60
                                            : Colors.black54,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  SizedBox(width: screenWidth * 0.03),
                                  Icon(
                                    Icons.arrow_downward,
                                    size: screenWidth * 0.035,
                                    color: isDark
                                        ? Colors.white60
                                        : Colors.black54,
                                  ),
                                  SizedBox(width: screenWidth * 0.01),
                                  Text(
                                    '${eq.depth.toStringAsFixed(1)} km',
                                    style: TextStyle(
                                      fontSize: screenWidth * 0.03,
                                      color: isDark
                                          ? Colors.white60
                                          : Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: _getMagnitudeColor(eq.magnitude),
                            size: screenWidth * 0.06,
                          ),
                          onTap: () {
                            _showEarthquakeDetails(context, eq);
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _formatTimeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  void _showEarthquakeDetails(BuildContext context, EarthquakeData eq) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1A1F3A) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.all(screenWidth * 0.06),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              SizedBox(height: screenWidth * 0.06),
              Row(
                children: [
                  Container(
                    width: screenWidth * 0.16,
                    height: screenWidth * 0.16,
                    decoration: BoxDecoration(
                      color: _getMagnitudeColor(eq.magnitude).withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          eq.magnitude.toStringAsFixed(1),
                          style: TextStyle(
                            fontSize: screenWidth * 0.06,
                            fontWeight: FontWeight.bold,
                            color: _getMagnitudeColor(eq.magnitude),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: screenWidth * 0.04),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'Magnitude ${eq.magnitude.toStringAsFixed(1)}',
                            style: TextStyle(
                              fontSize: screenWidth * 0.05,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Text(
                          _formatTimeAgo(eq.time),
                          style: TextStyle(
                            fontSize: screenWidth * 0.035,
                            color: isDark ? Colors.white60 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: screenWidth * 0.06),
              _DetailRow(
                icon: Icons.location_on,
                label: 'Location',
                value: eq.place,
                screenWidth: screenWidth,
              ),
              _DetailRow(
                icon: Icons.public,
                label: 'Coordinates',
                value:
                    '${eq.latitude.toStringAsFixed(4)}°, ${eq.longitude.toStringAsFixed(4)}°',
                screenWidth: screenWidth,
              ),
              _DetailRow(
                icon: Icons.arrow_downward,
                label: 'Depth',
                value: '${eq.depth.toStringAsFixed(1)} km',
                screenWidth: screenWidth,
              ),
              _DetailRow(
                icon: Icons.calendar_today,
                label: 'Time',
                value: '${eq.time.toLocal()}',
                screenWidth: screenWidth,
              ),
              SizedBox(height: screenWidth * 0.04),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  label: const Text('Close'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6D00),
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: screenWidth * 0.04),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final double screenWidth;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.screenWidth,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Padding(
      padding: EdgeInsets.symmetric(vertical: screenWidth * 0.02),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: screenWidth * 0.05,
            color: const Color(0xFFFF6D00),
          ),
          SizedBox(width: screenWidth * 0.03),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: screenWidth * 0.03,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: screenWidth * 0.035,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class EarthquakeData {
  final double magnitude;
  final String place;
  final DateTime time;
  final double latitude;
  final double longitude;
  final double depth;
  final String url;

  EarthquakeData({
    required this.magnitude,
    required this.place,
    required this.time,
    required this.latitude,
    required this.longitude,
    required this.depth,
    required this.url,
  });
}

class AnalyticsPage extends StatelessWidget {
  const AnalyticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;

    return Center(
      child: Container(
        margin: EdgeInsets.all(screenWidth * 0.08),
        padding: EdgeInsets.all(screenWidth * 0.08),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1A1F3A) : Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isDark
                ? Colors.white.withOpacity(0.1)
                : Colors.black.withOpacity(0.1),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(screenWidth * 0.05),
              decoration: BoxDecoration(
                color: const Color(0xFFFF6D00).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.analytics_outlined,
                size: screenWidth * 0.16,
                color: const Color(0xFFFF6D00),
              ),
            ),
            SizedBox(height: screenWidth * 0.06),
            Text(
              'Analytics Coming Soon',
              style: TextStyle(
                fontSize: screenWidth * 0.06,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: screenWidth * 0.03),
            Text(
              'Historical earthquake data and trends will appear here after Cloud Function deployment',
              style: TextStyle(
                fontSize: screenWidth * 0.035,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}