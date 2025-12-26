import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'dart:isolate';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:math';
import 'package:url_launcher/url_launcher.dart';




// === GLOBAL VARIABLES ===
ValueNotifier<Color> mainColor = ValueNotifier(Colors.cyanAccent);
ValueNotifier<Color> breakColor = ValueNotifier(Colors.pinkAccent);
ValueNotifier<Color> examColor = ValueNotifier(Colors.greenAccent);

// Settings Controls
ValueNotifier<bool> enableLockScreen = ValueNotifier(true);
ValueNotifier<bool> enableNotificationSound = ValueNotifier(true); // 👈 Ye ab MASTER SWITCH hai
// 👇 NEW: Sticky Notification Toggle (Default true rakh rahe hain)
ValueNotifier<bool> enableStickyNotification = ValueNotifier(true);
ValueNotifier<bool> resetTimerOnSwitch = ValueNotifier(false);

ValueNotifier<String> soundAlarm = ValueNotifier("alarm.mp3");
ValueNotifier<String> soundBreak = ValueNotifier("bell.mp3");
ValueNotifier<String> soundDone = ValueNotifier("success.mp3");

List<String> availableSounds = [];
StreamController<String> notificationActionStream = StreamController.broadcast();
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
final AudioPlayer _audioPlayer = AudioPlayer();

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'timer_foreground',
    'Foreground Timer',
    description: 'This channel is used for timer service',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
  FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'timer_foreground',
      initialNotificationTitle: 'Timer Manager',
      initialNotificationContent: 'Initializing...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(),
  );
}

// 👇 STEP 1: IS FUNCTION KO UPDATE KARO
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
  FlutterLocalNotificationsPlugin();

  // 1. Initialize Notification & Handle Button Clicks
  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('timer_icon'),
    ),
    onDidReceiveNotificationResponse: (NotificationResponse details) {
      if (details.actionId == 'pause_service') {
        service.invoke('action', {'type': 'pause'});
      } else if (details.actionId == 'resume_service') {
        service.invoke('action', {'type': 'resume'});
      } else if (details.actionId == 'stop_service') {
        service.stopSelf(); // 👇 Ye service aur notification dono ko maar dega
      }
    },
  );

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // 2. Handle Bridge Button Clicks (Background)
  service.on('button_click').listen((event) {
    String? actionId = event?['actionId'];
    if (actionId == 'pause_service' || actionId == 'pause_timer') {
      service.invoke('action', {'type': 'pause'});
    } else if (actionId == 'resume_service' || actionId == 'resume_timer') {
      service.invoke('action', {'type': 'resume'});
    } else if (actionId == 'stop_service') {
      service.stopSelf(); // 👇 Close Button Logic
    }
  });

  // 3. Notification Update Listener
  service.on('updateNotification').listen((event) async {
    String title = event?['title'] ?? 'Timer';
    String body = event?['body'] ?? 'Running...';
    bool isTimerRunning = event?['showPause'] ?? true;
    String iconName = event?['largeIcon'] ?? 'study';
    bool isStickySetting = event?['isSticky'] ?? true;

    // Logic: Notification tabhi chipkega jab Timer chal raha ho YA Sticky ON ho
    bool shouldBeOngoing = isStickySetting || isTimerRunning;

   // print("SERVICE DEBUG: Running: $isTimerRunning | Sticky: $isStickySetting | Ongoing: $shouldBeOngoing");

    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        flutterLocalNotificationsPlugin.show(
          888,
          title,
          body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              'timer_foreground',
              'Foreground Timer',
              icon: 'timer_icon',
              largeIcon: DrawableResourceAndroidBitmap(iconName),
              color: const Color(0xFF616161),
              colorized: true,

              // Redmi ke liye attempts:
              ongoing: shouldBeOngoing,
              autoCancel: !shouldBeOngoing,
              priority: shouldBeOngoing ? Priority.high : Priority.low, // Low priority might help
              importance: shouldBeOngoing ? Importance.high : Importance.low,

              playSound: false,
              actions: [
                // 1. Agar Timer Chal raha hai -> PAUSE Button
                if (isTimerRunning)
                  const AndroidNotificationAction('pause_service', 'PAUSE', showsUserInterface: false)

                // 2. Agar Timer Ruka hai (Paused) -> RESUME Button
                else ...[
                  const AndroidNotificationAction('resume_service', 'RESUME', showsUserInterface: false),

                  // 👇 3. EXIT BUTTON (Sirf tab dikhega jab Sticky OFF ho aur Timer Ruka ho)
                  if (!isStickySetting)
                    const AndroidNotificationAction('stop_service', 'EXIT APP', showsUserInterface: false),
                ]
              ],
            ),
          ),
        );
      }
    }
  });
}

// === BACKGROUND NOTIFICATION HANDLER ===
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse notificationResponse) {
  print("Background Button Clicked: ${notificationResponse.actionId}");

  // 1. Pehle Port check karo (Purana tarika)
  final SendPort? sendPort = IsolateNameServer.lookupPortByName('time_manager_notification_port');
  if (sendPort != null) {
    if (notificationResponse.actionId != null) {
      sendPort.send(notificationResponse.actionId);
    }
  } else {
    // 2. 👇 AGAR PORT NA MILE, TO SERVICE KO BOLO (Ye Naya Fix Hai)
    print("Port dead via Isolate. Trying Service Invoke...");
    final service = FlutterBackgroundService();
    service.invoke("button_click", {'actionId': notificationResponse.actionId});
  }
}

ReceivePort? _receivePort;


// 👇 MAIN FUNCTION KO REPLACE KARO
// 👇 FIX: main function update karo
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Service Init
  await initializeService();

  // Agar tum purana notification logic use kar rahe ho to use bhi init kar sakte ho,
  // lekin Service ke sath conflicts ho sakte hain. Filhal simple rakho.

  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: SplashScreen()));
}

// === SPLASH SCREEN (UPDATED) ===
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Duration 2 seconds rakha hai taaki rotation smooth dikhe
    _controller = AnimationController(duration: const Duration(seconds: 2), vsync: this)..repeat();
    _loadAppResources();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadAppResources() async {
    // Yahan hum resources load kar rahe hain
    await initNotifications();
    await loadAssetSounds();

    final prefs = await SharedPreferences.getInstance();

    // Preferences Load
    enableLockScreen.value = prefs.getBool('lock_screen_popup') ?? true;
    enableNotificationSound.value = prefs.getBool('enable_notif_sound') ?? true;
    resetTimerOnSwitch.value = prefs.getBool('reset_timer_switch') ?? false;
    enableStickyNotification.value = prefs.getBool('sticky_notif') ?? true;

    mainColor.value = Color(prefs.getInt('color_main') ?? Colors.cyanAccent.value);
    breakColor.value = Color(prefs.getInt('color_break') ?? Colors.pinkAccent.value);
    examColor.value = Color(prefs.getInt('color_exam') ?? Colors.greenAccent.value);

    // Sounds Load
    String sA = prefs.getString('snd_alarm') ?? "alarm.mp3";
    String sB = prefs.getString('snd_break') ?? "bell.mp3";
    String sD = prefs.getString('snd_done') ?? "success.mp3";
    soundAlarm.value = availableSounds.contains(sA) ? sA : "alarm.mp3";
    soundBreak.value = availableSounds.contains(sB) ? sB : "bell.mp3";
    soundDone.value = availableSounds.contains(sD) ? sD : "success.mp3";

    // Thoda delay taaki animation dikhe (Optional, hata sakte ho agar fast chahiye)
    await Future.delayed(const Duration(seconds: 3));

    if (mounted) {
      // Jaise hi load hua, turant next screen (Animation wahin cut ho jayegi)
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        pageBuilder: (_, __, ___) => const MyApp(),
        transitionsBuilder: (_, animation, __, child) => FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 800),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Clock Animation
            AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return CustomPaint(
                      size: const Size(200, 200),
                      painter: AnalogClockPainter(_controller.value)
                  );
                }
            ),
            const SizedBox(height: 60),
            const Text(
                "TIME MANAGER",
                style: TextStyle(
                    color: Colors.cyanAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 24,
                    letterSpacing: 3.0,
                    fontFamily: 'monospace'
                )
            ),
            const SizedBox(height: 10),
            const Text("Setting up your workspace...", style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// 👇 UPDATED PAINTER CLASS (Sui Logic Fixed)
class AnalogClockPainter extends CustomPainter {
  final double animationValue;
  AnalogClockPainter(this.animationValue);

  @override
  void paint(Canvas canvas, Size size) {
    double centerX = size.width / 2;
    double centerY = size.height / 2;
    Offset center = Offset(centerX, centerY);
    double radius = size.width / 2;

    // 1. Tick Marks (Ghadi ke nishan)
    Paint tickPaint = Paint()..strokeCap = StrokeCap.butt..style = PaintingStyle.stroke;
    for (int i = 0; i < 60; i++) {
      double angle = (i * 6) * (pi / 180);
      bool isHourMark = i % 5 == 0;
      double lineLength = isHourMark ? 20.0 : 10.0;

      tickPaint.color = isHourMark ? Colors.cyanAccent : Colors.grey[800]!;
      tickPaint.strokeWidth = isHourMark ? 6 : 2;

      double x1 = centerX + (radius - lineLength) * cos(angle);
      double y1 = centerY + (radius - lineLength) * sin(angle);
      double x2 = centerX + radius * cos(angle);
      double y2 = centerY + radius * sin(angle);
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), tickPaint);
    }

    // 2. Hour Hand (Moti sui) - Ab ye Pura Gol ghumegi
    // (animationValue * 2 * pi) ka matlab hai 1 complete circle per loop
    _drawTaperedHand(canvas, center, radius * 0.5, 8, Colors.white.withOpacity(0.8), (animationValue * 2 * pi));

    // 3. Second Hand (Lambiwali sui) - Ab ye CYAN hai (Red nahi)
    // Ye thoda tez ghumegi (4 chakkar lagayegi jab tak hour hand 1 lagayegi)
    _drawTaperedHand(canvas, center, radius * 0.85, 3, Colors.cyanAccent, (animationValue * 8 * pi));

    // 4. Center Dots
    canvas.drawCircle(center, 8, Paint()..color = Colors.black);
    canvas.drawCircle(center, 4, Paint()..color = Colors.cyanAccent); // Dot bhi Cyan kar diya
  }

  void _drawTaperedHand(Canvas canvas, Offset center, double length, double baseWidth, Color color, double angleRadians) {
    double adjustedAngle = angleRadians - (pi / 2);
    Paint handPaint = Paint()..color = color..style = PaintingStyle.fill;
    Path path = Path();

    double dx = cos(adjustedAngle);
    double dy = sin(adjustedAngle);
    double pdx = -dy;
    double pdy = dx;
    double halfWidth = baseWidth / 2;

    Offset base1 = Offset(center.dx + pdx * halfWidth, center.dy + pdy * halfWidth);
    Offset base2 = Offset(center.dx - pdx * halfWidth, center.dy - pdy * halfWidth);
    Offset tip = Offset(center.dx + dx * length, center.dy + dy * length);
    Offset tail = Offset(center.dx - dx * (length * 0.2), center.dy - dy * (length * 0.2)); // Thoda piche bhi nikla rahega balance ke liye

    path.moveTo(tail.dx, tail.dy);
    path.lineTo(base1.dx, base1.dy);
    path.lineTo(tip.dx, tip.dy);
    path.lineTo(base2.dx, base2.dy);
    path.close();
    canvas.drawPath(path, handPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

void playButtonFeedback() { HapticFeedback.lightImpact(); SystemSound.play(SystemSoundType.click); }

// 👇 FIX: Global Sound Mute Check
Future<void> playGlobalSound(String fileName) async {
  if (!enableNotificationSound.value) return; // Agar setting OFF hai to koi sound nahi bajega
  try { await _audioPlayer.stop(); await _audioPlayer.play(AssetSource('sounds/$fileName')); } catch (e) { print("Sound Error: $e"); }
}

// 👇 INIT NOTIFICATIONS KO REPLACE KARO
Future<void> initNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('timer_icon');

  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(android: initializationSettingsAndroid),

    // Jab App Foreground me ho (Khuli ho)
    onDidReceiveNotificationResponse: (NotificationResponse resp) {
      print("Foreground Action: ${resp.actionId}");
      if (resp.actionId != null) {
        notificationActionStream.add(resp.actionId!);
      }
    },

    // Jab App Background/Killed ho
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

// === NOTIFICATION LOGIC (FIXED) ===
Future<void> showTimerNotification({
  required String title,
  required String body,
  required Color color,
  required bool isRunning,
  required bool isTick,
  bool isFinished = false,
  bool playSound = false,
}) async {
  try {
    // 1. Sound Control
    bool shouldPlaySound = playSound && !isTick && enableNotificationSound.value;

    // 2. Wake Screen Control
    bool wakeScreen = false;
    if (!isTick && enableLockScreen.value) wakeScreen = true;

    // 3. Category & Priority
    AndroidNotificationCategory category = wakeScreen ? AndroidNotificationCategory.alarm : AndroidNotificationCategory.progress;
    Priority priority = isTick ? Priority.low : Priority.high;
    Importance importance = isTick ? Importance.low : Importance.max;

    // 4. Buttons (Actions)
    List<AndroidNotificationAction> actions = [];
    if (!isFinished) {
      if (isRunning) {
        actions.add(const AndroidNotificationAction('pause_timer', 'PAUSE', showsUserInterface: false));
      } else {
        actions.add(const AndroidNotificationAction('resume_timer', 'RESUME', showsUserInterface: false));
      }
    }

    AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'timer_channel_master_v12',
      'Timer Notifications',
      importance: importance,
      priority: priority,
      category: category,
      fullScreenIntent: wakeScreen,

      playSound: shouldPlaySound,
      enableVibration: !isTick,

      onlyAlertOnce: true,
      color: color,
      colorized: true,

      // ⚠️ MAIN FIX: Ise 'true' kar do taaki pause hone par notification gayab na ho
      ongoing: true,

      autoCancel: false,
      actions: actions,
      visibility: NotificationVisibility.public,
    );

    await flutterLocalNotificationsPlugin.show(0, title, body, NotificationDetails(android: androidDetails), payload: 'open_app');
  } catch (e) {
    print("Notif Error: $e");
  }
}

Future<void> cancelNotification() async {
  await flutterLocalNotificationsPlugin.cancel(0);
}

// 👇 FIX: Modern Asset Loader (Flutter ke naye versions ke liye)
Future<void> loadAssetSounds() async {
  try {
    // 1. Naya Tarika: AssetManifest class use karo (JSON file ki zarurat nahi)
    final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);

    // 2. Saare assets ki list nikalo
    final List<String> assets = assetManifest.listAssets();

    // 3. Sirf 'sounds/' folder wale aur '.mp3' files filter karo
    final soundPaths = assets
        .where((String key) => key.contains('sounds/') && key.toLowerCase().endsWith('.mp3'))
        .toList();

    // 4. List update karo
    if (soundPaths.isNotEmpty) {
      availableSounds = soundPaths.map((path) => path.split('/').last).toList();
      print("✅ Loaded Sounds (${availableSounds.length}): $availableSounds");
    } else {
      print("⚠️ No sounds found via scanning. Using defaults.");
      availableSounds = ["alarm.mp3", "bell.mp3", "success.mp3"];
    }

  } catch (e) {
    print("❌ Error scanning assets: $e");
    // Fallback agar kuch gadbad ho
    availableSounds = ["alarm.mp3", "bell.mp3", "success.mp3"];
  }
}

// 👇 FIX: Crash Rokne ke liye Try-Catch Block
Future<void> updateJsonFile() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    String? path = prefs.getString('backup_path');
    if (path == null) return;

    Map<String, dynamic> fullData = {
      "tasks": jsonDecode(prefs.getString('saved_tasks') ?? "[]"),
      "history": jsonDecode(prefs.getString('study_history') ?? "[]"),
      "subjects": prefs.getStringList('study_subjects') ?? [],
      "breaks": prefs.getStringList('break_activities') ?? [],
      "subject_colors": jsonDecode(prefs.getString('subject_colors') ?? "{}"),
      "color_main": prefs.getInt('color_main'),
      "color_break": prefs.getInt('color_break'),
      "color_exam": prefs.getInt('color_exam'),
    };

    File file = File('$path/time_manager_data.json');
    await file.writeAsString(jsonEncode(fullData));
    print("Backup File Updated Successfully");

  } catch (e) {
    // Agar permission fail hui, to yahan pakda jayega
    // App CRASH NAHI HOGI
    print("⚠️ Error saving backup file: $e");
    print("Don't worry, internal data is still safe in SharedPreferences.");
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
        valueListenable: mainColor,
        builder: (context, color, child) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'Time Manager',
            theme: ThemeData.dark().copyWith(
              scaffoldBackgroundColor: Colors.black,
              primaryColor: color,
              colorScheme: const ColorScheme.dark().copyWith(secondary: color),
            ),
            home: const HomeScreen(),
          );
        });
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 1;
  final PageController _pageController = PageController(initialPage: 1);

  @override
  void initState() {
    super.initState();
    _checkStorageSetup();
  }

// 👇 FIX: App khulte hi Automatic Permission Maangne wala code
  Future<void> _checkStorageSetup() async {
    // 1. Sabse pehle 'Manage All Files' permission check karo aur mango
    if (!await Permission.manageExternalStorage.isGranted) {
      await Permission.manageExternalStorage.request();
    }

    // 2. Android 10 ya usse niche ke liye Storage permission bhi check kar lo
    if (!await Permission.storage.isGranted) {
      await Permission.storage.request();
    }

    // 3. Ab folder setup check karo (Purana logic)
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('backup_path') == null) {
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) _showSetupDialog();
    }
  }

  void _showSetupDialog() {
    showDialog(context: context, barrierDismissible: false, builder: (context) => AlertDialog(backgroundColor: const Color(0xFF1E1E1E), title: Text("Select Folder", style: TextStyle(color: mainColor.value)), content: const Text("Select 'Download' or 'Documents' folder to save data.", style: TextStyle(color: Colors.white70)), actions: [ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: mainColor.value), onPressed: () async {
      await Permission.manageExternalStorage.request();
      var status = await Permission.storage.request();
      if (status.isGranted || await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted) {
        String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
        if (selectedDirectory != null) { final prefs = await SharedPreferences.getInstance(); await prefs.setString('backup_path', selectedDirectory); Navigator.pop(context); }
      }
    }, child: const Text("CHOOSE FOLDER", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)))]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: const [TaskListScreen(), UniversalTimerScreen(), StatisticsScreen(), SettingsScreen()],
      ),
      bottomNavigationBar: MediaQuery.of(context).orientation == Orientation.landscape ? null : BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) { playButtonFeedback(); setState(() { _currentIndex = index; _pageController.jumpToPage(index); }); },
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color(0xFF1E1E1E),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.list), label: "Tasks"),
          BottomNavigationBarItem(icon: Icon(Icons.timer), label: "Timer"),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: "Stats"),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: "Settings"),
        ],
      ),
    );
  }
}

// ================== 1. TASKS SCREEN ==================
class TaskListScreen extends StatefulWidget { const TaskListScreen({super.key}); @override State<TaskListScreen> createState() => _TaskListScreenState(); }
class _TaskListScreenState extends State<TaskListScreen> with AutomaticKeepAliveClientMixin {
  @override bool get wantKeepAlive => true; Map<String, List<dynamic>> allTasks = {}; DateTime selectedDate = DateTime.now(); final TextEditingController _textController = TextEditingController(); String get _dateKey => DateFormat('yyyy-MM-dd').format(selectedDate);
  @override void initState() { super.initState(); _loadTasks(); }
  Future<void> _loadTasks() async { final prefs = await SharedPreferences.getInstance(); final String? tasksString = prefs.getString('saved_tasks'); if (tasksString != null) { if (mounted) { setState(() { try { Map<String, dynamic> decoded = jsonDecode(tasksString); allTasks = decoded.map((key, value) => MapEntry(key, List<dynamic>.from(value))); } catch (e) { List<dynamic> oldList = jsonDecode(tasksString); allTasks[_dateKey] = oldList; } }); } } }
  Future<void> _saveTasks() async { final prefs = await SharedPreferences.getInstance(); await prefs.setString('saved_tasks', jsonEncode(allTasks)); updateJsonFile(); }
  List<dynamic> _getCurrentDayTasks() { return allTasks[_dateKey] ?? []; }
  void _addNewTask() { showDialog(context: context, builder: (context) { return AlertDialog(backgroundColor: const Color(0xFF1E1E1E), title: Text("New Task", style: TextStyle(color: mainColor.value)), content: TextField(controller: _textController, style: const TextStyle(color: Colors.white), cursorColor: mainColor.value, autofocus: true, decoration: InputDecoration(hintText: "Add for ${DateFormat('dd MMM').format(selectedDate)}...", hintStyle: const TextStyle(color: Colors.grey), enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: mainColor.value)), focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: mainColor.value, width: 2)))), actions: [TextButton(onPressed: () { Navigator.pop(context); _textController.clear(); }, child: const Text("CANCEL", style: TextStyle(color: Colors.redAccent))), TextButton(onPressed: () { if (_textController.text.isNotEmpty) { setState(() { if (allTasks[_dateKey] == null) { allTasks[_dateKey] = []; } allTasks[_dateKey]!.add({"title": _textController.text, "isDone": false}); }); _saveTasks(); _textController.clear(); Navigator.pop(context); } }, child: Text("ADD", style: TextStyle(color: mainColor.value, fontWeight: FontWeight.bold)))]); }); }
  void _deleteTask(int index) { setState(() { allTasks[_dateKey]?.removeAt(index); if (allTasks[_dateKey]!.isEmpty) { allTasks.remove(_dateKey); } }); _saveTasks(); }
  void _toggleTask(int index) { setState(() { var task = allTasks[_dateKey]![index]; task['isDone'] = !task['isDone']; }); _saveTasks(); }
  void _changeDate(int days) { playButtonFeedback(); setState(() { selectedDate = selectedDate.add(Duration(days: days)); }); }
  Future<void> _pickDate() async { DateTime? picked = await showDatePicker(context: context, initialDate: selectedDate, firstDate: DateTime(2023), lastDate: DateTime(2030), builder: (context, child) { return Theme(data: ThemeData.dark().copyWith(colorScheme: ColorScheme.dark(primary: mainColor.value, onPrimary: Colors.black, surface: const Color(0xFF1E1E1E), onSurface: Colors.white), dialogBackgroundColor: const Color(0xFF1E1E1E)), child: child!); }); if (picked != null) { setState(() { selectedDate = picked; }); } }
  @override Widget build(BuildContext context) { super.build(context); List<dynamic> currentTasks = _getCurrentDayTasks(); bool isToday = DateFormat('yyyy-MM-dd').format(selectedDate) == DateFormat('yyyy-MM-dd').format(DateTime.now()); return Scaffold(appBar: AppBar(title: Text("TASKS", style: TextStyle(color: mainColor.value, fontWeight: FontWeight.bold, letterSpacing: 2.0)), centerTitle: true), body: Column(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0), color: const Color(0xFF111111), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [IconButton(icon: const Icon(Icons.arrow_back_ios, size: 18, color: Colors.grey), onPressed: () => _changeDate(-1)), GestureDetector(onTap: _pickDate, child: Row(children: [Icon(Icons.calendar_today, size: 16, color: mainColor.value), const SizedBox(width: 8), Text(isToday ? "TODAY" : DateFormat('EEE, dd MMM').format(selectedDate).toUpperCase(), style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 1.0))])), IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 18, color: Colors.grey), onPressed: () => _changeDate(1))])), Expanded(child: currentTasks.isEmpty ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.event_note, size: 60, color: Colors.grey.withOpacity(0.3)), const SizedBox(height: 10), Text("No tasks for ${DateFormat('dd MMM').format(selectedDate)}", style: TextStyle(color: Colors.grey.withOpacity(0.5), fontSize: 16))])) : ListView.builder(itemCount: currentTasks.length, padding: const EdgeInsets.all(15), itemBuilder: (context, index) { var task = currentTasks[index]; return Container(margin: const EdgeInsets.only(bottom: 15), decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(10), border: Border.all(color: task['isDone'] ? examColor.value.withOpacity(0.5) : mainColor.value.withOpacity(0.5))), child: ListTile(onTap: () => _toggleTask(index), leading: Icon(task['isDone'] ? Icons.check_circle : Icons.radio_button_unchecked, color: task['isDone'] ? examColor.value : mainColor.value), title: Text(task['title'], style: TextStyle(fontSize: 18, color: task['isDone'] ? Colors.grey : Colors.white, decoration: task['isDone'] ? TextDecoration.lineThrough : null, decorationColor: examColor.value, decorationThickness: 2)), trailing: IconButton(icon: const Icon(Icons.delete_outline, color: Colors.redAccent), onPressed: () => _deleteTask(index)))); }))],), floatingActionButton: FloatingActionButton(onPressed: () { playButtonFeedback(); _addNewTask(); }, backgroundColor: mainColor.value, child: const Icon(Icons.add, color: Colors.black))); }
}

// ================== 2. TIMER SCREEN (BUG FREE VERSION) ==================
class UniversalTimerScreen extends StatefulWidget {
  const UniversalTimerScreen({super.key});
  @override
  State<UniversalTimerScreen> createState() => _UniversalTimerScreenState();
}

class _UniversalTimerScreenState extends State<UniversalTimerScreen> with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  StreamSubscription? _subscription;

  @override bool get wantKeepAlive => true;

  int timerMode = 0;
  bool isStudyMode = true;
  bool isTimerRunning = false;
  List<String> studySubjects = ["Biology", "Physics", "Chemistry"];
  List<String> breakActivities = ["Gaming", "Social Media", "Rest"];
  String selectedSubject = "Biology";
  String lastStudySubject = "Biology";
  String lastBreakActivity = "Gaming";
  Map<String, int> subjectColors = {};
  Timer? _timer;

  DateTime? _targetEndTime;
  DateTime? _stopwatchStartTime;
  int _studyStopwatchTime = 0;
  int _studyAnchor = 0;
  int _breakAnchor = 0;
  int _breakStopwatchTime = 0;
  int _countdownRemaining = 25 * 60;
  int focusHours = 0;
  int focusMinutes = 25;
  int focusSeconds = 0;
  int breakHours = 0;
  int breakMinutes = 5;
  int breakSeconds = 0;
  int totalRounds = 4;
  int currentRound = 1;

  // 👇 FIX: initState ko replace karo
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();

    FlutterBackgroundService().on('action').listen((event) {
      if (event != null && event['type'] == 'pause') {
        if (isTimerRunning) _handlePause();
      }
      else if (event != null && event['type'] == 'resume') {
        if (!isTimerRunning) _handleResume();
      }
    });
    enableStickyNotification.addListener(() {
      if (mounted) {
        _updateNotification(silent: false); // Force update notification
      }
    });
  }

// 👇 FIX: Har 1 second pe data pakdega
  Future<void> _saveCurrentProgress() async {
    if (timerMode == 0) {
      // 1. Current Total Time Calculate karo
      int currentTotal = isStudyMode ? _studyStopwatchTime : _breakStopwatchTime;

      if (isTimerRunning && _stopwatchStartTime != null) {
        currentTotal += DateTime.now().difference(_stopwatchStartTime!).inSeconds;
      }

      // 2. Anchor (Pichla saved point) nikalo
      int anchor = isStudyMode ? _studyAnchor : _breakAnchor;

      // 3. Delta (Sirf naya time) nikalo
      int delta = currentTotal - anchor;

      // 4. Save Logic (Agar delta 1 ya usse zyada hai)
      if (delta >= 1) { // 👈 Yahan change kiya (Pehle > 2 tha)
        await _saveSession(delta, selectedSubject, isStudyMode);

        // Anchor Update karo
        if (isStudyMode) _studyAnchor = currentTotal;
        else _breakAnchor = currentTotal;
      }

      if (mounted) {
        setState(() {
          if (isStudyMode) _studyStopwatchTime = currentTotal;
          else _breakStopwatchTime = currentTotal;

          if (!isTimerRunning) _stopwatchStartTime = null;
          else _stopwatchStartTime = DateTime.now();
        });
      }
    }
  }

// 👇 FIX: Pause Logic Update
  void _handlePause() async {
    // 1. Pehle data save karo
    if (timerMode == 0) {
      await _saveCurrentProgress();

      // 2 Hour Alert Check
      int currentTotal = isStudyMode ? _studyStopwatchTime : _breakStopwatchTime;
      if (currentTotal >= 7200) {
        if (isStudyMode) {
          _showCompletionDialog(customTitle: "Great Job! 🎉", customMsg: "You studied for over 2 hours!");
        } else {
          _showCompletionDialog(customTitle: "Time to Focus! ⚠️", customMsg: "Break is over 2 hours. Let's go to study!");
        }
      }
    } else {
      // Pomodoro Logic
      if (_targetEndTime != null) {
        _countdownRemaining = _targetEndTime!.difference(DateTime.now()).inSeconds;
        if (_countdownRemaining < 0) _countdownRemaining = 0;
        _targetEndTime = null;
      }
    }

    if (mounted) {
      setState(() {
        isTimerRunning = false;
        _timer?.cancel();
      });
    }

    _updateNotification(silent: false, isTick: false);
  }

// 👇 FIX: Isme hum Service START kar rahe hain
  void _handleResume() async {
    // 1. Service ko start karo (Agar band hai to)
    var service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      service.startService();
    }

    setState(() {
      isTimerRunning = true;
      if (timerMode == 0) {
        _stopwatchStartTime = DateTime.now();
      } else {
        _targetEndTime =
            DateTime.now().add(Duration(seconds: _countdownRemaining));
      }
    });
    _startTimerLoop();
  }

  void _startStopTimer() {
    if (isTimerRunning)
      _handlePause();
    else
      _handleResume();
  }

  // 👇 TIMER LOOP
  void _startTimerLoop() {
    _timer?.cancel();
    _updateNotification(silent: false, isTick: false);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (timerMode != 0 && _targetEndTime != null) {
          _countdownRemaining =
              _targetEndTime!.difference(DateTime.now()).inSeconds;
          if (_countdownRemaining <= 0) {
            _countdownRemaining = 0;
            _timer?.cancel();
            cancelNotification();
            _handleTimerComplete();
          }
        }
      });
      _updateNotification(silent: true, isTick: true);
    });
  }

// 👇 FIX: Is function ko replace karo. Ye Zero wali problem jad se khatam karega.
  int _getCurrentSeconds() {
    if (timerMode == 0) {
      // Pehle variable me wo time lo jo save ho chuka hai
      int storedTime = isStudyMode ? _studyStopwatchTime : _breakStopwatchTime;

      // Agar timer chal raha hai, to (Abhi ka Time - Start Time) + Purana Saved Time
      if (isTimerRunning && _stopwatchStartTime != null) {
        return storedTime + DateTime
            .now()
            .difference(_stopwatchStartTime!)
            .inSeconds;
      }

      // Agar ruka hua hai, to sirf saved time dikhao
      return storedTime;
    } else {
      return _countdownRemaining;
    }
  }

  void _toggleSystemMode(int modeIndex) {
    if (isTimerRunning) _handlePause();
    cancelNotification();
    setState(() {
      timerMode = modeIndex;
      if (modeIndex == 2) {
        isStudyMode = true;
        if (studySubjects.contains(lastStudySubject))
          selectedSubject = lastStudySubject;
      }
      _resetTimerLogic(false);
    });
  }

// 👇 FIX: Switch Logic with Settings Check
  void _toggleStudyBreak(bool isStudy) async {
    // 1. Purana data save karo
    if (timerMode == 0) {
      await _saveCurrentProgress();
    } else {
      if (isTimerRunning) _handlePause();
    }

    cancelNotification();

    setState(() {
      isStudyMode = isStudy;

      // Subject Selection
      if (isStudy) {
        if (studySubjects.contains(lastStudySubject)) selectedSubject = lastStudySubject;
        else if (studySubjects.isNotEmpty) selectedSubject = studySubjects[0];
      } else {
        if (breakActivities.contains(lastBreakActivity)) selectedSubject = lastBreakActivity;
        else if (breakActivities.isNotEmpty) selectedSubject = breakActivities[0];
      }

      if (timerMode != 0) {
        _resetTimerLogic(false);
      } else {
        // === STUDYWATCH LOGIC ===

        // 👇 AGAR SETTING ON HAI, TABHI RESET KARO
        if (resetTimerOnSwitch.value) {
          _studyStopwatchTime = 0;
          _breakStopwatchTime = 0;
          _studyAnchor = 0; // Anchor bhi reset karna zaruri hai
          _breakAnchor = 0;
        }

        // Timer start karo (Continue karega agar setting OFF hai)
        _stopwatchStartTime = DateTime.now();
        isTimerRunning = true;
      }
    });

    if (timerMode == 0) {
      var service = FlutterBackgroundService();
      // Agar service band thi to chalu karo
      if (!await service.isRunning()) {
        await service.startService();
      }

      // 👇 YE LINE ADD KARO: Taki button dabte hi Icon badal jaye
      _updateNotification(silent: false);

      _startTimerLoop();
    }
  }

// 👇 FIX: Exam End Notification (Congratulations)
  void _handleTimerComplete() {
    int duration = isStudyMode ? (focusHours * 3600 + focusMinutes * 60 + focusSeconds) : (breakHours * 3600 + breakMinutes * 60 + breakSeconds);
    _saveSession(duration, selectedSubject, isStudyMode);

    if (timerMode == 1) { // POMODORO
      if (isStudyMode) {
        playGlobalSound(soundBreak.value);
        setState(() {
          isStudyMode = false;
          if (breakActivities.contains(lastBreakActivity)) selectedSubject = lastBreakActivity;
          _countdownRemaining = (breakHours * 3600 + breakMinutes * 60 + breakSeconds);
          isTimerRunning = false;
          _targetEndTime = null;
        });
        _handleResume();
      } else {
        if (currentRound < totalRounds) {
          playGlobalSound(soundAlarm.value);
          setState(() {
            currentRound++;
            isStudyMode = true;
            if (studySubjects.contains(lastStudySubject)) selectedSubject = lastStudySubject;
            _countdownRemaining = (focusHours * 3600 + focusMinutes * 60 + focusSeconds);
            isTimerRunning = false;
            _targetEndTime = null;
          });
          _handleResume();
        } else {
          playGlobalSound(soundDone.value);
          // Pomodoro Done Msg
          flutterLocalNotificationsPlugin.show(999, "Session Complete! 🎉", "Well done! All rounds finished.", const NotificationDetails(android: AndroidNotificationDetails('alert_channel', 'Alerts', importance: Importance.max, priority: Priority.high)));
          _fullReset();
          _showCompletionDialog();
        }
      }
    } else {
      // === EXAM MODE DONE ===
      playGlobalSound(soundDone.value);

      // 👇 FIX: Exam End Notification (Clean Look)
      flutterLocalNotificationsPlugin.show(
          889,
          "Congratulations! 🎓",
          "You have completed your exam: $selectedSubject",
          const NotificationDetails(
              android: AndroidNotificationDetails(
                'exam_alerts',
                'Exam Alerts',
                importance: Importance.max,
                priority: Priority.high,

                // ❌ largeIcon: ... <-- YE HATA DO

                icon: 'timer_icon', // Sirf ye rahega
                color: Color(0xFF00E5FF),
                colorized: true,
              )
          )
      );

      _fullReset(); // Ye service band karega, lekin upar wali notification rahegi
      _showCompletionDialog(customTitle: "Exam Finished!", customMsg: "Congratulations on completing your exam! 🎉");
    }
  }

  // 👇 FIX: Isme hum Service STOP kar rahe hain
  void _fullReset() {
    // Service ko bolo ki band ho jaye (Notification hata de)
    FlutterBackgroundService().invoke('stopService');

    setState(() {
      isTimerRunning = false;
      isStudyMode = true;

      // 👇 FIX: YE LINE ADD KARO (Round ko wapas 1 par laao)
      currentRound = 1;

      if (studySubjects.contains(lastStudySubject))
        selectedSubject = lastStudySubject;

      _resetTimerLogic(true);
    });
  }

  // 👇 FIX: Reset Logic
  void _resetTimerLogic(bool hardReset) {
    _timer?.cancel();
    _stopwatchStartTime = null;
    _targetEndTime = null;

    if (timerMode == 0) {
      if (hardReset) {
        _studyStopwatchTime = 0;
        _breakStopwatchTime = 0;
        _studyAnchor = 0; // Naye variables reset
        _breakAnchor = 0;
      }
    } else {
      if (isStudyMode) _countdownRemaining = (focusHours * 3600 + focusMinutes * 60 + focusSeconds);
      else _countdownRemaining = (breakHours * 3600 + breakMinutes * 60 + breakSeconds);
    }
  }

// 👇 FIX: Ab 1 second ka data bhi save hoga
  Future<void> _saveSession(int seconds, String subject, bool isStudy) async {
    // 1. Agar Pomodoro ka Break hai, to SAVE MAT KARO
    if (timerMode == 1 && !isStudy) {
      return;
    }

    // 2. Sirf 0 second wale ignore karo (1 sec allow hai)
    if (seconds < 1) return;

    final prefs = await SharedPreferences.getInstance();
    String sessionType = timerMode == 2 ? "EXAM" : (isStudy ? "STUDY" : "BREAK");
    if (timerMode == 2 && !subject.contains("(Exam)")) subject = "$subject (Exam)";

    Map<String, dynamic> session = {
      "date": DateFormat('yyyy-MM-dd').format(DateTime.now()),
      "time": seconds,
      "subject": subject,
      "type": sessionType
    };

    String historyString = prefs.getString('study_history') ?? "[]";
    List<dynamic> historyList = jsonDecode(historyString);
    historyList.add(session);

    await prefs.setString('study_history', jsonEncode(historyList));
    updateJsonFile(); // Backup file update
    print("SAVED: $subject - $seconds seconds");
  }

// 👇 FIX: Blue Background Hata Diya (Ab sirf Icon dikhega)
  // 👇 FIX: Dynamic Icon Logic Added
  void _updateNotification({bool silent = false, bool isTick = false}) {
    if (!isTimerRunning && silent) return;

    String status = "";
    if (timerMode == 0) {
      status = isStudyMode ? "Study" : "Not Study";
    } else if (timerMode == 2) {
      status = "Best of Luck! 🍀";
    } else {
      status = isStudyMode ? "Focus" : "Break";
    }

    String title = "";
    if (timerMode == 2) {
      title = "$status ($selectedSubject)";
    } else {
      title = "$status: $selectedSubject";
    }

    String timeText = timerMode == 0 ? "Time: ${_formatTime()}" : "Remaining: ${_formatTime()}";

    if (!isTimerRunning) {
      title = "Paused";
      timeText = "Tap Resume to continue";
    }

    // 👇 NEW: Icon Decide Karo
    // Agar Study Mode ya Exam hai to 'study' image, warna 'break' image
    String currentIcon = (isStudyMode || timerMode == 2) ? 'study' : 'break_icon';

    // Service Update Bhejo
    FlutterBackgroundService().invoke(
      'updateNotification',
      {
        'title': title,
        'body': timeText,
        'showPause': isTimerRunning,
        'largeIcon': currentIcon,

        // 👇 YE LINE HONI CHAHIYE (Value bhejni padegi)
        'isSticky': enableStickyNotification.value,
      },
    );
  }


  String _formatTime() {
    int totalSec = _getCurrentSeconds();
    int hr = totalSec ~/ 3600;
    int min = (totalSec % 3600) ~/ 60;
    int sec = totalSec % 60;
    return "${hr.toString().padLeft(2, '0')}:${min.toString().padLeft(
        2, '0')}:${sec.toString().padLeft(2, '0')}";
  }

  // 👇 Fix: super.build(context) added
  @override
  Widget build(BuildContext context) {
    super.build(context);
    Color primaryColor = (timerMode == 2 ? examColor.value : mainColor.value);
    Color secondaryColor = isStudyMode ? primaryColor : breakColor.value;
    bool isLandscape = MediaQuery
        .of(context)
        .orientation == Orientation.landscape;
    if (isLandscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    return Scaffold(backgroundColor: Colors.black,
        // Naya Code:
        // UniversalTimerScreen ke andar 'build' method mein

        appBar: isLandscape
            ? null
            : AppBar(
          title: Text("TIMER ZONE",
              style: TextStyle(
                  color: primaryColor,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2.0)),
          centerTitle: true,
          backgroundColor: Colors.black,
          actions: [
            // 👇 SIRF YE EK BUTTON RAHEGA (Time Change karne ke liye)
            if (timerMode != 0)
              IconButton(
                  onPressed: _openSettings, // Ye function Time Picker kholega
                  icon: const Icon(Icons.settings, color: Colors.grey)), // Wapas Gear Icon laga diya
          ],
        ),
        body: isLandscape
            ? _buildLandscapeLayout(primaryColor, secondaryColor)
            : Center(
            child: _buildPortraitLayout(primaryColor, secondaryColor)));
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        studySubjects = prefs.getStringList('study_subjects') ??
            ["Biology", "Physics", "Chemistry"];
        breakActivities = prefs.getStringList('break_activities') ??
            ["Gaming", "Social Media", "Rest"];
        String? colorString = prefs.getString('subject_colors');
        if (colorString != null) {
          subjectColors = Map<String, int>.from(jsonDecode(colorString));
        }
        if (studySubjects.isNotEmpty) lastStudySubject = studySubjects[0];
        if (breakActivities.isNotEmpty) lastBreakActivity = breakActivities[0];
        if (isStudyMode) {
          if (studySubjects.contains(lastStudySubject))
            selectedSubject = lastStudySubject;
          else if (studySubjects.isNotEmpty) selectedSubject = studySubjects[0];
        } else {
          if (breakActivities.contains(lastBreakActivity))
            selectedSubject = lastBreakActivity;
          else
          if (breakActivities.isNotEmpty) selectedSubject = breakActivities[0];
        }
      });
    }
  }

  Future<void> _saveSubjects() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setStringList('study_subjects', studySubjects);
    await prefs.setStringList('break_activities', breakActivities);
    await prefs.setString('subject_colors', jsonEncode(subjectColors));
    updateJsonFile();
  }

  void _manageSubjects() {
    showDialog(context: context, builder: (context) {
      return StatefulBuilder(builder: (context, setDialogState) {
        List<String> activeList = isStudyMode ? studySubjects : breakActivities;
        return AlertDialog(backgroundColor: const Color(0xFF1E1E1E),
            title: Text(
                "Manage List", style: TextStyle(color: mainColor.value)),
            content: SizedBox(width: double.maxFinite,
                height: 300,
                child: activeList.isEmpty
                    ? const Center(child: Text(
                    "Empty List", style: TextStyle(color: Colors.grey)))
                    : ListView.builder(itemCount: activeList.length,
                    itemBuilder: (context, index) {
                      String name = activeList[index];
                      Color itemColor = subjectColors.containsKey(name) ? Color(
                          subjectColors[name]!) : Colors.white;
                      return ListTile(leading: CircleAvatar(
                          backgroundColor: itemColor, radius: 6),
                          title: Text(name, style: TextStyle(
                              color: itemColor, fontWeight: FontWeight.bold)),
                          trailing: IconButton(icon: const Icon(
                              Icons.delete, color: Colors.redAccent),
                              onPressed: () {
                                setDialogState(() {
                                  setState(() {
                                    if (isStudyMode) {
                                      studySubjects.removeAt(index);
                                      if (selectedSubject == name &&
                                          studySubjects.isNotEmpty)
                                        selectedSubject = studySubjects[0];
                                    } else {
                                      breakActivities.removeAt(index);
                                      if (selectedSubject == name &&
                                          breakActivities.isNotEmpty)
                                        selectedSubject = breakActivities[0];
                                    }
                                  });
                                });
                                _saveSubjects();
                              }));
                    })),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context),
                  child: Text(
                      "CLOSE", style: TextStyle(color: mainColor.value)))
            ]);
      });
    });
  }

  void _addSubject() {
    TextEditingController ctrl = TextEditingController();
    Color pickerColor = mainColor.value;
    showDialog(context: context, builder: (context) {
      return StatefulBuilder(builder: (context, setDialogState) {
        return AlertDialog(scrollable: true,
            backgroundColor: const Color(0xFF1E1E1E),
            title: Text(isStudyMode ? "Add Subject" : "Add Activity",
                style: TextStyle(color: mainColor.value)),
            content: Column(mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: ctrl,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    cursorColor: mainColor.value,
                    decoration: InputDecoration(hintText: "Enter Name...",
                        hintStyle: const TextStyle(color: Colors.grey),
                        enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: mainColor.value)),
                        focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: mainColor.value,
                                width: 2)))),
                const SizedBox(height: 25),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Pick Color:",
                          style: TextStyle(color: Colors.grey, fontSize: 16)),
                      GestureDetector(onTap: () {
                        showDialog(context: context,
                            builder: (context) =>
                                AlertDialog(scrollable: true,
                                    backgroundColor: Colors.grey[900],
                                    title: const Text("Pick a Color",
                                        style: TextStyle(color: Colors.white)),
                                    content: SingleChildScrollView(
                                        child: ColorPicker(
                                            pickerColor: pickerColor,
                                            onColorChanged: (color) {
                                              pickerColor = color;
                                            },
                                            enableAlpha: false,
                                            displayThumbColor: true,
                                            paletteType: PaletteType.hsvWithHue,
                                            labelTypes: const [],
                                            pickerAreaHeightPercent: 0.7)),
                                    actions: [
                                      ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                              backgroundColor: mainColor.value),
                                          onPressed: () {
                                            setDialogState(() {});
                                            Navigator.of(context).pop();
                                          },
                                          child: const Text("SELECT",
                                              style: TextStyle(
                                                  color: Colors.black,
                                                  fontWeight: FontWeight.bold)))
                                    ]));
                      }, child: Container(padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(shape: BoxShape.circle,
                              border: Border.all(
                                  color: Colors.white, width: 1)),
                          child: CircleAvatar(backgroundColor: pickerColor,
                              radius: 18,
                              child: const Icon(
                                  Icons.edit, color: Colors.white, size: 16))))
                    ])
              ],),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context),
                  child: const Text(
                      "CANCEL", style: TextStyle(color: Colors.redAccent))),
              ElevatedButton(style: ElevatedButton.styleFrom(
                  backgroundColor: mainColor.value),
                  onPressed: () {
                    if (ctrl.text.isNotEmpty) {
                      setState(() {
                        if (isStudyMode) {
                          studySubjects.add(ctrl.text);
                          selectedSubject = ctrl.text;
                          lastStudySubject = ctrl.text;
                        } else {
                          breakActivities.add(ctrl.text);
                          selectedSubject = ctrl.text;
                          lastBreakActivity = ctrl.text;
                        }
                        subjectColors[ctrl.text] = pickerColor.value;
                      });
                      _saveSubjects();
                      Navigator.pop(context);
                    }
                  },
                  child: const Text("ADD", style: TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold)))
            ]);
      });
    });
  }

  void _openSettings() {
    int tempFocusH = focusHours;
    int tempFocusM = focusMinutes;
    int tempFocusS = focusSeconds;
    int tempBreakH = breakHours;
    int tempBreakM = breakMinutes;
    int tempBreakS = breakSeconds;
    int tempRounds = totalRounds;
    showModalBottomSheet(context: context,
        backgroundColor: const Color(0xFF121212),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (context) {
          return SizedBox(height: MediaQuery
              .of(context)
              .size
              .height * 0.7,
              child: Padding(padding: const EdgeInsets.all(20),
                  child: Column(children: [
                    Text(timerMode == 1
                        ? "POMODORO SETTINGS"
                        : "EXAM TIMER SETTINGS", style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                    const SizedBox(height: 20),
                    const Text(
                        "Focus Duration", style: TextStyle(color: Colors.grey)),
                    Expanded(child: Row(children: [
                      Expanded(child: _buildScrollWheel(
                          24, tempFocusH, (v) => tempFocusH = v)),
                      const Text(":"),
                      Expanded(child: _buildScrollWheel(
                          60, tempFocusM, (v) => tempFocusM = v)),
                      const Text(":"),
                      Expanded(child: _buildScrollWheel(
                          60, tempFocusS, (v) => tempFocusS = v))
                    ])),
                    if (timerMode == 1) ...[
                      const SizedBox(height: 10),
                      const Text("Break Duration",
                          style: TextStyle(color: Colors.grey)),
                      Expanded(child: Row(
                          children: [
                            Expanded(child: _buildScrollWheel(
                                24, tempBreakH, (v) => tempBreakH = v)),
                            const Text(":"),
                            Expanded(child: _buildScrollWheel(
                                60, tempBreakM, (v) => tempBreakM = v)),
                            const Text(":"),
                            Expanded(child: _buildScrollWheel(
                                60, tempBreakS, (v) => tempBreakS = v))
                          ])),
                      const SizedBox(height: 10),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                                "Rounds", style: TextStyle(color: Colors.grey)),
                            SizedBox(width: 80,
                                height: 80,
                                child: _buildScrollWheel(15, tempRounds, (v) =>
                                tempRounds = v, offset: 1))
                          ])
                    ],
                    SizedBox(width: double.infinity,
                        child: ElevatedButton(onPressed: () {
                          setState(() {
                            focusHours = tempFocusH;
                            focusMinutes = tempFocusM;
                            focusSeconds = tempFocusS;
                            breakHours = tempBreakH;
                            breakMinutes = tempBreakM;
                            breakSeconds = tempBreakS;
                            totalRounds = tempRounds;
                            _resetTimerLogic(true);
                          });
                          Navigator.pop(context);
                        },
                            style: ElevatedButton.styleFrom(
                                backgroundColor: timerMode == 2 ? examColor
                                    .value : mainColor.value),
                            child: const Text("SAVE", style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold))))
                  ])));
        });
  }

  Widget _buildScrollWheel(int count, int initialItem, Function(int) onChanged,
      {int offset = 0}) {
    Color wheelColor = (timerMode == 2 ? examColor.value : mainColor.value);
    return CupertinoPicker(scrollController: FixedExtentScrollController(
        initialItem: initialItem - offset),
        itemExtent: 32,
        onSelectedItemChanged: (i) => onChanged(i + offset),
        children: List.generate(count, (i) =>
            Center(child: Text('${i + offset}'.padLeft(2, '0'),
                style: TextStyle(color: wheelColor, fontSize: 20)))));
  }

  Widget _buildTypeBtn(String t, int modeIndex) {
    bool isActive = timerMode == modeIndex;
    Color activeColor = (modeIndex == 2 ? examColor.value : mainColor.value);
    return GestureDetector(onTap: () {
      playButtonFeedback();
      _toggleSystemMode(modeIndex);
    },
        child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            margin: EdgeInsets.zero,
            decoration: BoxDecoration(
                color: isActive ? activeColor : Colors.transparent,
                borderRadius: BorderRadius.circular(30)),
            child: Text(t, style: TextStyle(
                color: isActive ? Colors.black : Colors.grey,
                fontWeight: FontWeight.bold,
                fontSize: 12))));
  }

  Widget _buildMiniToggleBtn(IconData icon, String label, bool isStudyBtn,
      Color activeColor) {
    bool isActive = isStudyMode == isStudyBtn;
    return GestureDetector(onTap: () {
      playButtonFeedback();
      _toggleStudyBreak(isStudyBtn);
    },
        child: Column(children: [
          Container(padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: isActive ? activeColor : Colors.grey[900],
                  shape: BoxShape.circle,
                  border: isActive ? BoxBorder.lerp(null, null, 0) : Border.all(
                      color: Colors.grey.withOpacity(0.3))),
              child: Icon(icon, color: isActive ? Colors.black : Colors.grey,
                  size: 20)),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(
              color: isActive ? activeColor : Colors.grey,
              fontSize: 10,
              fontWeight: FontWeight.bold))
        ]));
  }

  Widget _buildLandscapeLayout(Color primaryColor, Color secondaryColor) {
    return Stack(children: [
      Row(crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 👇 CHANGE 1: 'flex' ko 2 se badha kar 3 kar diya (Zyada Jagah mili)
          Expanded(flex: 3,
              child: Container(
                alignment: Alignment.centerLeft, // Text ko Left side rakhenge
                // 👇 CHANGE 2: Sirf Left side se 40 ka gap diya (Right se nahi)
                padding: const EdgeInsets.only(left: 40.0),
                child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(_formatTime(), style: TextStyle(fontSize: 180, // Font size bhi thoda badha diya
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        fontFamily: 'monospace',
                        shadows: [
                          Shadow(color: secondaryColor.withOpacity(0.5),
                              blurRadius: 40)
                        ]))),
              )),

          // Controls Section (Iska size waisa hi rahega)
          Expanded(flex: 1,
              child: Container(color: Colors.transparent,
                  child: Column(mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 30),
                        Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Text(selectedSubject.toUpperCase(),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                style: TextStyle(color: secondaryColor,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.5))),
                        const SizedBox(height: 20),
                        GestureDetector(onTap: () {
                          playButtonFeedback();
                          _startStopTimer();
                        },
                            child: Icon(isTimerRunning
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill, color: secondaryColor,
                                size: 75)),
                        const SizedBox(height: 15),
                        if (timerMode != 2) Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildMiniToggleBtn(
                                  Icons.school, "Study", true, primaryColor),
                              const SizedBox(width: 20),
                              _buildMiniToggleBtn(Icons.coffee, "Break", false,
                                  breakColor.value)
                            ]),
                        const SizedBox(height: 10),
                        IconButton(onPressed: () {
                          _fullReset();
                        },
                            icon: const Icon(
                                Icons.refresh, color: Colors.grey, size: 26),
                            tooltip: "Reset")
                      ])))
        ],),

      // Top Mode Selector Buttons
      Positioned(top: 20,
          left: 225, // Isko bhi thoda shift kiya taaki aligned lage
          right: 150, // Right side se jagah chhodi taaki overlap na ho
          child: Align(
            alignment: Alignment.centerLeft, // Buttons ko bhi Left Align kiya
            child: Container(padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E).withOpacity(0.8),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: Colors.grey.withOpacity(0.3))),
                child: Row(mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTypeBtn("STUDYWATCH", 0),
                      _buildTypeBtn("POMODORO", 1),
                      _buildTypeBtn("EXAM", 2)
                    ])),
          ))
    ]);
  }

  Widget _buildPortraitLayout(Color primaryColor, Color secondaryColor) {
    return Column(children: [
      const SizedBox(height: 20),
      Container(padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.grey.withOpacity(0.3))),
          child: Row(mainAxisSize: MainAxisSize.min,
              children: [
                _buildTypeBtn("STUDYWATCH", 0),
                _buildTypeBtn("POMODORO", 1),
                _buildTypeBtn("EXAM", 2)
              ])),
      const SizedBox(height: 20),
      Row(mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ChoiceChip(label: Text(
                timerMode == 0 ? "STUDY" : (timerMode == 1 ? "FOCUS" : "EXAM")),
                selected: isStudyMode,
                selectedColor: primaryColor.withOpacity(0.2),
                labelStyle: TextStyle(
                    color: isStudyMode ? primaryColor : Colors.grey),
                onSelected: (v) => _toggleStudyBreak(true)),
            if (timerMode != 2) ...[
              const SizedBox(width: 15),
              ChoiceChip(label: Text(timerMode == 0 ? "NOT STUDY" : "BREAK"),
                  selected: !isStudyMode,
                  selectedColor: breakColor.value.withOpacity(0.2),
                  labelStyle: TextStyle(
                      color: !isStudyMode ? breakColor.value : Colors.grey),
                  onSelected: (v) => _toggleStudyBreak(false))
            ]
          ]),
      const SizedBox(height: 20),
      Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
          decoration: BoxDecoration(color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: secondaryColor.withOpacity(0.5))),
          child: Row(mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonHideUnderline(child: DropdownButton<String>(
                    value: (studySubjects.contains(selectedSubject) ||
                        breakActivities.contains(selectedSubject))
                        ? selectedSubject
                        : null,
                    dropdownColor: const Color(0xFF2C2C2C),
                    icon: Icon(Icons.arrow_drop_down, color: secondaryColor),
                    style: TextStyle(
                        color: subjectColors.containsKey(selectedSubject)
                            ? Color(subjectColors[selectedSubject]!)
                            : Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                    hint: const Text(
                        "Select...", style: TextStyle(color: Colors.grey)),
                    onChanged: (String? newValue) {
                      if (newValue != null) {
                        setState(() {
                          selectedSubject = newValue;
                          if (isStudyMode)
                            lastStudySubject = newValue;
                          else
                            lastBreakActivity = newValue;
                        });
                      }
                    },
                    items: (isStudyMode ? studySubjects : breakActivities).map<
                        DropdownMenuItem<String>>((String v) {
                      Color txtColor = subjectColors.containsKey(v) ? Color(
                          subjectColors[v]!) : Colors.white;
                      return DropdownMenuItem(
                          value: v, child: Text(v, style: TextStyle(
                          color: txtColor, fontWeight: FontWeight.bold)));
                    }).toList())),
                const SizedBox(width: 5),
                InkWell(onTap: _addSubject,
                    child: Icon(Icons.add_circle, color: secondaryColor)),
                const SizedBox(width: 10),
                InkWell(onTap: _manageSubjects,
                    child: const Icon(Icons.list, color: Colors.grey))
              ])),
      const Spacer(),
// 👇 FIX: Padding add ki
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5.0), // Left-Right se gap
        child: FittedBox(fit: BoxFit.scaleDown,
            child: Text(_formatTime(), style: TextStyle(fontSize: 100,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontFamily: 'monospace',
                shadows: [
                  Shadow(color: secondaryColor.withOpacity(0.5), blurRadius: 20)
                ]))),
      ),
      if (timerMode == 1) Padding(padding: const EdgeInsets.only(top: 10),
          child: Text("ROUND $currentRound / $totalRounds",
              style: const TextStyle(
                  color: Colors.grey, fontSize: 18, letterSpacing: 1.5))),
      const Spacer(),
      Row(mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(onPressed: () {
              _fullReset();
            }, icon: const Icon(Icons.refresh, color: Colors.grey, size: 40)),
            const SizedBox(width: 30),
            GestureDetector(onTap: () {
              playButtonFeedback();
              _startStopTimer();
            },
                child: Container(height: 90,
                    width: 90,
                    decoration: BoxDecoration(color: secondaryColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: secondaryColor.withOpacity(0.5),
                              blurRadius: 20)
                        ]),
                    child: Icon(isTimerRunning ? Icons.pause : Icons.play_arrow,
                        color: Colors.black, size: 50))),
            const SizedBox(width: 70)
          ]),
      const SizedBox(height: 50)
    ]);
  }

  // 👇 FIX: Custom Message Support
  void _showCompletionDialog({String? customTitle, String? customMsg}) {
    showDialog(context: context, builder: (context) {
      return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15),
              side: BorderSide(color: mainColor.value, width: 2)),

          title: Row(children: [
            Icon(Icons.emoji_events, color: mainColor.value),
            const SizedBox(width: 10),
            Expanded(child: Text(customTitle ?? "Done!", style: TextStyle(
                color: mainColor.value,
                fontWeight: FontWeight.bold,
                fontSize: 18)))
          ]),

          content: Text(customMsg ?? "Target Achieved! Data saved.",
              style: const TextStyle(color: Colors.white70)),

          actions: [
            TextButton(onPressed: () => Navigator.pop(context),
                child: const Text(
                    "CLOSE", style: TextStyle(color: Colors.grey))),

            if(customTitle == null) // Sirf timer khatam hone par Restart dikhao
              ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _handleResume();
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: mainColor.value),
                  child: const Text("RESTART", style: TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold))
              )
          ]
      );
    });
  }
}

// ================== 3. STATISTICS SCREEN ==================
class StatisticsScreen extends StatefulWidget { const StatisticsScreen({super.key}); @override State<StatisticsScreen> createState() => _StatisticsScreenState(); }
class _StatisticsScreenState extends State<StatisticsScreen> {
  List<Map<String, dynamic>> historyLog = []; String trendViewMode = "Weekly"; String timeUnit = "Min"; String activeFilter = "All"; String streakViewMode = "Weekly"; int maxDailyStudySeconds = 1; String currentChartType = "Line"; Map<String, int> subjectColors = {}; DateTime focusedDate = DateTime.now(); String compareMode = "Day"; String compareChartType = "Bar"; DateTime? compareDate1; DateTime? compareDate2; DateTime selectedChartDate = DateTime.now(); int touchedIndex = -1;
  Color _getColorForSubject(String subject) { if (subjectColors.containsKey(subject)) { return Color(subjectColors[subject]!); } return Colors.primaries[subject.length % Colors.primaries.length]; }
  @override void initState() { super.initState(); _loadData(); }
  Future<void> _loadData() async { final prefs = await SharedPreferences.getInstance(); String? historyString = prefs.getString('study_history'); if (historyString != null) { List<dynamic> loaded = jsonDecode(historyString); if (mounted) { setState(() { historyLog = List<Map<String, dynamic>>.from(loaded); _calculateMaxDailyStudy(); String? colorString = prefs.getString('subject_colors'); if (colorString != null) { subjectColors = Map<String, int>.from(jsonDecode(colorString)); } }); } } }
  void _calculateMaxDailyStudy() { Map<String, int> dailyTotals = {}; for (var session in historyLog) { if (session['type'] == 'STUDY') { String date = session['date']; dailyTotals[date] = (dailyTotals[date] ?? 0) + (session['time'] as int); } } if (dailyTotals.isNotEmpty) { maxDailyStudySeconds = dailyTotals.values.reduce((a, b) => a > b ? a : b); } }
  Set<String> _getStudyDates() { Set<String> studyDates = {}; for (var session in historyLog) { if (session['type'] == 'STUDY' && (session['time'] as int) > 0) { studyDates.add(session['date']); } } return studyDates; }
  Color _getIntensityColor(int seconds) { if (seconds == 0) return Colors.grey[900]!; double intensity = (seconds / maxDailyStudySeconds).clamp(0.0, 1.0); if (intensity < 0.3) intensity = 0.3; return Colors.orangeAccent.withOpacity(intensity); }
  double _convertTime(int seconds) { if (timeUnit == "Sec") return seconds.toDouble(); if (timeUnit == "Min") return seconds / 60; if (timeUnit == "Hr") return seconds / 3600; return seconds / 60; }
  String _formatYAxis(double value) { if (value % 1 == 0) return value.toInt().toString(); return value.toStringAsFixed(1); }
  int _getDailyStudySeconds(DateTime date) { String dateStr = DateFormat('yyyy-MM-dd').format(date); int total = 0; for (var session in historyLog) { if (session['date'] == dateStr && session['type'] == 'STUDY') { total += (session['time'] as int); } } return total; }
  int _getMonthStudySeconds(DateTime date) { int total = 0; for (var session in historyLog) { if (session['type'] == 'STUDY') { DateTime sDate = DateTime.parse(session['date']); if (sDate.year == date.year && sDate.month == date.month) { total += (session['time'] as int); } } } return total; }
  Future<void> _pickDate(bool isFirst) async { DateTime? picked = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now(), builder: (context, child) { return Theme(data: ThemeData.dark().copyWith(colorScheme: ColorScheme.dark(primary: mainColor.value, onPrimary: Colors.black)), child: child!); }); if (picked != null) { setState(() { if (isFirst) compareDate1 = picked; else compareDate2 = picked; }); } }
  Widget _buildStreakVisualizer() { DateTime now = DateTime.now(); DateFormat dayFormat = DateFormat('E');
  if (streakViewMode == "Weekly") { int currentWeekday = now.weekday; DateTime startOfWeek = now.subtract(Duration(days: currentWeekday - 1)); return Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: List.generate(7, (index) { DateTime day = startOfWeek.add(Duration(days: index)); int seconds = _getDailyStudySeconds(day); bool isSelected = DateFormat('yyyy-MM-dd').format(day) == DateFormat('yyyy-MM-dd').format(selectedChartDate); bool isToday = DateFormat('yyyy-MM-dd').format(day) == DateFormat('yyyy-MM-dd').format(now); return GestureDetector(onTap: () { setState(() { selectedChartDate = day; }); }, child: Column(children: [Text(dayFormat.format(day)[0], style: TextStyle(color: isSelected ? examColor.value : (isToday ? mainColor.value : Colors.grey), fontWeight: FontWeight.bold)), const SizedBox(height: 5), Container(decoration: BoxDecoration(border: isSelected ? Border.all(color: Colors.white, width: 1.5) : null, shape: BoxShape.circle), child: Icon(seconds > 0 ? Icons.local_fire_department : Icons.circle_outlined, color: _getIntensityColor(seconds).withOpacity(seconds > 0 ? 1 : 0.2), size: 30))])); })); }
  else if (streakViewMode == "Monthly") { int daysInMonth = DateTime(focusedDate.year, focusedDate.month + 1, 0).day; Widget header = Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [IconButton(icon: Icon(Icons.arrow_back_ios, size: 16, color: mainColor.value), onPressed: () => setState(() => focusedDate = DateTime(focusedDate.year, focusedDate.month - 1))), Text(DateFormat('MMMM yyyy').format(focusedDate).toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5)), IconButton(icon: Icon(Icons.arrow_forward_ios, size: 16, color: mainColor.value), onPressed: () => setState(() => focusedDate = DateTime(focusedDate.year, focusedDate.month + 1)))]); return Column(children: [header, const SizedBox(height: 10), Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: List.generate(daysInMonth, (index) { DateTime day = DateTime(focusedDate.year, focusedDate.month, index + 1); int seconds = _getDailyStudySeconds(day); bool isSelected = DateFormat('yyyy-MM-dd').format(day) == DateFormat('yyyy-MM-dd').format(selectedChartDate); return GestureDetector(onTap: () { setState(() { selectedChartDate = day; }); }, child: Container(width: 28, height: 27, alignment: Alignment.center, decoration: BoxDecoration(color: seconds > 0 ? _getIntensityColor(seconds) : Colors.transparent, shape: BoxShape.rectangle, borderRadius: BorderRadius.circular(8), border: Border.all(color: isSelected ? Colors.white : (seconds > 0 ? Colors.transparent : Colors.grey[800]!), width: isSelected ? 1.5 : 1)), child: Text("${index + 1}", style: TextStyle(color: seconds > 0 ? Colors.black : (isSelected ? Colors.white : Colors.grey), fontSize: 10, fontWeight: FontWeight.bold)))); }))]); }
  else { return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text("LAST 365 DAYS", style: TextStyle(color: Colors.grey, fontSize: 10)), const SizedBox(height: 10), GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: 365, gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 20, crossAxisSpacing: 3, mainAxisSpacing: 3, childAspectRatio: 1.0), itemBuilder: (context, index) { DateTime day = now.subtract(Duration(days: 364 - index)); int seconds = _getDailyStudySeconds(day); return Tooltip(message: "${DateFormat('MMM d').format(day)}: ${seconds ~/ 60} min", child: Container(decoration: BoxDecoration(color: _getIntensityColor(seconds), borderRadius: BorderRadius.circular(2)))); })]); }
  }
  List<Map<String, dynamic>> _getTodayDataList() { Map<String, int> aggregated = {}; Map<String, String> subTypes = {}; String targetDateStr = DateFormat('yyyy-MM-dd').format(selectedChartDate); for (var session in historyLog) { if (session['date'] == targetDateStr) { bool include = false; if (activeFilter == "All") include = true; else if (activeFilter == "Study" && session['type'] == "STUDY") include = true; else if (activeFilter == "Break" && session['type'] == "BREAK") include = true; else if (activeFilter == "Exam" && session['type'] == "EXAM") include = true; if (include) { String sub = session['subject']; aggregated[sub] = (aggregated[sub] ?? 0) + (session['time'] as int); subTypes[sub] = session['type']; } } } List<Map<String, dynamic>> result = []; aggregated.forEach((key, value) { result.add({"subject": key, "time": _convertTime(value), "type": subTypes[key]}); }); return result; }
  Map<String, dynamic> _getTrendData() { List<FlSpot> studySpots = []; List<FlSpot> breakSpots = []; List<FlSpot> examSpots = []; List<String> xLabels = []; DateTime now = DateTime.now(); DateFormat formatter = DateFormat('yyyy-MM-dd'); int daysCount = (trendViewMode == "Monthly") ? 30 : (trendViewMode == "Yearly" ? 12 : 7); if (trendViewMode == "Yearly") { for (int i = 11; i >= 0; i--) { DateTime targetMonth = DateTime(now.year, now.month - i, 1); xLabels.add(DateFormat('MMM').format(targetMonth)); double studySec = 0; double breakSec = 0; double examSec = 0; for (var session in historyLog) { DateTime sDate = DateTime.parse(session['date']); if (sDate.year == targetMonth.year && sDate.month == targetMonth.month) { if (session['type'] == 'EXAM') examSec += (session['time'] as int); else if (session['type'] == 'STUDY') studySec += (session['time'] as int); else breakSec += (session['time'] as int); } } studySpots.add(FlSpot((11-i).toDouble(), _convertTime(studySec.toInt()))); breakSpots.add(FlSpot((11-i).toDouble(), _convertTime(breakSec.toInt()))); examSpots.add(FlSpot((11-i).toDouble(), _convertTime(examSec.toInt()))); } } else { for (int i = daysCount - 1; i >= 0; i--) { DateTime targetDate = now.subtract(Duration(days: i)); String dateStr = formatter.format(targetDate); if (trendViewMode == "Weekly") xLabels.add(DateFormat('E').format(targetDate)); else xLabels.add(DateFormat('d').format(targetDate)); double studySec = 0; double breakSec = 0; double examSec = 0; for (var session in historyLog) { if (session['date'] == dateStr) { if (session['type'] == 'EXAM') examSec += (session['time'] as int); else if (session['type'] == 'STUDY') studySec += (session['time'] as int); else breakSec += (session['time'] as int); } } studySpots.add(FlSpot((daysCount - 1 - i).toDouble(), _convertTime(studySec.toInt()))); breakSpots.add(FlSpot((daysCount - 1 - i).toDouble(), _convertTime(breakSec.toInt()))); examSpots.add(FlSpot((daysCount - 1 - i).toDouble(), _convertTime(examSec.toInt()))); } } return {"study": studySpots, "break": breakSpots, "exam": examSpots, "labels": xLabels}; }
  Widget _buildFilterBtn(String label, Color color) { bool isSelected = activeFilter == label; return GestureDetector(onTap: () { setState(() { activeFilter = label; }); }, child: AnimatedContainer(duration: const Duration(milliseconds: 200), padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), decoration: BoxDecoration(color: isSelected ? color.withOpacity(0.2) : Colors.transparent, borderRadius: BorderRadius.circular(20), border: Border.all(color: isSelected ? color : Colors.grey.withOpacity(0.3), width: 1.5), boxShadow: isSelected ? [BoxShadow(color: color.withOpacity(0.2), blurRadius: 8)] : []), child: Text(label, style: TextStyle(color: isSelected ? color : Colors.grey, fontWeight: FontWeight.bold)))); }
  Widget _buildUnitDropdown(String value, Function(String) onChanged, List<String> items) { return Container(height: 30, padding: const EdgeInsets.symmetric(horizontal: 8), decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(8), border: Border.all(color: mainColor.value.withOpacity(0.3))), child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: value, dropdownColor: Colors.grey[900], icon: Icon(Icons.arrow_drop_down, color: mainColor.value, size: 18), style: TextStyle(color: mainColor.value, fontSize: 12, fontWeight: FontWeight.bold), items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(), onChanged: (val) => onChanged(val!)))); }
  @override Widget build(BuildContext context) { List<Map<String, dynamic>> todayDataList = _getTodayDataList(); Map<String, dynamic> trendData = _getTrendData(); List<FlSpot> trendExamSpots = List<FlSpot>.from(trendData['exam']); List<FlSpot> todayStudySpots = []; List<FlSpot> todayBreakSpots = []; List<FlSpot> todayExamSpots = []; List<String> topLabels = []; for(int i=0; i<todayDataList.length; i++) { String subj = todayDataList[i]['subject']; double val = todayDataList[i]['time'] as double; String type = todayDataList[i]['type']; topLabels.add(subj); if (type == 'EXAM') { todayExamSpots.add(FlSpot(i.toDouble(), val)); todayStudySpots.add(FlSpot(i.toDouble(), 0)); todayBreakSpots.add(FlSpot(i.toDouble(), 0)); } else if (type == 'STUDY') { todayStudySpots.add(FlSpot(i.toDouble(), val)); todayExamSpots.add(FlSpot(i.toDouble(), 0)); todayBreakSpots.add(FlSpot(i.toDouble(), 0)); } else { todayBreakSpots.add(FlSpot(i.toDouble(), val)); todayStudySpots.add(FlSpot(i.toDouble(), 0)); todayExamSpots.add(FlSpot(i.toDouble(), 0)); } } double maxVal = todayDataList.isEmpty ? 0 : todayDataList.map((e) => e['time'] as double).reduce((a,b) => a>b?a:b); double maxYTop = (maxVal == 0 ? 5 : maxVal) * 1.2; double intervalTop = maxYTop < 10 ? 1 : maxYTop / 5; int currentStreak = 0; Set<String> studyDates = _getStudyDates(); DateTime checkDate = DateTime.now(); DateFormat formatter = DateFormat('yyyy-MM-dd'); if (studyDates.contains(formatter.format(checkDate))) currentStreak++; while (true) { checkDate = checkDate.subtract(const Duration(days: 1)); if (studyDates.contains(formatter.format(checkDate))) currentStreak++; else break; }
  return Scaffold(backgroundColor: Colors.black, appBar: AppBar(title: Text("ANALYTICS", style: TextStyle(color: mainColor.value, fontWeight: FontWeight.bold, letterSpacing: 2.0)), centerTitle: true, backgroundColor: Colors.black, actions: [IconButton(icon: Icon(Icons.refresh, color: mainColor.value), onPressed: _loadData)]), body: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Row(children: [const Icon(Icons.local_fire_department, color: Colors.orangeAccent), const SizedBox(width: 5), Text("STREAK: $currentStreak Days", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))]), _buildUnitDropdown(streakViewMode, (val) { setState(() { streakViewMode = val; }); }, ["Weekly", "Monthly", "Yearly"])]), const SizedBox(height: 15), Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.orangeAccent.withOpacity(0.3))), child: _buildStreakVisualizer()), const SizedBox(height: 30), Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [_buildFilterBtn("All", Colors.white), _buildFilterBtn("Study", mainColor.value), _buildFilterBtn("Break", breakColor.value), _buildFilterBtn("Exam", examColor.value)]), const SizedBox(height: 30), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Row(children: [Text(DateFormat('yyyy-MM-dd').format(selectedChartDate) == DateFormat('yyyy-MM-dd').format(DateTime.now()) ? "TODAY:" : "${DateFormat('dd MMM').format(selectedChartDate).toUpperCase()}:", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)), const SizedBox(width: 10), _buildUnitDropdown(currentChartType, (val) { setState(() { currentChartType = val; }); }, ["Line", "Bar", "Pie"])]), _buildUnitDropdown(timeUnit, (val) { setState(() { timeUnit = val; }); }, ["Sec", "Min", "Hr"])]), const SizedBox(height: 10), Container(height: 300, padding: const EdgeInsets.fromLTRB(10, 25, 20, 10), decoration: BoxDecoration(color: const Color(0xFF050505), borderRadius: BorderRadius.circular(15)), child: topLabels.isEmpty ? const Center(child: Text("No Data for selected filter.", style: TextStyle(color: Colors.grey))) : _buildDynamicChart(todayDataList, todayStudySpots, todayBreakSpots, todayExamSpots, maxYTop, intervalTop, topLabels)), const SizedBox(height: 30), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("HISTORY TREND", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)), _buildUnitDropdown(trendViewMode, (val) { setState(() { trendViewMode = val; }); }, ["Weekly", "Monthly", "Yearly"])]), const SizedBox(height: 10), Container(height: 300, padding: const EdgeInsets.fromLTRB(10, 20, 20, 10), decoration: BoxDecoration(color: const Color(0xFF050505), borderRadius: BorderRadius.circular(15)), child: LineChart(LineChartData(clipData: const FlClipData.none(), gridData: FlGridData(show: true, drawVerticalLine: false, getDrawingHorizontalLine: (value) => const FlLine(color: Colors.white10, strokeWidth: 1)), titlesData: FlTitlesData(show: true, topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, interval: (trendData['study'] as List).isEmpty ? 1 : null, getTitlesWidget: (v, m) => Text(_formatYAxis(v), style: const TextStyle(color: Colors.grey, fontSize: 10)))), bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, interval: 1, getTitlesWidget: (value, meta) { List<String> labels = trendData['labels'] as List<String>; int index = value.toInt(); if (trendViewMode == "Monthly" && index % 5 != 0) return const Text(""); if(index >= 0 && index < labels.length) return Padding(padding: const EdgeInsets.only(top: 8.0), child: Text(labels[index], style: const TextStyle(color: Colors.white, fontSize: 10))); return const Text(""); }))), borderData: FlBorderData(show: false), minY: 0, lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(getTooltipColor: (_) => Colors.grey[900]!, getTooltipItems: (touchedSpots) { return touchedSpots.map((spot) { return LineTooltipItem("${spot.y.toStringAsFixed(1)} $timeUnit", TextStyle(color: spot.bar.color ?? Colors.white, fontWeight: FontWeight.bold)); }).toList(); })), lineBarsData: _buildTrendLines(trendData)))), const SizedBox(height: 30), const Text("COMPARE PERFORMANCE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)), const SizedBox(height: 15), _buildComparisonChart(), const SizedBox(height: 50)])));
  }
  List<LineChartBarData> _buildTrendLines(Map<String, dynamic> trendData) { List<LineChartBarData> lines = []; if (activeFilter == "All" || activeFilter == "Break") { lines.add(LineChartBarData(spots: trendData['break'] as List<FlSpot>, isCurved: true, color: breakColor.value, barWidth: 3, dotData: FlDotData(show: true, getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(radius: 3, color: Colors.black, strokeWidth: 2, strokeColor: breakColor.value)), belowBarData: BarAreaData(show: true, color: breakColor.value.withOpacity(0.1)))); } if (activeFilter == "All" || activeFilter == "Exam") { lines.add(LineChartBarData(spots: trendData['exam'] as List<FlSpot>, isCurved: true, color: examColor.value, barWidth: 3, dotData: FlDotData(show: true, getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(radius: 3, color: Colors.black, strokeWidth: 2, strokeColor: examColor.value)), belowBarData: BarAreaData(show: true, color: examColor.value.withOpacity(0.1)))); } if (activeFilter == "All" || activeFilter == "Study") { lines.add(LineChartBarData(spots: trendData['study'] as List<FlSpot>, isCurved: true, color: mainColor.value, barWidth: 3, dotData: FlDotData(show: true, getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(radius: 3, color: Colors.black, strokeWidth: 2, strokeColor: mainColor.value)), belowBarData: BarAreaData(show: true, gradient: LinearGradient(colors: [mainColor.value.withOpacity(0.4), mainColor.value.withOpacity(0.0)], begin: Alignment.topCenter, end: Alignment.bottomCenter)))); } return lines; }
  Widget _buildDynamicChart(List<Map<String, dynamic>> data, List<FlSpot> study, List<FlSpot> breakS, List<FlSpot> examS, double maxY, double interval, List<String> labels) { Color getSubjectColor(String subject, String type) { if (subjectColors.containsKey(subject)) { return Color(subjectColors[subject]!); } if (type == 'EXAM') return examColor.value; if (type == 'BREAK') return breakColor.value; return _getColorForSubject(subject); } Widget getBottomLabel(double value, TitleMeta meta) { int index = value.toInt(); if (index >= 0 && index < labels.length) { String text = labels[index]; if (text.contains(" ")) text = text.replaceAll(" ", "\n"); return SideTitleWidget(axisSide: meta.axisSide, space: 4, child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold), maxLines: 2, overflow: TextOverflow.ellipsis)); } return const Text(""); } if (currentChartType == "Pie") { return PieChart(PieChartData(pieTouchData: PieTouchData(touchCallback: (FlTouchEvent event, pieTouchResponse) { setState(() { if (!event.isInterestedForInteractions || pieTouchResponse == null || pieTouchResponse.touchedSection == null) { touchedIndex = -1; return; } touchedIndex = pieTouchResponse.touchedSection!.touchedSectionIndex; }); }), sectionsSpace: 2, centerSpaceRadius: 40, sections: data.asMap().entries.map((entry) { int idx = entry.key; Map item = entry.value; final double value = item['time']; final String subject = item['subject']; Color sectColor = getSubjectColor(subject, item['type']); final isTouched = idx == touchedIndex; final double radius = isTouched ? 70.0 : 60.0; final double fontSize = isTouched ? 14.0 : 10.0; return PieChartSectionData(color: sectColor, value: value, title: '${value.toStringAsFixed(1)}\n${timeUnit}', radius: radius, titleStyle: TextStyle(fontSize: fontSize, fontWeight: FontWeight.bold, color: Colors.white), badgeWidget: isTouched ? Container(padding: const EdgeInsets.all(6), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(5)), child: Text(subject, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 10))) : null, badgePositionPercentageOffset: 1.3); }).toList()), swapAnimationDuration: const Duration(milliseconds: 300), swapAnimationCurve: Curves.easeInOutBack); } if (currentChartType == "Bar") { return BarChart(BarChartData(barTouchData: BarTouchData(touchCallback: (FlTouchEvent event, barTouchResponse) { setState(() { if (!event.isInterestedForInteractions || barTouchResponse == null || barTouchResponse.spot == null) { touchedIndex = -1; return; } touchedIndex = barTouchResponse.spot!.touchedBarGroupIndex; }); }, touchTooltipData: BarTouchTooltipData(getTooltipColor: (_) => Colors.grey[900]!, getTooltipItem: (group, groupIndex, rod, rodIndex) { String subject = data[group.x.toInt()]['subject']; return BarTooltipItem("$subject\n", TextStyle(color: rod.color, fontWeight: FontWeight.bold), children: [TextSpan(text: "${rod.toY.toStringAsFixed(1)} $timeUnit", style: const TextStyle(color: Colors.white))]); })), gridData: FlGridData(show: false), titlesData: FlTitlesData(leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, getTitlesWidget: (v, m) => Text(_formatYAxis(v), style: const TextStyle(color: Colors.grey, fontSize: 10)))), rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, getTitlesWidget: getBottomLabel))), borderData: FlBorderData(show: false), barGroups: data.asMap().entries.map((entry) { int idx = entry.key; Map item = entry.value; Color barColor = getSubjectColor(item['subject'], item['type']); bool isTouched = idx == touchedIndex; Color finalColor = isTouched ? Colors.white : barColor; double width = isTouched ? 28 : 20; return BarChartGroupData(x: idx, barRods: [BarChartRodData(toY: item['time'], color: finalColor, width: width, borderRadius: BorderRadius.circular(4), backDrawRodData: BackgroundBarChartRodData(show: true, toY: maxY, color: Colors.grey[900]))]); }).toList())); } return LineChart(LineChartData(clipData: const FlClipData.none(), gridData: FlGridData(show: true, drawVerticalLine: false, getDrawingHorizontalLine: (value) => const FlLine(color: Colors.white10, strokeWidth: 1)), titlesData: FlTitlesData(show: true, topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, interval: interval, getTitlesWidget: (v, m) => Text(_formatYAxis(v), style: const TextStyle(color: Colors.grey, fontSize: 10)))), bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, interval: 1, getTitlesWidget: getBottomLabel))), borderData: FlBorderData(show: false), minY: 0, maxY: maxY, lineTouchData: LineTouchData(touchCallback: (FlTouchEvent event, LineTouchResponse? lineTouch) { setState(() { if (!event.isInterestedForInteractions || lineTouch == null || lineTouch.lineBarSpots == null) { touchedIndex = -1; return; } touchedIndex = lineTouch.lineBarSpots![0].spotIndex; }); }, touchTooltipData: LineTouchTooltipData(getTooltipColor: (_) => Colors.grey[900]!, getTooltipItems: (touchedSpots) { return touchedSpots.map((spot) { if(spot.y == 0) return null; int index = spot.x.toInt(); String subjectName = data[index]['subject']; return LineTooltipItem("$subjectName\n", TextStyle(color: spot.bar.color, fontWeight: FontWeight.bold), children: [TextSpan(text: "${spot.y.toStringAsFixed(1)} $timeUnit", style: const TextStyle(color: Colors.white))]); }).toList(); })), lineBarsData: [if (activeFilter == "All" || activeFilter == "Study") LineChartBarData(spots: study, isCurved: true, color: mainColor.value, barWidth: 3, belowBarData: BarAreaData(show: true, gradient: LinearGradient(colors: [mainColor.value.withOpacity(0.4), mainColor.value.withOpacity(0.0)], begin: Alignment.topCenter, end: Alignment.bottomCenter)), dotData: FlDotData(show: true, getDotPainter: (spot, percent, barData, index) { bool isTouched = index == touchedIndex; return FlDotCirclePainter(radius: isTouched ? 8 : 4, color: mainColor.value, strokeWidth: 0); })), if (activeFilter == "All" || activeFilter == "Exam") LineChartBarData(spots: examS, isCurved: true, color: examColor.value, barWidth: 3, belowBarData: BarAreaData(show: true, color: examColor.value.withOpacity(0.1)), dotData: FlDotData(show: true, getDotPainter: (spot, percent, barData, index) { bool isTouched = index == touchedIndex; return FlDotCirclePainter(radius: isTouched ? 8 : 4, color: examColor.value, strokeWidth: 0); })), if (activeFilter == "All" || activeFilter == "Break") LineChartBarData(spots: breakS, isCurved: true, color: breakColor.value, barWidth: 3, belowBarData: BarAreaData(show: true, color: breakColor.value.withOpacity(0.1)), dotData: FlDotData(show: true, getDotPainter: (spot, percent, barData, index) { bool isTouched = index == touchedIndex; return FlDotCirclePainter(radius: isTouched ? 8 : 4, color: breakColor.value, strokeWidth: 0); }))])); }
  Widget _buildComparisonChart() { double val1 = 0; double val2 = 0; String label1 = "Date A"; String label2 = "Date B"; if (compareDate1 != null) { if (compareMode == "Day") { val1 = _convertTime(_getDailyStudySeconds(compareDate1!)); label1 = DateFormat('dd MMM').format(compareDate1!); } else { val1 = _convertTime(_getMonthStudySeconds(compareDate1!)); label1 = DateFormat('MMM yy').format(compareDate1!); } } if (compareDate2 != null) { if (compareMode == "Day") { val2 = _convertTime(_getDailyStudySeconds(compareDate2!)); label2 = DateFormat('dd MMM').format(compareDate2!); } else { val2 = _convertTime(_getMonthStudySeconds(compareDate2!)); label2 = DateFormat('MMM yy').format(compareDate2!); } } double maxY = (val1 > val2 ? val1 : val2); if (maxY == 0) maxY = 10; maxY *= 1.2; return Column(children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [_buildUnitDropdown(compareChartType, (v) { setState(() { compareChartType = v; }); }, ["Bar", "Line", "Pie"]), _buildUnitDropdown(compareMode, (v) { setState(() { compareMode = v; compareDate1 = null; compareDate2 = null; }); }, ["Day", "Month"])]), const SizedBox(height: 10), Row(children: [Expanded(child: ElevatedButton(onPressed: () => _pickDate(true), style: ElevatedButton.styleFrom(backgroundColor: mainColor.value.withOpacity(0.1), padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: mainColor.value, width: 1))), child: Text(compareDate1 == null ? "Select 1" : DateFormat(compareMode == "Day" ? 'dd/MM' : 'MMM yy').format(compareDate1!), style: TextStyle(color: mainColor.value, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis))), const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text("VS", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))), Expanded(child: ElevatedButton(onPressed: () => _pickDate(false), style: ElevatedButton.styleFrom(backgroundColor: breakColor.value.withOpacity(0.1), padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: breakColor.value, width: 1))), child: Text(compareDate2 == null ? "Select 2" : DateFormat(compareMode == "Day" ? 'dd/MM' : 'MMM yy').format(compareDate2!), style: TextStyle(color: breakColor.value, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)))]), const SizedBox(height: 20), Container(height: 250, padding: const EdgeInsets.fromLTRB(10, 20, 20, 10), decoration: BoxDecoration(color: const Color(0xFF050505), borderRadius: BorderRadius.circular(15)), child: _buildCompareChartContent(val1, val2, maxY, label1, label2))]); }
  Widget _buildCompareChartContent(double val1, double val2, double maxY, String label1, String label2) { Widget getCompareLabel(double value, TitleMeta meta) { String text = ""; if (value.toInt() == 0) text = label1; else if (value.toInt() == 1) text = label2; else return const Text(""); if (text.contains(" ")) text = text.replaceAll(" ", "\n"); return SideTitleWidget(axisSide: meta.axisSide, space: 4, child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: value.toInt() == 0 ? mainColor.value : breakColor.value, fontSize: 10, fontWeight: FontWeight.bold))); } if (compareChartType == "Pie") { if (val1 == 0 && val2 == 0) return const Center(child: Text("Select dates to compare", style: TextStyle(color: Colors.grey))); return PieChart(PieChartData(sectionsSpace: 4, centerSpaceRadius: 40, sections: [PieChartSectionData(color: mainColor.value, value: val1 == 0 ? 0.1 : val1, title: "${val1.toStringAsFixed(1)}\n$timeUnit", radius: 50, titleStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black)), PieChartSectionData(color: breakColor.value, value: val2 == 0 ? 0.1 : val2, title: "${val2.toStringAsFixed(1)}\n$timeUnit", radius: 50, titleStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black))])); } if (compareChartType == "Line") { return LineChart(LineChartData(gridData: FlGridData(show: true, drawVerticalLine: false, getDrawingHorizontalLine: (v) => const FlLine(color: Colors.white10, strokeWidth: 1)), titlesData: FlTitlesData(leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, getTitlesWidget: (v, m) => Text(_formatYAxis(v), style: const TextStyle(color: Colors.grey, fontSize: 10)))), bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, getTitlesWidget: getCompareLabel)), topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false))), borderData: FlBorderData(show: false), minY: 0, maxY: maxY, lineBarsData: [LineChartBarData(spots: [FlSpot(0, val1), FlSpot(1, val2)], isCurved: false, color: Colors.white, barWidth: 2, dotData: FlDotData(show: true, getDotPainter: (spot, percent, barData, index) { return FlDotCirclePainter(radius: 6, color: index == 0 ? mainColor.value : breakColor.value, strokeWidth: 0); }))])); } return BarChart(BarChartData(gridData: FlGridData(show: false), titlesData: FlTitlesData(leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, getTitlesWidget: (v, m) => Text(_formatYAxis(v), style: const TextStyle(color: Colors.grey, fontSize: 10)))), rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, getTitlesWidget: getCompareLabel))), borderData: FlBorderData(show: false), barGroups: [BarChartGroupData(x: 0, barRods: [BarChartRodData(toY: val1, color: mainColor.value, width: 40, borderRadius: BorderRadius.circular(4), backDrawRodData: BackgroundBarChartRodData(show: true, toY: maxY, color: Colors.grey[900]))]), BarChartGroupData(x: 1, barRods: [BarChartRodData(toY: val2, color: breakColor.value, width: 40, borderRadius: BorderRadius.circular(4), backDrawRodData: BackgroundBarChartRodData(show: true, toY: maxY, color: Colors.grey[900]))])])); }
}

// ================== 4. SETTINGS SCREEN (UPDATED) ==================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}
class _SettingsScreenState extends State<SettingsScreen> {
  // MethodChannel define (Android Native Bridge ke liye)
  static const platform = MethodChannel('com.example.time_app/settings');

  // --- DONATION LOGIC START ---
  Future<void> _payWithUPI(String amount) async {
    const String upiId = "saqibqamar7866@okicici"; // Apni ID yahan dalein
    const String name = "Time Manager Dev";
    const String note = "Support Time Manager";

    // Yahan 'amount' dynamic ho gaya hai
    final Uri upiUrl = Uri.parse(
        "upi://pay?pa=$upiId&pn=$name&tn=$note&am=$amount&cu=INR"
    );
    if (!await launchUrl(upiUrl, mode: LaunchMode.externalApplication)) {
      debugPrint("UPI App not open");
    }
  }
  Widget _buildDonationBox(String amount) {
    return Expanded(
      child: GestureDetector(
        onTap: () => _payWithUPI(amount), // Button dabte hi wo amount jayega
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: Colors.green[700],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white24),
          ),
          alignment: Alignment.center,
          child: Text("₹$amount", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }
  Future<void> _openBuyMeCoffee() async {
    // 👇 YAHAN APNA LINK DALEIN 👇
    final Uri url = Uri.parse('https://buymeacoffee.com/saqib791');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      debugPrint("Browser not open");
    }
  }
  // --- DONATION LOGIC END ---

  void _openColorPicker(String title, ValueNotifier<Color> colorNotifier, String prefKey) {
    Color tempColor = colorNotifier.value;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text("Pick $title Color", style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: tempColor,
            onColorChanged: (c) => tempColor = c,
            enableAlpha: false,
            displayThumbColor: true,
            paletteType: PaletteType.hsvWithHue,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL", style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: mainColor.value),
            onPressed: () async {
              setState(() {
                colorNotifier.value = tempColor;
              });
              final prefs = await SharedPreferences.getInstance();
              await prefs.setInt(prefKey, tempColor.value);
              Navigator.pop(context);
            },
            child: const Text("SAVE", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  // ... (Baaki functions same rahenge: _exportData, _importData, _clearAllData) ...
  // Jagah bachane ke liye main unhe repeat nahi kar raha hu, wo waise hi rahenge
  // jaise aapke purane code mein the. Agar wo functions chahiye to bata dena.
  // Main yahan direct export/import functions copy kar raha hu taaki error na aaye:

  Future<void> _exportData() async {
    // Aapka purana export logic yahan same rahega
    try {
      bool storageGranted = await Permission.manageExternalStorage.request().isGranted || await Permission.storage.request().isGranted;
      if (!storageGranted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Storage Permission Required!"), backgroundColor: Colors.red)); return; }
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory != null) {
        final prefs = await SharedPreferences.getInstance();
        Map<String, dynamic> backupData = {
          "tasks": jsonDecode(prefs.getString('saved_tasks') ?? "[]"),
          "history": jsonDecode(prefs.getString('study_history') ?? "[]"),
          "subjects": prefs.getStringList('study_subjects') ?? [],
          "breaks": prefs.getStringList('break_activities') ?? [],
          "subject_colors": jsonDecode(prefs.getString('subject_colors') ?? "{}"),
          "color_main": prefs.getInt('color_main'),
          "color_break": prefs.getInt('color_break'),
          "color_exam": prefs.getInt('color_exam'),
          "backup_date": DateTime.now().toString(),
        };
        String fileName = "StudyBackup_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.json";
        File file = File('$selectedDirectory/$fileName');
        await file.writeAsString(jsonEncode(backupData));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Saved to: $fileName"), backgroundColor: Colors.green));
      }
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red)); }
  }

  Future<void> _importData() async {
    // Aapka purana import logic yahan same rahega
    try {
      bool storageGranted = await Permission.manageExternalStorage.request().isGranted || await Permission.storage.request().isGranted;
      if (!storageGranted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Permission Denied!"), backgroundColor: Colors.red)); return; }
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result != null && result.files.single.path != null) {
        File file = File(result.files.single.path!);
        String content = await file.readAsString();
        Map<String, dynamic> data = jsonDecode(content);
        final prefs = await SharedPreferences.getInstance();
        if (data['tasks'] != null) await prefs.setString('saved_tasks', jsonEncode(data['tasks']));
        if (data['history'] != null) await prefs.setString('study_history', jsonEncode(data['history']));
        if (data['subjects'] != null) await prefs.setStringList('study_subjects', List<String>.from(data['subjects']));
        if (data['breaks'] != null) await prefs.setStringList('break_activities', List<String>.from(data['breaks']));
        if (data['color_main'] != null) { await prefs.setInt('color_main', data['color_main']); mainColor.value = Color(data['color_main']); }
        if (data['color_break'] != null) { await prefs.setInt('color_break', data['color_break']); breakColor.value = Color(data['color_break']); }
        if (data['color_exam'] != null) { await prefs.setInt('color_exam', data['color_exam']); examColor.value = Color(data['color_exam']); }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Data Restored! Restarting..."), backgroundColor: Colors.green));
          await Future.delayed(const Duration(seconds: 1));
          Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (context) => const MyApp()), (route) => false);
        }
      }
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red)); }
  }

  Future<void> _clearAllData() async {
    // Aapka purana clear logic yahan same rahega
    showDialog(context: context, builder: (context) => AlertDialog(backgroundColor: const Color(0xFF1E1E1E), title: const Text("⚠️ Reset Everything?", style: TextStyle(color: Colors.redAccent)), content: const Text("This will delete all data.", style: TextStyle(color: Colors.white70)), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL", style: TextStyle(color: Colors.grey))), ElevatedButton(onPressed: () async { final prefs = await SharedPreferences.getInstance(); await prefs.clear(); setState(() { mainColor.value = Colors.cyanAccent; breakColor.value = Colors.pinkAccent; examColor.value = Colors.greenAccent; }); if (context.mounted) Navigator.pop(context); if (context.mounted) { Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (context) => const MyApp()), (Route<dynamic> route) => false); } }, style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent), child: const Text("RESET ALL", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))) ]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text("SETTINGS", style: TextStyle(color: mainColor.value, fontWeight: FontWeight.bold, letterSpacing: 2.0)),
        centerTitle: true,
        backgroundColor: Colors.black,
        iconTheme: IconThemeData(color: mainColor.value),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ==========================================
          // 👇 NEW DONATION SECTION (SABSE UPAR) 👇
          // ==========================================
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.amber.withOpacity(0.5), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Support Development ❤️", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 5),
                const Text("If you like this time management app, please consider donating.", style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 15),

                const Text("Select Amount (UPI):", style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 10),

                Row(
                  children: [
                    _buildDonationBox("10"),
                    _buildDonationBox("20"),
                    _buildDonationBox("50"),
                    _buildDonationBox("100"),
                  ],
                ),
                const SizedBox(height: 10),

                // Button 2: Buy Me a Coffee
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _openBuyMeCoffee,
                    icon: const Icon(Icons.coffee, color: Colors.black),
                    label: const Text("Buy me a Coffee (International)"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFDD00),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 25),
          // ==========================================

          const Text("THEME COLORS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 15),
          _buildSettingsTile(icon: Icons.color_lens, title: "Main Theme", subtitle: "Study & App UI Color", color: mainColor.value, onTap: () => _openColorPicker("Main", mainColor, 'color_main')),
          const SizedBox(height: 10),
          _buildSettingsTile(icon: Icons.coffee, title: "Break Theme", subtitle: "Break Timer & Graph Color", color: breakColor.value, onTap: () => _openColorPicker("Break", breakColor, 'color_break')),
          const SizedBox(height: 10),
          _buildSettingsTile(icon: Icons.school, title: "Exam Theme", subtitle: "Exam Mode & Graph Color", color: examColor.value, onTap: () => _openColorPicker("Exam", examColor, 'color_exam')),

          const SizedBox(height: 30),
          const Divider(color: Colors.grey),
          const SizedBox(height: 15),

          const Text("SOUND SETTINGS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 15),
          _buildSoundTile("Time Over Sound", "Plays when timer ends", soundAlarm, 'snd_alarm'),
          const SizedBox(height: 10),
          _buildSoundTile("Break Start Sound", "Plays when break starts", soundBreak, 'snd_break'),
          const SizedBox(height: 10),
          _buildSoundTile("Session Done Sound", "Plays when target achieved", soundDone, 'snd_done'),
          const SizedBox(height: 10),
          ValueListenableBuilder<bool>(
            valueListenable: enableNotificationSound,
            builder: (context, value, child) {
              return SwitchListTile(
                title: const Text("Notification Sounds", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: const Text("Play 'Ting' sound on timer updates", style: TextStyle(color: Colors.grey, fontSize: 12)),
                activeColor: mainColor.value,
                value: value,
                onChanged: (val) async {
                  enableNotificationSound.value = val;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('enable_notif_sound', val);
                },
                secondary: Icon(Icons.volume_up, color: mainColor.value),
                tileColor: const Color(0xFF111111),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: mainColor.value.withOpacity(0.3))),
              );
            },
          ),

          const SizedBox(height: 30),
          const Divider(color: Colors.grey),
          const SizedBox(height: 15),

          const Text("LOCK SCREEN BEHAVIOR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 15),
          ValueListenableBuilder<bool>(
            valueListenable: enableLockScreen,
            builder: (context, currentValue, child) {
              return SwitchListTile(
                title: const Text("Show over Lock Screen", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: const Text("Allow app to appear on lock screen", style: TextStyle(color: Colors.grey, fontSize: 12)),
                activeColor: mainColor.value,
                value: currentValue,
                onChanged: (newValue) async {
                  enableLockScreen.value = newValue;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('lock_screen_popup', newValue);
                  try { await platform.invokeMethod('toggleLockScreen', newValue); } catch (e) { print("Bridge Error: $e"); }
                },
                secondary: Icon(Icons.screen_lock_portrait, color: mainColor.value),
                tileColor: const Color(0xFF111111),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: mainColor.value.withOpacity(0.3))),
              );
            },
          ),

          const SizedBox(height: 15),
          const Text("NOTIFICATION BEHAVIOR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 15),
          ValueListenableBuilder<bool>(
            valueListenable: enableStickyNotification,
            builder: (context, val, child) {
              return SwitchListTile(
                title: const Text("Sticky Notification", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: Text(val ? "Notification cannot be swiped away (Always ON)." : "Notification can be swiped away ONLY when paused.", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                activeColor: mainColor.value,
                value: val,
                onChanged: (newValue) async {
                  enableStickyNotification.value = newValue;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('sticky_notif', newValue);
                },
                secondary: Icon(Icons.push_pin, color: mainColor.value),
                tileColor: const Color(0xFF111111),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: mainColor.value.withOpacity(0.3))),
              );
            },
          ),
          const SizedBox(height: 30),
          const Divider(color: Colors.grey),
          const SizedBox(height: 15),

          // 👇 TIMER BEHAVIOR (Isse wapas add karein)
          const Text("TIMER BEHAVIOR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 15),

          ValueListenableBuilder<bool>(
            valueListenable: resetTimerOnSwitch,
            builder: (context, val, child) {
              return SwitchListTile(
                title: const Text("Always Start from 0", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: Text(
                    val
                        ? "Timer resets to 00:00 when you switch modes."
                        : "Timer continues today's total time on switch.",
                    style: const TextStyle(color: Colors.grey, fontSize: 12)
                ),
                activeColor: mainColor.value,
                value: val,
                onChanged: (newValue) async {
                  resetTimerOnSwitch.value = newValue;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('reset_timer_switch', newValue);
                },
                secondary: Icon(Icons.restart_alt, color: mainColor.value),
                tileColor: const Color(0xFF111111),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: mainColor.value.withOpacity(0.3))),
              );
            },
          ),

          const SizedBox(height: 30),
          const Divider(color: Colors.grey),
          const SizedBox(height: 15),

          const Text("DATA MANAGEMENT", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 15),
          _buildSettingsTile(icon: Icons.upload_file, title: "Backup Data", subtitle: "Save to folder", color: Colors.greenAccent, onTap: _exportData),
          const SizedBox(height: 10),
          _buildSettingsTile(icon: Icons.download_for_offline, title: "Restore Data", subtitle: "Load from backup file", color: Colors.cyanAccent, onTap: _importData),
          // ... Backup aur Restore ke neeche ye paste karein ...

          const SizedBox(height: 10),

          // 👇 UPDATED CHANGE FOLDER (NO RESTART)
          _buildSettingsTile(
            icon: Icons.folder_open,
            title: "Change Folder",
            subtitle: "Current data will be saved to new folder",
            color: Colors.orangeAccent,
            onTap: () async {
              // 1. Pehle Permission Check karein
              bool hasPermission = false;
              if (await Permission.manageExternalStorage.request().isGranted) {
                hasPermission = true;
              } else if (await Permission.storage.request().isGranted) {
                hasPermission = true;
              }

              if (!hasPermission) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Permission Required!"), backgroundColor: Colors.red)
                );
                return;
              }

              // 2. Folder Picker Kholein
              String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

              if (selectedDirectory != null) {
                final prefs = await SharedPreferences.getInstance();

                // 3. Naya Path Save karein
                await prefs.setString('backup_path', selectedDirectory);

                // 4. Turant naye folder mein ek baar data save kar dein
                // (Taaki wahan 'time_manager_data.json' file ban jaye)
                await updateJsonFile();

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("Folder Changed to: ${selectedDirectory.split('/').last} "),
                        backgroundColor: Colors.green,
                      )
                  );
                }
              }
            },
          ),

          // ... Iske baad Reset Everything wala button hoga ...
          const SizedBox(height: 40),
          _buildSettingsTile(icon: Icons.delete_forever, title: "Reset Everything", subtitle: "Delete all data", color: Colors.redAccent, onTap: _clearAllData)
        ],
      ),
    );
  }

  Widget _buildSettingsTile({required IconData icon, required String title, required String subtitle, required Color color, required VoidCallback onTap}) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(15), border: Border.all(color: color.withOpacity(0.3))),
      child: ListTile(
        leading: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle), child: Icon(icon, color: color)),
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
        trailing: CircleAvatar(backgroundColor: color, radius: 8),
        onTap: onTap,
      ),
    );
  }

  void _showSoundPicker(String title, ValueNotifier<String> notifier, String prefKey) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: Text("Select $title", style: TextStyle(color: mainColor.value)),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: ListView.builder(
              itemCount: availableSounds.length,
              itemBuilder: (context, index) {
                String soundName = availableSounds[index];
                bool isSelected = notifier.value == soundName;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(color: isSelected ? mainColor.value.withOpacity(0.1) : Colors.transparent, borderRadius: BorderRadius.circular(10), border: isSelected ? Border.all(color: mainColor.value) : null),
                  child: ListTile(
                    leading: IconButton(icon: const Icon(Icons.play_circle_fill, color: Colors.white), onPressed: () { playGlobalSound(soundName); }),
                    title: Text(soundName.replaceAll(".mp3", "").toUpperCase(), style: TextStyle(color: isSelected ? mainColor.value : Colors.grey, fontWeight: FontWeight.bold)),
                    trailing: isSelected ? Icon(Icons.check_circle, color: mainColor.value) : const Icon(Icons.circle_outlined, color: Colors.grey),
                    onTap: () async {
                      playButtonFeedback();
                      setState(() { notifier.value = soundName; });
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString(prefKey, soundName);
                      Navigator.pop(context);
                    },
                  ),
                );
              },
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("CLOSE", style: TextStyle(color: Colors.redAccent)))],
        );
      },
    );
  }

  Widget _buildSoundTile(String title, String subtitle, ValueNotifier<String> notifier, String prefKey) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.grey.withOpacity(0.3))),
      child: ListTile(
        leading: const Icon(Icons.music_note, color: Colors.white),
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [Text(notifier.value.replaceAll(".mp3", "").toUpperCase(), style: TextStyle(color: mainColor.value, fontWeight: FontWeight.bold)), const SizedBox(width: 10), const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey)]),
        onTap: () { _showSoundPicker(title, notifier, prefKey); },
      ),
    );
  }
}