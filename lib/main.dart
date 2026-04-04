import 'dart:math';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:image/image.dart' as img;
import 'package:image_cropper/image_cropper.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

/// Même région que les Cloud Functions dans la console Firebase (souvent us-central1).
/// Sinon l’app peut renvoyer `firebase_functions/not-found` sur iOS/Android.
final FirebaseFunctions _firebaseFunctionsRegion =
    FirebaseFunctions.instanceFor(region: 'us-central1');

const AndroidNotificationChannel _defaultNotificationChannel =
    AndroidNotificationChannel(
  'ldconnect_high_importance',
  'Notifications LD Connect',
  description: 'Notifications importantes LD Connect',
  importance: Importance.high,
);

/// Sélectionne et recadre une image (PP ou bannière). L'utilisateur peut zoomer/déplacer pour choisir la zone.
Future<File?> pickAndCropImage(
  BuildContext context, {
  required double aspectRatioX,
  required double aspectRatioY,
  bool circular = false,
  int maxWidth = 1024,
  int maxHeight = 1024,
}) async {
  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (picked == null || !context.mounted) return null;
  final cropped = await ImageCropper().cropImage(
    sourcePath: picked.path,
    aspectRatio: CropAspectRatio(ratioX: aspectRatioX, ratioY: aspectRatioY),
    uiSettings: [
      AndroidUiSettings(
        toolbarTitle: circular ? "Recadrer la photo" : "Recadrer la bannière",
        toolbarColor: const Color(0xFF1E1C33),
        toolbarWidgetColor: Colors.white,
        backgroundColor: const Color(0xFF030315),
        dimmedLayerColor: Colors.black54,
        statusBarLight: false,
        navBarLight: false,
        cropStyle: circular ? CropStyle.circle : CropStyle.rectangle,
        lockAspectRatio: true,
        hideBottomControls: false,
        showCropGrid: true,
      ),
      IOSUiSettings(
        title: circular ? "Recadrer la photo" : "Recadrer la bannière",
        cropStyle: circular ? CropStyle.circle : CropStyle.rectangle,
        aspectRatioLockEnabled: true,
        resetAspectRatioEnabled: false,
        rotateButtonsHidden: false,
        aspectRatioPickerButtonHidden: true,
        embedInNavigationController: true,
        hidesNavigationBar: false,
      ),
    ],
    compressQuality: 85,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
  );
  if (cropped == null) return null;
  return File(cropped.path);
}

/// Redimensionne une image (PP ou bannière) pour limiter taille et poids.
Future<File?> resizeImageForUpload(
  File source, {
  int maxWidth = 512,
  int maxHeight = 512,
  int quality = 85,
}) async {
  try {
    final bytes = await source.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final needResize =
        decoded.width > maxWidth || decoded.height > maxHeight;
    img.Image resized = decoded;
    if (needResize) {
      if (decoded.width > decoded.height) {
        resized = img.copyResize(decoded, width: maxWidth);
      } else {
        resized = img.copyResize(decoded, height: maxHeight);
      }
      if (resized.height > maxHeight) {
        resized = img.copyResize(resized, height: maxHeight);
      }
      if (resized.width > maxWidth) {
        resized = img.copyResize(resized, width: maxWidth);
      }
    }
    final out = img.encodeJpg(resized, quality: quality);
    final tmp = File('${source.path}_resized.jpg');
    await tmp.writeAsBytes(out);
    return tmp;
  } catch (_) {
    return null;
  }
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

void _firebaseOnMessageHandler(RemoteMessage message) {
  final notification = message.notification;
  final android = notification?.android;
  if (notification == null || android == null) return;

  flutterLocalNotificationsPlugin.show(
    id: notification.hashCode,
    title: notification.title,
    body: notification.body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _defaultNotificationChannel.id,
        _defaultNotificationChannel.name,
        channelDescription: _defaultNotificationChannel.description,
        icon: '@mipmap/ic_launcher',
      ),
    ),
    payload: jsonEncode(message.data),
  );
}

Future<void> saveFcmTokenToUser(String? token) async {
  if (token == null) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  await FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .set({
    'fcmTokens': FieldValue.arrayUnion([token]),
  }, SetOptions(merge: true));
}

Future<bool> _checkUserNotBannedForAction(BuildContext context) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Connecte-toi pour utiliser cette fonctionnalité.")),
    );
    return false;
  }

  try {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final data = snap.data() ?? <String, dynamic>{};
    final banPermanent = (data['banPermanent'] ?? false) as bool;
    final banUntilTs = data['banUntil'] as Timestamp?;
    final now = DateTime.now();
    final bool isTempBanned =
        banUntilTs != null && banUntilTs.toDate().isAfter(now);
    final bool isBanned = banPermanent || isTempBanned;

    if (isBanned) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Ton compte est actuellement banni. Tu ne peux pas effectuer cette action.",
          ),
        ),
      );
      return false;
    }
  } catch (_) {
    // En cas d'erreur de lecture, on laisse passer mais on loguerait côté analytics si besoin.
  }

  return true;
}

bool _isStaffRole(String role) {
  final r = role.toLowerCase();
  return r == 'founder' || r == 'cofounder' || r == 'dev' || r == 'moderator';
}

int _computeLevelFromXp(int xp) {
  if (xp <= 0) return 0;
  // courbe: niveau ~ sqrt(xp / 100)
  final lvl = sqrt(xp / 100).floor();
  return lvl.clamp(0, 50);
}

String _levelTitleFromLevel(int level) {
  if (level >= 50) return "Dragon LD";
  if (level >= 25) return "Pilier LD";
  if (level >= 10) return "Joueur confirmé";
  if (level >= 1) return "Rookie LD";
  return "";
}

Future<void> _awardXp(String userId, int amount) async {
  if (amount <= 0) return;
  final ref = FirebaseFirestore.instance.collection('users').doc(userId);
  await FirebaseFirestore.instance.runTransaction((tx) async {
    final snap = await tx.get(ref);
    final data = snap.data() as Map<String, dynamic>? ?? {};
    final rawXp = data['xp'];
    final int currentXp = rawXp is int ? rawXp : 0;
    final newXp = currentXp + amount;
    final newLevel = _computeLevelFromXp(newXp);
    final title = _levelTitleFromLevel(newLevel);
    tx.set(
      ref,
      {
        'xp': newXp,
        'level': newLevel,
        'levelTitle': title,
      },
      SetOptions(merge: true),
    );
  });
}

/// FCM + notifications locales : ne doit pas bloquer [runApp], sinon écran blanc
/// (souvent sur iOS / sideload ou si `getToken()` attend indéfiniment).
Future<void> _setupMessagingAndNotifications() async {
  try {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    await flutterLocalNotificationsPlugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final p = response.payload;
        if (p == null || p.isEmpty) return;
        try {
          final decoded = jsonDecode(p);
          if (decoded is Map) {
            navigateFromNotificationData(
              Map<String, dynamic>.from(
                decoded.map((k, v) => MapEntry(k.toString(), v)),
              ),
            );
          }
        } catch (_) {}
      },
    );
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_defaultNotificationChannel);

    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    final token = await messaging.getToken().timeout(
      const Duration(seconds: 25),
      onTimeout: () => null,
    );
    debugPrint('FCM token: $token');
    await saveFcmTokenToUser(token);

    messaging.onTokenRefresh.listen((newToken) async {
      debugPrint('FCM token refresh: $newToken');
      await saveFcmTokenToUser(newToken);
    });

    FirebaseMessaging.onMessage.listen(_firebaseOnMessageHandler);

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage msg) {
      navigateFromNotificationData(msg.data);
    });
    final initialMsg = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMsg != null) {
      navigateFromNotificationData(initialMsg.data);
    }
  } catch (e, st) {
    debugPrint('FCM / notifications init failed: $e\n$st');
  }
}

/// Premier écran si Firebase ne démarre pas (bundle ID / plist / réseau).
Widget _firebaseInitErrorScreen(Object error) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF030315),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(
              'Impossible d’initialiser Firebase.\n\n'
              'Vérifie la connexion, que le Bundle ID correspond à '
              'GoogleService-Info.plist, puis réinstalle l’app.\n\n'
              '$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Object? firebaseInitError;
  try {
    await Firebase.initializeApp().timeout(
      const Duration(seconds: 25),
      onTimeout: () => throw TimeoutException('Firebase.initializeApp()'),
    );
  } catch (e, st) {
    firebaseInitError = e;
    debugPrint('Firebase init failed: $e\n$st');
  }

  if (firebaseInitError != null) {
    runApp(_firebaseInitErrorScreen(firebaseInitError));
    return;
  }

  // Doit être enregistré avant runApp (recommandation Firebase).
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Démarre l'UI tout de suite ; FCM en arrière-plan (évite écran blanc si getToken bloque).
  runApp(const LDConnectApp());
  unawaited(_setupMessagingAndNotifications());

  // XP passif pour temps d'utilisation : petite récompense toutes les 5 minutes
  Timer.periodic(const Duration(minutes: 5), (timer) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await _awardXp(user.uid, 2);
  });
}

// --- DESIGN SYSTEM ---

class NeonTheme {
  static const Color accent = Color(0xFFE100FF);
  static const Color neonBlue = Color(0xFF00FFFF);
  static const Color bgDark = Color(0xFF030315);
  static const Color surface = Color(0xFF1E1C33);
  static const Color surface2 = Color(0xFF121024);

  /// Fond pour l'écran de connexion / inscription / vérification / setup
  static BoxDecoration galaxyBg() => const BoxDecoration(
    image: DecorationImage(
      image: AssetImage("assets/background.png"),
      fit: BoxFit.cover,
    ),
  );

  /// Fond une fois connecté (ciel étoilé / Voie lactée)
  static BoxDecoration galaxyBgConnected() => const BoxDecoration(
    image: DecorationImage(
      image: AssetImage("assets/background_connected.png"),
      fit: BoxFit.cover,
    ),
  );

  static BoxDecoration neonCardDecoration({double radius = 18}) =>
      BoxDecoration(
        color: surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: neonBlue.withValues(alpha: 0.55), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: neonBlue.withValues(alpha: 0.25),
            blurRadius: 26,
            spreadRadius: 3,
            offset: const Offset(0, 8),
          ),
        ],
      );

  static TextStyle titleGlow(double size) => TextStyle(
    fontSize: size,
    fontWeight: FontWeight.w800,
    shadows: [Shadow(color: accent.withValues(alpha: 0.35), blurRadius: 16)],
  );

  static TextStyle labelGlow({
    Color color = neonBlue,
    FontWeight weight = FontWeight.w700,
  }) => TextStyle(
    color: color,
    fontWeight: weight,
    shadows: [Shadow(color: color.withValues(alpha: 0.45), blurRadius: 14)],
  );

  static InputDecoration inputStyle(String label, {IconData? icon}) =>
      InputDecoration(
        labelText: label,
        prefixIcon: icon != null ? Icon(icon, color: accent) : null,
        filled: true,
        fillColor: surface.withValues(alpha: 0.7),
        labelStyle: const TextStyle(color: accent),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: accent.withValues(alpha: 0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: accent),
        ),
      );

  static TextStyle sectionTitle() => const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      );
}

String? _rankAssetFromRank(String rank) {
  final r = rank.toLowerCase();
  if (r.contains('supersonic') || r.contains('ssl')) return 'assets/rl_ssl.png';
  if (r.contains('grand')) return 'assets/rl_grand_champion.png';
  if (r.contains('champion')) return 'assets/rl_champion.png';
  if (r.contains('diamant') || r.contains('diamond')) return 'assets/rl_diamant.png';
  if (r.contains('platine') || r.contains('platinum')) return 'assets/rl_platine.png';
  if (r.contains('or') || r.contains('gold')) return 'assets/rl_or.png';
  if (r.contains('argent') || r.contains('silver')) return 'assets/rl_argent.png';
  if (r.contains('bronze')) return 'assets/rl_bronze.png';
  return null;
}

/// Navigation globale (notifications FCM / tap sur une notif).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> _globalNotificationRelay({
  required String targetUid,
  required String type,
  required String message,
  required String postId,
  String? commentId,
}) async {
  final currentUid = FirebaseAuth.instance.currentUser?.uid;
  if (currentUid == null || currentUid == targetUid) return;
  final currentUserSnap =
      await FirebaseFirestore.instance.collection('users').doc(currentUid).get();
  final currentUserData = currentUserSnap.data() ?? <String, dynamic>{};
  final fromName = (currentUserData['pseudo'] ??
          currentUserData['email'] ??
          'Quelqu\'un')
      .toString();
  final fullMessage = '$fromName $message';
  await FirebaseFirestore.instance
      .collection('users')
      .doc(targetUid)
      .collection('notifications')
      .add({
    'type': type,
    'message': fullMessage,
    'postId': postId,
    'commentId': commentId,
    'fromUserId': currentUid,
    'fromUserName': fromName,
    'timestamp': FieldValue.serverTimestamp(),
    'read': false,
  });
}

/// Ouvre le fil / profil selon les données FCM ou le centre de notifications.
void navigateFromNotificationData(Map<String, dynamic> raw) {
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    final postId = (raw['postId'] ?? '').toString().trim();
    final fromUserId = (raw['fromUserId'] ?? '').toString().trim();

    if (postId.isNotEmpty) {
      final snap =
          await FirebaseFirestore.instance.collection('posts').doc(postId).get();
      if (!snap.exists) return;
      final d = snap.data() as Map<String, dynamic>;
      final authorId = (d['authorId'] ?? '').toString();
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      await showModalBottomSheet<void>(
        context: ctx,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetCtx) => CommentsSheet(
          postId: postId,
          postAuthorId: authorId,
          onNotify: _globalNotificationRelay,
        ),
      );
    } else if (fromUserId.isNotEmpty) {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      await Navigator.of(ctx).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => PublicProfileScreen(userId: fromUserId),
        ),
      );
    }
  });
}

void openFullscreenImageUrl(BuildContext context, String url) {
  Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      pageBuilder: (ctx, _, __) => Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5,
                  child: Image.network(url),
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class LDConnectApp extends StatelessWidget {
  const LDConnectApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: NeonTheme.bgDark,
        primaryColor: NeonTheme.accent,
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges().timeout(
          const Duration(seconds: 20),
          onTimeout: (sink) => sink.add(null),
        ),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Scaffold(
              backgroundColor: NeonTheme.bgDark,
              body: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            );
          }

          if (snapshot.hasError) {
            return Scaffold(
              backgroundColor: NeonTheme.bgDark,
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Erreur auth: ${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            );
          }

          final user = snapshot.data;
          if (user == null) {
            return const AuthScreen();
          }

          return FutureBuilder<DocumentSnapshot>(
            future: FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .get()
                .timeout(const Duration(seconds: 20)),
            builder: (context, userDocSnap) {
              if (userDocSnap.connectionState == ConnectionState.waiting) {
                return Scaffold(
                  backgroundColor: NeonTheme.bgDark,
                  body: const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                );
              }

              if (userDocSnap.hasError) {
                return Scaffold(
                  backgroundColor: NeonTheme.bgDark,
                  body: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Erreur chargement profil: ${userDocSnap.error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                );
              }

              if (!userDocSnap.hasData || !userDocSnap.data!.exists) {
                // Si le profil Firestore n'est pas encore créé, on renvoie à l'auth
                return const AuthScreen();
              }

              final data = userDocSnap.data!.data() as Map<String, dynamic>;
              final isVerified = (data['isVerified'] ?? false) as bool;
              final setupDone = (data['setupDone'] ?? false) as bool;
              final email = (data['email'] ?? user.email ?? '').toString();
              final storedCode = (data['verificationCode'] ?? '').toString();

              if (!isVerified) {
                return VerificationCodeScreen(
                  email: email,
                  initialCode: storedCode,
                );
              }

              if (!setupDone) {
                return const SetupProfileScreen();
              }

              return const MainNavigation();
            },
          );
        },
      ),
    );
  }
}

Future<void> _banUserFromProfile(
  BuildContext context,
  String targetUserId, {
  Duration? duration,
}) async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      String label;
      if (duration == null) {
        label = "ban définitif";
      } else if (duration.inDays >= 7) {
        label = "ban 7 jours";
      } else {
        label = "ban 24 heures";
      }
      return AlertDialog(
        title: const Text("Bannir l'utilisateur"),
        content: Text(
          "Es-tu sûr de vouloir appliquer un $label à cet utilisateur ?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Annuler"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              "Confirmer",
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      );
    },
  );

  if (confirm != true) return;

  final userRef =
      FirebaseFirestore.instance.collection('users').doc(targetUserId);

  DateTime? until;
  final bool permanent = duration == null;
  if (!permanent) {
    until = DateTime.now().add(duration!);
  }

  if (permanent) {
    await userRef.update({
      'banPermanent': true,
      'banUntil': null,
    });
  } else {
    await userRef.update({
      'banPermanent': false,
      'banUntil': Timestamp.fromDate(until!),
    });
  }

  try {
    final moderatorId = FirebaseAuth.instance.currentUser?.uid;
    await FirebaseFirestore.instance.collection('bans').add({
      'userId': targetUserId,
      'moderatorId': moderatorId,
      'permanent': permanent,
      'banUntil': permanent ? null : Timestamp.fromDate(until!),
      'createdAt': FieldValue.serverTimestamp(),
      'active': true,
    });
  } catch (_) {}
}

// --- 1. AUTHENTIFICATION COMPLÈTE (AVEC BREVO) ---
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  final TextEditingController _passConfirm = TextEditingController();
  bool isLogin = true;
  bool isLoading = false;
  bool rememberMe = false;
  bool acceptTerms = false;
  late AnimationController _logoAnimController;
  late Animation<double> _logoScale;

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
    _logoAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _logoScale = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(parent: _logoAnimController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _logoAnimController.dispose();
    _email.dispose();
    _pass.dispose();
    _passConfirm.dispose();
    super.dispose();
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final savedRemember = prefs.getBool('remember_me') ?? false;
    final savedEmail = prefs.getString('saved_email');
    final savedPass = prefs.getString('saved_pass');
    if (!mounted) return;
    setState(() {
      rememberMe = savedRemember;
      if (savedRemember) {
        _email.text = savedEmail ?? '';
        _pass.text = savedPass ?? '';
      }
    });
  }

  Future<void> _handleAuth() async {
    if (!isLogin && !acceptTerms) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Tu dois accepter les Conditions d’utilisation et la Politique de confidentialité.",
          ),
        ),
      );
      return;
    }
    if (_email.text.isEmpty || _pass.text.length < 6) return;
    if (!isLogin && _pass.text != _passConfirm.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Les mots de passe ne correspondent pas."),
        ),
      );
      return;
    }
    setState(() => isLoading = true);
    UserCredential? userCredential;
    try {
      if (isLogin) {
        try {
          userCredential =
              await FirebaseAuth.instance.signInWithEmailAndPassword(
            email: _email.text.trim(),
            password: _pass.text.trim(),
          );
        } on FirebaseAuthMultiFactorException catch (e) {
          final resolver = e.resolver;
          final hints = resolver.hints;
          if (hints.isEmpty) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Vérification 2FA requise. Aucun facteur disponible.")),
              );
            }
            return;
          }
          final hint = hints.first;
          if (hint is! PhoneMultiFactorInfo) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Seul la 2FA par SMS est supportée.")),
              );
            }
            return;
          }
          final mfaCompleter = Completer<UserCredential?>();
          FirebaseAuth.instance.verifyPhoneNumber(
            multiFactorSession: resolver.session,
            multiFactorInfo: hint,
            verificationCompleted: (cred) async {
              try {
                final uc = await resolver.resolveSignIn(
                  PhoneMultiFactorGenerator.getAssertion(cred),
                );
                if (!mfaCompleter.isCompleted) mfaCompleter.complete(uc);
              } catch (_) {
                if (!mfaCompleter.isCompleted) mfaCompleter.complete(null);
              }
            },
            verificationFailed: (err) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(err.message ?? "Échec 2FA")),
                );
              }
              if (!mfaCompleter.isCompleted) mfaCompleter.complete(null);
            },
            codeSent: (String vid, int? _) async {
              if (!mounted) return;
              final codeCtrl = TextEditingController();
              final codeOk = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text("Code de vérification"),
                  content: TextField(
                    controller: codeCtrl,
                    decoration: const InputDecoration(
                      labelText: "Code SMS à 6 chiffres",
                    ),
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text("Annuler"),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text("Valider"),
                    ),
                  ],
                ),
              );
              if (codeOk != true || !mounted || mfaCompleter.isCompleted) return;
              final code = codeCtrl.text.trim();
              if (code.isEmpty) {
                mfaCompleter.complete(null);
                return;
              }
              try {
                final credential = PhoneAuthProvider.credential(
                  verificationId: vid,
                  smsCode: code,
                );
                final uc = await resolver.resolveSignIn(
                  PhoneMultiFactorGenerator.getAssertion(credential),
                );
                if (!mfaCompleter.isCompleted) mfaCompleter.complete(uc);
              } catch (_) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Code invalide.")),
                );
                if (!mfaCompleter.isCompleted) mfaCompleter.complete(null);
              }
            },
            codeAutoRetrievalTimeout: (_) {},
          );
          userCredential = await mfaCompleter.future;
          if (userCredential == null) return;
        }

        // Après connexion, on s'assure que le profil Firestore existe
        // et on redirige vers le bon écran (vérif / setup / app).
        final user = userCredential.user;
        if (user != null) {
          final userRef =
              FirebaseFirestore.instance.collection('users').doc(user.uid);
          final snap = await userRef.get();

          if (!snap.exists) {
            await userRef.set({
              'uid': user.uid,
              'email': user.email ?? _email.text.trim(),
              'pseudo': 'Joueur_${Random().nextInt(1000)}',
              'rank': 'Champion 2',
              'friendsCount': 0,
              'roomsCount': 0,
              'setupDone': false,
              'isVerified': true,
              'xp': 0,
              'level': 0,
              'levelTitle': '',
            }, SetOptions(merge: true));
            if (mounted) {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => const SetupProfileScreen(),
                ),
              );
            }
          } else {
            final data = snap.data() as Map<String, dynamic>;
            final isVerified = (data['isVerified'] ?? false) as bool;
            final setupDone = (data['setupDone'] ?? false) as bool;

            if (!mounted) return;

            if (!isVerified) {
              final email = (data['email'] ?? user.email ?? '').toString();
              final storedCode = (data['verificationCode'] ?? '').toString();
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => VerificationCodeScreen(
                    email: email,
                    initialCode: storedCode,
                  ),
                ),
              );
            } else if (!setupDone) {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => const SetupProfileScreen(),
                ),
              );
            } else {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => const MainNavigation(),
                ),
              );
            }
          }
        }
      } else {
        // Inscription + envoi du code par Brevo (Cloud Function, clé API dans Firebase Config)
        String code = (100000 + Random().nextInt(899999)).toString();
        userCredential = await FirebaseAuth.instance
            .createUserWithEmailAndPassword(
              email: _email.text.trim(),
              password: _pass.text.trim(),
            );

        final callable = _firebaseFunctionsRegion
            .httpsCallable('sendVerificationEmail');
        await callable.call({
          'email': _email.text.trim(),
          'code': code,
        });

        final userId = userCredential.user!.uid;

        await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .set({
              'uid': userCredential.user!.uid,
              'email': _email.text.trim(),
              'pseudo': 'Joueur_${Random().nextInt(1000)}',
              'rank': 'Champion 2',
              'friendsCount': 0,
              'roomsCount': 0,
              'setupDone': false,
              'isVerified': false,
              'verificationCode': code,
            });

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => VerificationCodeScreen(
                email: _email.text.trim(),
                initialCode: code,
              ),
            ),
          );
        }
      }

      final prefs = await SharedPreferences.getInstance();
      if (rememberMe) {
        await prefs.setBool('remember_me', true);
        await prefs.setString('saved_email', _email.text.trim());
        await prefs.setString('saved_pass', _pass.text.trim());
      } else {
        await prefs.remove('remember_me');
        await prefs.remove('saved_email');
        await prefs.remove('saved_pass');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: NeonTheme.galaxyBg(),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(35),
            child: Column(
              children: [
                ScaleTransition(
                  scale: _logoScale,
                  child: Image.asset(
                    "assets/logo.png",
                    height: 180,
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  "LD CONNECT",
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        color: NeonTheme.accent.withValues(alpha: 0.9),
                        blurRadius: 24,
                      ),
                      Shadow(
                        color: NeonTheme.neonBlue.withValues(alpha: 0.7),
                        blurRadius: 16,
                      ),
                      const Shadow(
                        color: Colors.white24,
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Le jeu vidéo n'isole pas, il unit, il sauve.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.9),
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _email,
                  decoration: NeonTheme.inputStyle("Email", icon: Icons.email),
                ),
                const SizedBox(height: 15),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: NeonTheme.inputStyle(
                    "Mot de passe",
                    icon: Icons.lock,
                  ),
                ),
                if (!isLogin) ...[
                  const SizedBox(height: 15),
                  TextField(
                    controller: _passConfirm,
                    obscureText: true,
                    decoration: NeonTheme.inputStyle(
                      "Confirmer le mot de passe",
                      icon: Icons.lock_outline,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Checkbox(
                      value: rememberMe,
                      onChanged: (v) {
                        setState(() {
                          rememberMe = v ?? false;
                        });
                      },
                      activeColor: NeonTheme.accent,
                    ),
                    const Text("Se souvenir de moi"),
                  ],
                ),
                if (!isLogin) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Checkbox(
                        value: acceptTerms,
                        onChanged: (v) {
                          setState(() {
                            acceptTerms = v ?? false;
                          });
                        },
                        activeColor: NeonTheme.accent,
                      ),
                      Expanded(
                        child: Wrap(
                          children: [
                            const Text(
                              "J’accepte les ",
                              style: TextStyle(fontSize: 12),
                            ),
                            GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const TermsScreen(),
                                  ),
                                );
                              },
                              child: const Text(
                                "Conditions d’utilisation",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: NeonTheme.neonBlue,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                            const Text(
                              " et la ",
                              style: TextStyle(fontSize: 12),
                            ),
                            GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const PrivacyPolicyScreen(),
                                  ),
                                );
                              },
                              child: const Text(
                                "Politique de confidentialité",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: NeonTheme.neonBlue,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                            const Text(
                              ".",
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                if (isLoading)
                  const CircularProgressIndicator()
                else
                  Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _handleAuth,
                          child: Text(isLogin ? "CONNEXION" : "S'INSCRIRE"),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => isLogin = !isLogin),
                        child: Text(
                          isLogin ? "Créer un compte" : "Déjà inscrit ?",
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Écran de vérification par code à 6 chiffres (envoyé par Brevo via Cloud Function).
class VerificationCodeScreen extends StatelessWidget {
  final String email;
  final String initialCode;
  const VerificationCodeScreen({
    super.key,
    required this.email,
    required this.initialCode,
  });

  @override
  Widget build(BuildContext context) {
    final TextEditingController inputCtrl = TextEditingController();
    return Scaffold(
      body: Container(
        decoration: NeonTheme.galaxyBg(),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    "ENTRE LE CODE REÇU PAR MAIL",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: inputCtrl,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: const InputDecoration(
                      counterText: '',
                      hintText: '000000',
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 30,
                      letterSpacing: 10,
                      color: NeonTheme.neonBlue,
                    ),
                  ),
                  const SizedBox(height: 30),
                  ElevatedButton(
                    onPressed: () async {
                      final code =
                          inputCtrl.text.replaceAll(RegExp(r'\D'), '');
                      if (code.length != 6) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Entre les 6 chiffres du code.'),
                          ),
                        );
                        return;
                      }
                      try {
                        final callable = _firebaseFunctionsRegion
                            .httpsCallable('verifyEmailCode');
                        await callable.call({'code': code});

                        if (!context.mounted) return;
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const SetupProfileScreen(),
                          ),
                        );
                      } catch (e) {
                        if (!context.mounted) return;
                        final s = e.toString();
                        final short = s.contains('permission-denied') ||
                                s.contains('Code incorrect')
                            ? 'Code incorrect'
                            : s;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(short)),
                        );
                      }
                    },
                    child: const Text("VALIDER LE COMPTE"),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () async {
                      await FirebaseAuth.instance.signOut();
                      rootNavigatorKey.currentState
                          ?.popUntil((route) => route.isFirst);
                    },
                    child: const Text(
                      "Changer de compte / Se déconnecter",
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SetupProfileScreen extends StatefulWidget {
  const SetupProfileScreen({super.key});
  @override
  State<SetupProfileScreen> createState() => _SetupProfileScreenState();
}

class _SetupProfileScreenState extends State<SetupProfileScreen> {
  final TextEditingController _pseudo = TextEditingController();
  File? _img;
  bool loading = false;
  String _selectedGame = 'Rocket League';
  String _selectedRank = 'Champion 2';
  bool _hasMic = true;
  final Set<String> _selectedModes = {'2v2'};

  final List<String> _ranks = const [
    'Bronze',
    'Argent',
    'Or',
    'Platine',
    'Diamant',
    'Champion 1',
    'Champion 2',
    'Champion 3',
    'Grand Champion 1',
    'Grand Champion 2',
    'Grand Champion 3',
    'Supersonic Legend',
  ];

  void _save() async {
    if (_pseudo.text.isEmpty) return;
    setState(() => loading = true);
    String? url;
    final uid = FirebaseAuth.instance.currentUser!.uid;
    try {
      if (_img != null) {
        final ref = FirebaseStorage.instance.ref().child('avatars/$uid.jpg');
        await ref.putFile(_img!);
        url = await ref.getDownloadURL();
      }
      final primaryMode =
          _selectedModes.isNotEmpty ? _selectedModes.first : '2v2';

      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'pseudo': _pseudo.text,
        'avatarUrl': url,
        'setupDone': true,
        'game': _selectedGame,
        'rank': _selectedRank,
        'bestRank': _selectedRank,
        'mode': primaryMode,
        'modes': _selectedModes.toList(),
        'hasMic': _hasMic,
      });
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const MainNavigation()),
      );
    } catch (e) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        decoration: NeonTheme.galaxyBg(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 30),
                const Text(
                  "DERNIÈRE ÉTAPE !",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: NeonTheme.accent,
                  ),
                ),
                const SizedBox(height: 30),
                Center(
                  child: GestureDetector(
                    onTap: () async {
                      final f = await pickAndCropImage(
                        context,
                        aspectRatioX: 1,
                        aspectRatioY: 1,
                        circular: true,
                        maxWidth: 512,
                        maxHeight: 512,
                      );
                      if (f != null && mounted) setState(() => _img = f);
                    },
                    child: CircleAvatar(
                      radius: 70,
                      backgroundColor: NeonTheme.surface,
                      backgroundImage: _img != null ? FileImage(_img!) : null,
                      child: _img == null
                          ? const Icon(Icons.add_a_photo, size: 40)
                          : null,
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                TextField(
                  controller: _pseudo,
                  decoration: NeonTheme.inputStyle("Choisis ton pseudo"),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Ton jeu principal",
                    style: NeonTheme.labelGlow(),
                  ),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: _selectedGame,
                  decoration: NeonTheme.inputStyle("Jeu"),
                  dropdownColor: NeonTheme.surface2,
                  items: const [
                    DropdownMenuItem(
                      value: 'Rocket League',
                      child: Text('Rocket League'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _selectedGame = v);
                  },
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Ton rang",
                    style: NeonTheme.labelGlow(),
                  ),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: _selectedRank,
                  decoration: NeonTheme.inputStyle("Rang Rocket League"),
                  dropdownColor: NeonTheme.surface2,
                  items: _ranks
                      .map(
                        (r) => DropdownMenuItem(
                          value: r,
                          child: Text(r),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _selectedRank = v);
                  },
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Modes de jeu préférés",
                    style: NeonTheme.labelGlow(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: ['1v1', '2v2', '3v3'].map((m) {
                    final selected = _selectedModes.contains(m);
                    return ChoiceChip(
                      label: Text(m),
                      selected: selected,
                      onSelected: (value) {
                        setState(() {
                          if (value) {
                            _selectedModes.add(m);
                          } else {
                            _selectedModes.remove(m);
                          }
                          if (_selectedModes.isEmpty) {
                            _selectedModes.add('2v2');
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "As-tu un micro ?",
                    style: NeonTheme.labelGlow(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    ChoiceChip(
                      label: const Text("Oui"),
                      selected: _hasMic,
                      onSelected: (v) {
                        setState(() => _hasMic = true);
                      },
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text("Non"),
                      selected: !_hasMic,
                      onSelected: (v) {
                        setState(() => _hasMic = false);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                if (loading)
                  const Center(child: CircularProgressIndicator())
                else
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _save,
                      child: const Text("C'EST PARTI !"),
                    ),
                  ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- 2. NAVIGATION ---
class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});
  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _index = 0;
  final _pages = const [
    CommunityFeedScreen(),
    MatesScreen(),
    SocialScreen(),
    NewsScreen(),
    SafePlaceScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProfileAvatarBar(
              onGoToHome: () => setState(() => _index = 0),
            ),
            Expanded(child: _pages[_index]),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF050815),
              Color(0xFF02030A),
            ],
          ),
          border: Border(
            top: BorderSide(
              color: NeonTheme.neonBlue.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: NeonTheme.neonBlue.withValues(alpha: 0.35),
              blurRadius: 20,
              spreadRadius: 1,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: BottomNavigationBar(
          currentIndex: _index,
          onTap: (i) => setState(() => _index = i),
          type: BottomNavigationBarType.fixed,
          selectedItemColor: NeonTheme.neonBlue,
          unselectedItemColor: Colors.white70,
          selectedIconTheme:
              const IconThemeData(color: NeonTheme.neonBlue, size: 26),
          unselectedIconTheme:
              const IconThemeData(color: Colors.white70, size: 22),
          selectedLabelStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
          unselectedLabelStyle: const TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 11,
          ),
              backgroundColor: NeonTheme.surface.withValues(alpha: 0.6),
              items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home), label: "Accueil"),
            BottomNavigationBarItem(icon: Icon(Icons.search), label: "Mates"),
            BottomNavigationBarItem(
              icon: Icon(Icons.people_alt),
              label: "Social",
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.notifications),
              label: "Actualités",
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.security),
              label: "Safe Place",
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.settings),
              label: "Paramètres",
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Barre en haut avec la PP à gauche : clic = accès au profil.
class _ProfileAvatarBar extends StatelessWidget {
  final VoidCallback? onGoToHome;

  const _ProfileAvatarBar({this.onGoToHome});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const SizedBox(height: 56);
    }
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .snapshots(),
              builder: (context, snap) {
                String? avatarUrl;
                if (snap.hasData && snap.data!.exists) {
                  avatarUrl = (snap.data!.data() as Map<String, dynamic>?)?['avatarUrl'] as String?;
                }
                return GestureDetector(
                  onTap: () async {
                    final result = await Navigator.push<dynamic>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const UserProfileScreen(),
                      ),
                    );
                    if (result == 'goToHome' && context.mounted) {
                      onGoToHome?.call();
                    }
                  },
                  child: CircleAvatar(
                    radius: 22,
                    backgroundColor: NeonTheme.surface.withValues(alpha: 0.8),
                    backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                        ? NetworkImage(avatarUrl)
                        : null,
                    child: avatarUrl == null || avatarUrl.isEmpty
                        ? const Icon(Icons.person, color: Colors.white70)
                        : null,
                  ),
                );
              },
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

/// Écran de configuration de la double authentification (2FA).
class TwoFactorSettingsScreen extends StatefulWidget {
  const TwoFactorSettingsScreen({super.key});

  @override
  State<TwoFactorSettingsScreen> createState() => _TwoFactorSettingsScreenState();
}

class _TwoFactorSettingsScreenState extends State<TwoFactorSettingsScreen> {
  bool _loading = false;
  String? _error;

  Future<void> _enrollSms2FA() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null || user.email!.isEmpty) {
      setState(() => _error = "Un compte avec email vérifié est requis.");
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final phoneCtrl = TextEditingController();
    try {
      final session = await user.multiFactor.getSession();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: NeonTheme.surface2,
          title: const Text("Activer la 2FA (SMS)"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Entre ton numéro de téléphone. Tu recevras un code par SMS à chaque connexion.",
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneCtrl,
                decoration: const InputDecoration(
                  labelText: "Numéro (ex: +33612345678)",
                  hintText: "+33...",
                ),
                keyboardType: TextInputType.phone,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Envoyer le code"),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        setState(() => _loading = false);
        return;
      }
      final phone = phoneCtrl.text.trim();
      if (phone.isEmpty) {
        setState(() {
          _loading = false;
          _error = "Numéro requis.";
        });
        return;
      }
      final completer = Completer<bool>();
      String? vid;

      void safeComplete(bool value) {
        if (!completer.isCompleted) completer.complete(value);
      }

      void safeCompleteError(Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      }

      FirebaseAuth.instance.verifyPhoneNumber(
        multiFactorSession: session,
        phoneNumber: phone,
        verificationCompleted: (PhoneAuthCredential credential) async {
          if (completer.isCompleted) return;
          try {
            await user.multiFactor.enroll(
              PhoneMultiFactorGenerator.getAssertion(credential),
              displayName: "SMS",
            );
            safeComplete(true);
          } catch (e) {
            safeCompleteError(e);
          }
        },
        verificationFailed: (e) {
          safeCompleteError(e);
        },
        codeSent: (String verificationId, int? _) async {
          if (completer.isCompleted) return;
          vid = verificationId;
          if (!mounted) {
            safeComplete(false);
            return;
          }
          final codeCtrl = TextEditingController();
          try {
            final codeOk = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: NeonTheme.surface2,
                title: const Text("Code SMS"),
                content: TextField(
                  controller: codeCtrl,
                  decoration: const InputDecoration(
                    labelText: "Code à 6 chiffres reçu par SMS",
                  ),
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text("Annuler"),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text("Valider"),
                  ),
                ],
              ),
            );
            if (codeOk != true || vid == null || !mounted) {
              safeComplete(false);
              return;
            }
            final code = codeCtrl.text.trim();
            if (code.isEmpty) {
              safeComplete(false);
              return;
            }
            try {
              final credential = PhoneAuthProvider.credential(
                verificationId: vid!,
                smsCode: code,
              );
              await user.multiFactor.enroll(
                PhoneMultiFactorGenerator.getAssertion(credential),
                displayName: "SMS",
              );
              safeComplete(true);
            } catch (e) {
              safeCompleteError(e);
            }
          } finally {
            codeCtrl.dispose();
          }
        },
        codeAutoRetrievalTimeout: (_) {},
      );
      bool ok = false;
      try {
        ok = await completer.future.timeout(
          const Duration(minutes: 3),
          onTimeout: () {
            safeComplete(false);
            return false;
          },
        );
      } catch (e) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = e is FirebaseAuthException
                ? (e.message ?? e.code)
                : e.toString();
          });
        }
        return;
      }
      if (!mounted) return;
      setState(() => _loading = false);
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Double authentification activée.")),
        );
        Navigator.pop(context);
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error = e.message ?? e.code;
      });
    } catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error = e.toString();
      });
    } finally {
      phoneCtrl.dispose();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Double authentification"),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _NeonCard(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: FutureBuilder<List<MultiFactorInfo>>(
                      future: user != null
                          ? user.multiFactor.getEnrolledFactors()
                          : Future.value(<MultiFactorInfo>[]),
                      builder: (context, snap) {
                        final hasMFA = (snap.data?.length ?? 0) > 0;
                        return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              hasMFA ? Icons.check_circle : Icons.security,
                              color: hasMFA ? Colors.green : NeonTheme.neonBlue,
                              size: 32,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                hasMFA
                                    ? "La double authentification est activée."
                                    : "Protège ton compte avec une vérification en deux étapes.",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        ],
                        if (!hasMFA) ...[
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _loading ? null : _enrollSms2FA,
                              icon: _loading
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.sms),
                              label: Text(_loading ? "En cours…" : "Activer la 2FA (SMS)"),
                            ),
                          ),
                        ],
                      ],
                    );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Onglet Paramètres (engrenage) : Déconnexion + à configurer plus tard.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final currentUid = currentUser?.uid;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "Paramètres",
            style: NeonTheme.sectionTitle(),
          ),
          const SizedBox(height: 24),
          if (currentUid != null)
            StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(currentUid)
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData || !snap.data!.exists) {
                  return const SizedBox.shrink();
                }
                final data =
                    snap.data!.data() as Map<String, dynamic>? ?? {};
                final role = (data['role'] ?? 'user').toString().toLowerCase();
                final isSuperStaff =
                    role == 'founder' || role == 'cofounder' || role == 'dev';
                if (!isSuperStaff) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _NeonCard(
                      child: InkWell(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const AdminMenuScreen(),
                          ),
                        ),
                        borderRadius: BorderRadius.circular(18),
                        child: const ListTile(
                          leading:
                              Icon(Icons.admin_panel_settings, color: Colors.white),
                          title: Text("Menu admin"),
                          subtitle: Text(
                            "Bans, rôles et modération avancée",
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                );
              },
            ),
          _NeonCard(
            child: InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const PrivacyPolicyScreen(),
                ),
              ),
              borderRadius: BorderRadius.circular(18),
              child: const ListTile(
                leading: Icon(Icons.privacy_tip, color: Colors.white),
                title: Text("Politique de confidentialité"),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _NeonCard(
            child: InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const TermsScreen(),
                ),
              ),
              borderRadius: BorderRadius.circular(18),
              child: const ListTile(
                leading: Icon(Icons.description, color: Colors.white),
                title: Text("Conditions d’utilisation"),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _NeonCard(
            child: InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const TwoFactorSettingsScreen(),
                ),
              ),
              borderRadius: BorderRadius.circular(18),
              child: const ListTile(
                leading: Icon(Icons.security, color: Colors.white),
                title: Text("Double authentification (2FA)"),
                subtitle: Text(
                  "Sécurise ton compte avec une seconde vérification",
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _NeonCard(
            child: InkWell(
              onTap: () async {
                final currentUser = FirebaseAuth.instance.currentUser;
                if (currentUser == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Connecte-toi pour signaler un bug."),
                    ),
                  );
                  return;
                }

                final descriptionCtrl = TextEditingController();
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: NeonTheme.surface2,
                    title: const Text("Signaler un bug"),
                    content: TextField(
                      controller: descriptionCtrl,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText:
                            "Explique ce qui bug, ce que tu faisais, sur quel écran…",
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text("Annuler"),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text(
                          "Envoyer",
                          style: TextStyle(color: NeonTheme.neonBlue),
                        ),
                      ),
                    ],
                  ),
                );

                if (confirmed == true) {
                  final desc = descriptionCtrl.text.trim();
                  if (desc.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content:
                            Text("Merci de décrire un minimum le bug."),
                      ),
                    );
                    return;
                  }

                  final uid = currentUser.uid;
                  final userDoc = await FirebaseFirestore.instance
                      .collection('users')
                      .doc(uid)
                      .get();
                  final userData = userDoc.data() ?? {};
                  final pseudo =
                      (userData['pseudo'] ?? currentUser.email ?? 'Joueur')
                          .toString();

                  await FirebaseFirestore.instance
                      .collection('bug_reports')
                      .add({
                    'userId': uid,
                    'userPseudo': pseudo,
                    'description': desc,
                    'platform': !kIsWeb && Platform.isIOS
                        ? 'ios'
                        : (!kIsWeb && Platform.isAndroid ? 'android' : 'other'),
                    'appVersion': '1.0.0',
                    'resolved': false,
                    'createdAt': FieldValue.serverTimestamp(),
                  });

                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("Bug signalé, merci pour ton aide !"),
                      ),
                    );
                  }
                }
              },
              borderRadius: BorderRadius.circular(18),
              child: const ListTile(
                leading: Icon(Icons.bug_report, color: Colors.white),
                title: Text("Signaler un bug"),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _NeonCard(
            child: InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LegalMentionsScreen(),
                ),
              ),
              borderRadius: BorderRadius.circular(18),
              child: const ListTile(
                leading: Icon(Icons.info_outline, color: Colors.white),
                title: Text("Mentions légales"),
              ),
            ),
          ),
          const SizedBox(height: 24),
          _NeonCard(
            child: InkWell(
              onTap: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text("Supprimer mon compte"),
                    content: const Text(
                      "Cette action supprimera ton compte, tes amis et tes notifications. Es-tu sûr ?",
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text("Annuler"),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text(
                          "Supprimer",
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
                if (confirmed == true && context.mounted) {
                  await deleteAccountAndData(context);
                }
              },
              borderRadius: BorderRadius.circular(18),
              child: const ListTile(
                leading: Icon(Icons.delete_forever, color: Colors.red),
                title: Text(
                  "Supprimer mon compte",
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          _NeonCard(
            child: InkWell(
              onTap: () async {
                await FirebaseAuth.instance.signOut();
                rootNavigatorKey.currentState
                    ?.popUntil((route) => route.isFirst);
              },
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                child: Row(
                  children: [
                    const Icon(Icons.logout, color: Colors.red, size: 24),
                    const SizedBox(width: 14),
                    Text(
                      "Déconnexion",
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BanManagementScreen extends StatelessWidget {
  const BanManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Gestion des bannissements"),
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('bans')
              .orderBy('createdAt', descending: true)
              .limit(100)
              .snapshots(),
          builder: (context, snap) {
            if (snap.hasError) {
              return const Center(
                child: Text(
                  "Erreur de chargement des bans.",
                  style: TextStyle(color: Colors.white70),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final docs = snap.data!.docs;
            if (docs.isEmpty) {
              return const Center(
                child: Text(
                  "Aucun ban enregistré pour le moment.",
                  style: TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
              itemCount: docs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final doc = docs[index];
                final data = doc.data() as Map<String, dynamic>;
                final userId = (data['userId'] ?? 'inconnu').toString();
                final moderatorId =
                    (data['moderatorId'] ?? 'inconnu').toString();
                final permanent = (data['permanent'] ?? false) as bool;
                final banUntilTs = data['banUntil'] as Timestamp?;
                final createdAtTs = data['createdAt'] as Timestamp?;
                final unbannedAtTs = data['unbannedAt'] as Timestamp?;
                final active = (data['active'] ?? true) as bool;

                String subtitle = permanent
                    ? "Ban permanent"
                    : banUntilTs != null
                        ? "Ban jusqu'au ${DateFormat('dd/MM/yyyy HH:mm').format(banUntilTs.toDate())}"
                        : "Ban temporaire";
                if (!active) {
                  subtitle += " • levé";
                }

                final createdAtStr = createdAtTs != null
                    ? DateFormat('dd/MM/yyyy HH:mm')
                        .format(createdAtTs.toDate())
                    : '';
                final unbannedAtStr = unbannedAtTs != null
                    ? DateFormat('dd/MM/yyyy HH:mm')
                        .format(unbannedAtTs.toDate())
                    : null;

                return _NeonCard(
                  child: ListTile(
                    leading: Icon(
                      active ? Icons.gavel : Icons.undo,
                      color: active ? Colors.redAccent : Colors.greenAccent,
                    ),
                    title: Text(
                      "Utilisateur: $userId",
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          subtitle,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "Par: $moderatorId • le $createdAtStr",
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                        if (unbannedAtStr != null)
                          Text(
                            "Ban levé le $unbannedAtStr",
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                    trailing: active
                        ? TextButton(
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text("Lever le ban"),
                                  content: Text(
                                    "Es-tu sûr de vouloir lever le ban de l'utilisateur $userId ?",
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text("Annuler"),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, true),
                                      child: const Text(
                                        "Confirmer",
                                        style:
                                            TextStyle(color: Colors.greenAccent),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true) return;

                              try {
                                // Réinitialise le ban sur le user
                                await FirebaseFirestore.instance
                                    .collection('users')
                                    .doc(userId)
                                    .update({
                                  'banPermanent': false,
                                  'banUntil': null,
                                });

                                final currentModeratorId =
                                    FirebaseAuth.instance.currentUser?.uid;
                                // Marque le ban comme inactif pour déclencher le log Cloud Function
                                await doc.reference.update({
                                  'active': false,
                                  'unbannedAt': FieldValue.serverTimestamp(),
                                  'unbannedBy': currentModeratorId,
                                });
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        "Erreur lors de la levée du ban: $e",
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                            child: const Text(
                              "Lever le ban",
                              style: TextStyle(color: Colors.greenAccent),
                            ),
                          )
                        : null,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class AdminMenuScreen extends StatelessWidget {
  const AdminMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: NeonTheme.bgDark,
        title: const Text("Menu admin"),
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "Outils d’administration",
                  style: NeonTheme.sectionTitle(),
                ),
                const SizedBox(height: 16),
                _NeonCard(
                  child: InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const BanManagementScreen(),
                      ),
                    ),
                    borderRadius: BorderRadius.circular(18),
                    child: const ListTile(
                      leading: Icon(Icons.gavel, color: Colors.white),
                      title: Text("Gestion des bannissements"),
                      subtitle: Text(
                        "Voir et lever les bans actifs",
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _NeonCard(
                  child: InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const UserRolesScreen(),
                      ),
                    ),
                    borderRadius: BorderRadius.circular(18),
                    child: const ListTile(
                      leading:
                          Icon(Icons.manage_accounts, color: Colors.white),
                      title: Text("Gestion des rôles utilisateurs"),
                      subtitle: Text(
                        "Changer les rôles directement depuis l’app",
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _NeonCard(
                  child: InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const BugReportsAdminScreen(),
                      ),
                    ),
                    borderRadius: BorderRadius.circular(18),
                    child: const ListTile(
                      leading: Icon(Icons.bug_report, color: Colors.white),
                      title: Text("Bugs signalés"),
                      subtitle: Text(
                        "Voir les retours utilisateurs et marquer comme résolus",
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _NeonCard(
                  child: InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const UserReportsAdminScreen(),
                      ),
                    ),
                    borderRadius: BorderRadius.circular(18),
                    child: const ListTile(
                      leading: Icon(Icons.flag_outlined, color: Colors.white),
                      title: Text("Signalements"),
                      subtitle: Text(
                        "Modération des reports (profil, posts, etc.)",
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class BugReportsAdminScreen extends StatelessWidget {
  const BugReportsAdminScreen({super.key});

  static bool _isResolved(Map<String, dynamic> data) {
    final v = data['resolved'];
    if (v is bool) return v;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: NeonTheme.bgDark,
        title: const Text("Bugs signalés"),
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('bug_reports')
              .orderBy('createdAt', descending: true)
              .limit(200)
              .snapshots(),
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    "Erreur: ${snap.error}",
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final docs = snap.data!.docs.toList();
            docs.sort((a, b) {
              final da = a.data() as Map<String, dynamic>;
              final db = b.data() as Map<String, dynamic>;
              final ra = _isResolved(da);
              final rb = _isResolved(db);
              if (ra != rb) return ra ? 1 : -1;
              return 0;
            });
            if (docs.isEmpty) {
              return const Center(
                child: Text(
                  "Aucun bug signalé.",
                  style: TextStyle(color: Colors.white70),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              itemCount: docs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final doc = docs[index];
                final data = doc.data() as Map<String, dynamic>;
                final resolved = _isResolved(data);
                final desc = (data['description'] ?? '').toString();
                final pseudo = (data['userPseudo'] ?? '?').toString();
                final uid = (data['userId'] ?? '').toString();
                final platform = (data['platform'] ?? '?').toString();
                final ver = (data['appVersion'] ?? '?').toString();
                final ts = data['createdAt'] as Timestamp?;
                final dateStr = ts != null
                    ? DateFormat('dd/MM/yyyy HH:mm').format(ts.toDate())
                    : '';
                return _NeonCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                pseudo,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            if (resolved)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.25),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.greenAccent),
                                ),
                                child: const Text(
                                  "Résolu",
                                  style: TextStyle(
                                    color: Colors.greenAccent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "UID: $uid",
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          "$platform • v$ver • $dateStr",
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          desc.isEmpty ? "(pas de description)" : desc,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                        if (!resolved) ...[
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () async {
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text("Marquer comme résolu"),
                                    content: const Text(
                                      "Ce bug sera marqué comme traité.",
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text("Annuler"),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text(
                                          "Confirmer",
                                          style: TextStyle(
                                            color: Colors.greenAccent,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                if (ok != true) return;
                                try {
                                  await FirebaseFirestore.instance
                                      .collection('bug_reports')
                                      .doc(doc.id)
                                      .update({
                                    'resolved': true,
                                    'resolvedAt':
                                        FieldValue.serverTimestamp(),
                                    'resolvedBy': FirebaseAuth
                                        .instance.currentUser?.uid,
                                  });
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(
                                      const SnackBar(
                                        content: Text("Bug marqué résolu."),
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text("Erreur: $e"),
                                      ),
                                    );
                                  }
                                }
                              },
                              icon: const Icon(
                                Icons.check_circle_outline,
                                color: NeonTheme.neonBlue,
                              ),
                              label: const Text(
                                "Résolu",
                                style: TextStyle(color: NeonTheme.neonBlue),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class UserReportsAdminScreen extends StatelessWidget {
  const UserReportsAdminScreen({super.key});

  static bool _isResolved(Map<String, dynamic> data) {
    final v = data['resolved'];
    if (v is bool) return v;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: NeonTheme.bgDark,
        title: const Text("Signalements"),
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('reports')
              .orderBy('createdAt', descending: true)
              .limit(200)
              .snapshots(),
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    "Erreur: ${snap.error}",
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final docs = snap.data!.docs.toList();
            docs.sort((a, b) {
              final da = a.data() as Map<String, dynamic>;
              final db = b.data() as Map<String, dynamic>;
              final ra = _isResolved(da);
              final rb = _isResolved(db);
              if (ra != rb) return ra ? 1 : -1;
              return 0;
            });
            if (docs.isEmpty) {
              return const Center(
                child: Text(
                  "Aucun signalement.",
                  style: TextStyle(color: Colors.white70),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              itemCount: docs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final doc = docs[index];
                final data = doc.data() as Map<String, dynamic>;
                final resolved = _isResolved(data);
                final type = (data['type'] ?? '?').toString();
                final reason = (data['reason'] ?? '').toString();
                final reporter = (data['reporterName'] ?? '?').toString();
                final reported = (data['reportedUserName'] ?? '?').toString();
                final ts = data['createdAt'] as Timestamp?;
                final dateStr = ts != null
                    ? DateFormat('dd/MM/yyyy HH:mm').format(ts.toDate())
                    : '';
                return _NeonCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                type,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            if (resolved)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.25),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.greenAccent),
                                ),
                                child: const Text(
                                  "Résolu",
                                  style: TextStyle(
                                    color: Colors.greenAccent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Par: $reporter → $reported",
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          dateStr,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          reason.isEmpty ? "(pas de détail)" : reason,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                        if (!resolved) ...[
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () async {
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text("Marquer comme résolu"),
                                    content: const Text(
                                      "Ce signalement sera marqué comme traité.",
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text("Annuler"),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text(
                                          "Confirmer",
                                          style: TextStyle(
                                            color: Colors.greenAccent,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                if (ok != true) return;
                                try {
                                  await FirebaseFirestore.instance
                                      .collection('reports')
                                      .doc(doc.id)
                                      .update({
                                    'resolved': true,
                                    'resolvedAt':
                                        FieldValue.serverTimestamp(),
                                    'resolvedBy': FirebaseAuth
                                        .instance.currentUser?.uid,
                                  });
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          "Signalement marqué résolu.",
                                        ),
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text("Erreur: $e"),
                                      ),
                                    );
                                  }
                                }
                              },
                              icon: const Icon(
                                Icons.check_circle_outline,
                                color: NeonTheme.neonBlue,
                              ),
                              label: const Text(
                                "Résolu",
                                style: TextStyle(color: NeonTheme.neonBlue),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class NewsScreen extends StatelessWidget {
  const NewsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final currentUid = currentUser?.uid;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 32),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18),
          child: Text(
            "Actualités LD Connect",
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18),
          child: Text(
            "Annonces officielles publiées par l'équipe.",
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('news')
                .orderBy('createdAt', descending: true)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return const Center(
                  child: Text(
                    "Erreur de chargement des actualités.",
                    style: TextStyle(color: Colors.white70),
                  ),
                );
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const Center(
                  child: Text(
                    "Aucune actualité pour le moment.",
                    style: TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                );
              }

              bool viewerIsNewsStaff = false;
              if (currentUid != null) {
                // On récupère le rôle principal depuis le cache utilisateur
                // (les rôles avancés sont gérés via UserRolesScreen).
              }

              return FutureBuilder<DocumentSnapshot>(
                future: currentUid != null
                    ? FirebaseFirestore.instance
                        .collection('users')
                        .doc(currentUid)
                        .get()
                    : null,
                builder: (context, userSnap) {
                  if (userSnap.hasData && userSnap.data!.exists) {
                    final udata =
                        userSnap.data!.data() as Map<String, dynamic>? ?? {};
                    final viewerRole =
                        (udata['role'] ?? 'user').toString().toLowerCase();
                    viewerIsNewsStaff = viewerRole == 'moderator' ||
                        viewerRole == 'dev' ||
                        viewerRole == 'founder' ||
                        viewerRole == 'cofounder';
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                    itemCount: docs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final doc = docs[index];
                      final data = doc.data() as Map<String, dynamic>;
                      final title = (data['title'] ?? '').toString();
                      final body = (data['body'] ?? '').toString();
                      final createdAt = data['createdAt'] as Timestamp?;
                      final authorRole =
                          (data['authorRole'] ?? '').toString().toLowerCase();
                      final mediaUrl =
                          (data['mediaUrl'] ?? '').toString().trim();
                      final authorId =
                          (data['authorId'] ?? '').toString().trim();
                      final isCreator =
                          currentUid != null && currentUid == authorId;
                      final dateStr = createdAt != null
                          ? DateFormat('dd/MM/yyyy HH:mm')
                              .format(createdAt.toDate())
                          : '';

                      return _NeonCard(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.campaign,
                                    color: NeonTheme.neonBlue,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      title.isEmpty ? "Annonce" : title,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  if (isCreator || viewerIsNewsStaff)
                                    PopupMenuButton<String>(
                                      icon: const Icon(
                                        Icons.more_vert,
                                        color: Colors.white70,
                                      ),
                                      onSelected: (value) async {
                                        if (value == 'edit' && isCreator) {
                                          await _openEditNewsDialog(
                                            context,
                                            doc,
                                            data,
                                          );
                                        } else if (value == 'delete') {
                                          await doc.reference.delete();
                                        }
                                      },
                                      itemBuilder: (ctx) => [
                                        if (isCreator)
                                          const PopupMenuItem(
                                            value: 'edit',
                                            child: Text('Modifier'),
                                          ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Supprimer'),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Text(
                                    dateStr,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white38,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (authorRole == 'community_manager')
                                    const _NeonPill(text: "Com."),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                body,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.white70,
                                  height: 1.4,
                                ),
                              ),
                              if (mediaUrl.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: mediaUrl.endsWith('.mp4') ||
                                          mediaUrl.endsWith('.mov')
                                      ? Container(
                                          height: 160,
                                          color: Colors.black26,
                                          alignment: Alignment.center,
                                          child: const Text(
                                            "Média vidéo",
                                            style: TextStyle(
                                              color: Colors.white70,
                                            ),
                                          ),
                                        )
                                      : Image.network(
                                          mediaUrl,
                                          height: 160,
                                          width: double.infinity,
                                          fit: BoxFit.cover,
                                          errorBuilder:
                                              (context, error, stackTrace) {
                                            return Container(
                                              height: 160,
                                              color: Colors.black26,
                                              alignment: Alignment.center,
                                              child: const Text(
                                                "Impossible de charger l'image",
                                                style: TextStyle(
                                                  color: Colors.white70,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
        if (currentUid != null)
          StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('users')
                .doc(currentUid)
                .snapshots(),
            builder: (context, snap) {
              if (!snap.hasData || !snap.data!.exists) {
                return const SizedBox.shrink();
              }
              final data =
                  snap.data!.data() as Map<String, dynamic>? ?? {};
              final role = (data['role'] ?? 'user').toString().toLowerCase();
              final isCom = role == 'community_manager';
              if (!isCom) return const SizedBox.shrink();
              return SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () =>
                          _openCreateNewsDialog(context, currentUid, role),
                      icon: const Icon(Icons.add),
                      label: const Text("Nouvelle actualité"),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Future<void> _openCreateNewsDialog(
    BuildContext context,
    String currentUid,
    String role,
  ) async {
    if (!await _checkUserNotBannedForAction(context)) {
      return;
    }

    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    final mediaCtrl = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: NeonTheme.surface,
          title: const Text("Nouvelle actualité"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: NeonTheme.inputStyle("Titre"),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bodyCtrl,
                  decoration: NeonTheme.inputStyle("Message"),
                  maxLines: 5,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: mediaCtrl,
                  decoration: NeonTheme.inputStyle(
                    "Lien média (image / vidéo, optionnel)",
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Annuler"),
            ),
            TextButton(
              onPressed: () async {
                if (bodyCtrl.text.trim().isEmpty) return;
                if (!await _checkUserNotBannedForAction(ctx)) {
                  return;
                }
                await FirebaseFirestore.instance.collection('news').add({
                  'title': titleCtrl.text.trim(),
                  'body': bodyCtrl.text.trim(),
                  'createdAt': FieldValue.serverTimestamp(),
                  'authorId': currentUid,
                  'authorRole': role,
                  'mediaUrl': mediaCtrl.text.trim(),
                });
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text("Publier"),
            ),
          ],
        );
      },
    );
  }
}

Future<void> _openEditNewsDialog(
  BuildContext context,
  DocumentSnapshot doc,
  Map<String, dynamic> data,
) async {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) return;

  final titleCtrl = TextEditingController(
    text: (data['title'] ?? '').toString(),
  );
  final bodyCtrl = TextEditingController(
    text: (data['body'] ?? '').toString(),
  );
  final mediaCtrl = TextEditingController(
    text: (data['mediaUrl'] ?? '').toString(),
  );

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: NeonTheme.surface,
        title: const Text("Modifier l’actualité"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: NeonTheme.inputStyle("Titre"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bodyCtrl,
                decoration: NeonTheme.inputStyle("Message"),
                maxLines: 5,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: mediaCtrl,
                decoration: NeonTheme.inputStyle(
                  "Lien média (image / vidéo, optionnel)",
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Annuler"),
          ),
          TextButton(
            onPressed: () async {
              if (bodyCtrl.text.trim().isEmpty) return;
              await doc.reference.update({
                'title': titleCtrl.text.trim(),
                'body': bodyCtrl.text.trim(),
                'mediaUrl': mediaCtrl.text.trim(),
              });
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text("Enregistrer"),
          ),
        ],
      );
    },
  );
}

class UserRolesScreen extends StatefulWidget {
  const UserRolesScreen({super.key});

  @override
  State<UserRolesScreen> createState() => _UserRolesScreenState();
}

class _UserRolesScreenState extends State<UserRolesScreen> {
  String _search = '';

  final List<String> _roles = const [
    'user',
    'community_manager',
    'moderator',
    'dev',
    'founder',
    'cofounder',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Gestion des rôles"),
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: TextField(
                decoration: NeonTheme.inputStyle(
                  "Rechercher par pseudo ou email",
                  icon: Icons.search,
                ),
                onChanged: (v) {
                  setState(() {
                    _search = v.trim().toLowerCase();
                  });
                },
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .orderBy('pseudo')
                    .limit(200)
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const Center(
                      child: Text(
                        "Erreur de chargement des utilisateurs.",
                        style: TextStyle(color: Colors.white70),
                      ),
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data!.docs.where((d) {
                    if (_search.isEmpty) return true;
                    final data = d.data() as Map<String, dynamic>;
                    final pseudo =
                        (data['pseudo'] ?? '').toString().toLowerCase();
                    final email =
                        (data['email'] ?? '').toString().toLowerCase();
                    return pseudo.contains(_search) || email.contains(_search);
                  }).toList();

                  if (docs.isEmpty) {
                    return const Center(
                      child: Text(
                        "Aucun utilisateur trouvé.",
                        style: TextStyle(color: Colors.white70),
                      ),
                    );
                  }

                  final currentUid =
                      FirebaseAuth.instance.currentUser?.uid ?? '';

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
                    itemCount: docs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final doc = docs[index];
                      final data = doc.data() as Map<String, dynamic>;
                      final uid = doc.id;
                      final pseudo =
                          (data['pseudo'] ?? 'Sans pseudo').toString();
                      final email =
                          (data['email'] ?? 'Sans email').toString();
                      final role =
                          (data['role'] ?? 'user').toString().toLowerCase();
                      final roles = List<String>.from(
                        (data['roles'] as List?) ?? const <String>[],
                      );

                      return _NeonCard(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                pseudo,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                email,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "UID: $uid",
                                style: const TextStyle(
                                  color: Colors.white24,
                                  fontSize: 10,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: _roles.map((r) {
                                  final isSelected = roles.contains(r) ||
                                      (!roles.contains(r) && r == role);
                                  String label;
                                  switch (r) {
                                    case 'community_manager':
                                      label = 'Community Manager';
                                      break;
                                    case 'moderator':
                                      label = 'Modérateur';
                                      break;
                                    case 'dev':
                                      label = 'Développeur';
                                      break;
                                    case 'founder':
                                      label = 'Fondateur';
                                      break;
                                    case 'cofounder':
                                      label = 'Co-fondateur';
                                      break;
                                    default:
                                      label = r;
                                  }
                                  return FilterChip(
                                    label: Text(label),
                                    selected: isSelected,
                                    onSelected: (selected) async {
                                      List<String> newRoles =
                                          List<String>.from(roles);
                                      if (selected) {
                                        if (!newRoles.contains(r)) {
                                          newRoles.add(r);
                                        }
                                      } else {
                                        newRoles.remove(r);
                                      }
                                      if (!newRoles.contains('user')) {
                                        newRoles.add('user');
                                      }

                                      final primary = newRoles.firstWhere(
                                        (rr) => rr != 'user',
                                        orElse: () => 'user',
                                      );

                                      if (uid == currentUid &&
                                          (role == 'founder' ||
                                              role == 'cofounder' ||
                                              role == 'dev')) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              "Tu ne peux pas modifier ton propre rôle critique depuis ici.",
                                            ),
                                          ),
                                        );
                                        return;
                                      }
                                      try {
                                        await FirebaseFirestore.instance
                                            .collection('users')
                                            .doc(uid)
                                            .update({
                                          'roles': newRoles,
                                          'role': primary,
                                        });
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                "Erreur lors de la mise à jour du rôle: $e",
                                              ),
                                            ),
                                          );
                                        }
                                      }
                                    },
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Écrans légaux ---

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: NeonTheme.bgDark,
        title: const Text("Politique de confidentialité"),
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  "POLITIQUE DE CONFIDENTIALITÉ – LD Connect",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                SizedBox(height: 12),
                Text("Dernière mise à jour : 10/03/2026"),
                SizedBox(height: 16),
                Text(
                  "La présente politique de confidentialité décrit la manière dont l’application LD Connect collecte, "
                  "utilise et protège les données personnelles de ses utilisateurs.",
                ),
                SizedBox(height: 16),
                Text(
                  "Responsable du traitement",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text("L’application LD Connect est éditée par l’association Leader Drive."),
                Text("Adresse : Pipriac, France"),
                Text("Email : Leader.driveld@gmail.com"),
                SizedBox(height: 16),
                Text(
                  "Données collectées",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Lors de l’utilisation de l’application, certaines données peuvent être collectées :\n"
                  "• Adresse email\n"
                  "• Pseudo\n"
                  "• Photo de profil (avatar) et bannière\n"
                  "• Informations de profil (bio, jeux favoris, niveau, rang, etc.)\n"
                  "• Contenus publiés par l’utilisateur (messages, posts, commentaires, réactions)\n"
                  "• Identifiants techniques (UID Firebase, tokens de notification)",
                ),
                SizedBox(height: 16),
                Text(
                  "Utilisation des données",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Les données collectées servent uniquement à :\n"
                  "• Créer et gérer les comptes utilisateurs\n"
                  "• Permettre les interactions entre membres de la communauté (amis, messages, groupes, posts)\n"
                  "• Envoyer des notifications liées à l’activité du compte (likes, commentaires, follow, demandes d’ami)\n"
                  "• Améliorer les fonctionnalités de l’application\n"
                  "• Assurer la sécurité et la modération de la plateforme",
                ),
                SizedBox(height: 16),
                Text(
                  "Partage des données",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Les données personnelles ne sont jamais vendues à des tiers.\n\n"
                  "Certaines données sont traitées par des services techniques nécessaires au fonctionnement de "
                  "l’application, notamment Firebase (Firebase Auth, Cloud Firestore, Cloud Storage, Cloud Messaging) "
                  "fourni par Google, qui héberge et sécurise les données.",
                ),
                SizedBox(height: 16),
                Text(
                  "Conservation des données",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Les données sont conservées uniquement pendant la durée nécessaire au fonctionnement de l’application "
                  "et de la communauté. L’utilisateur peut demander la suppression de son compte et de ses données à tout moment.",
                ),
                SizedBox(height: 16),
                Text(
                  "Suppression du compte",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "L’utilisateur peut supprimer son compte directement depuis les Paramètres de l’application. Cette action entraîne "
                  "la suppression de son profil, de ses relations d’amis, de ses notifications et de ses contenus principaux. "
                  "Certains éléments techniques peuvent être conservés temporairement dans les sauvegardes pour des raisons de "
                  "sécurité et de continuité de service.",
                ),
                SizedBox(height: 16),
                Text(
                  "Sécurité",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "LD Connect s’appuie sur Firebase pour l’authentification et le stockage des données. Les mots de passe ne sont "
                  "jamais stockés en clair et sont gérés par Firebase Auth. Des mesures techniques et organisationnelles sont mises "
                  "en œuvre pour protéger les données contre tout accès non autorisé.",
                ),
                SizedBox(height: 16),
                Text(
                  "Droits des utilisateurs",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Conformément au RGPD, les utilisateurs disposent des droits suivants :\n"
                  "• Droit d’accès à leurs données\n"
                  "• Droit de rectification\n"
                  "• Droit à l’effacement\n"
                  "• Droit d’opposition\n\n"
                  "Toute demande peut être adressée à : Leader.driveld@gmail.com",
                ),
                SizedBox(height: 16),
                Text(
                  "Modification de la politique",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "La présente politique peut être mise à jour à tout moment afin de s’adapter aux évolutions de l’application "
                  "ou aux obligations légales. La version la plus récente est toujours disponible dans l’application.",
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: NeonTheme.bgDark,
        title: const Text("Conditions d’utilisation"),
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  "CONDITIONS D’UTILISATION – LD Connect",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  "Objet",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "LD Connect est une application communautaire destinée aux joueurs souhaitant échanger, trouver des coéquipiers "
                  "et participer à la communauté Leader Drive.",
                ),
                SizedBox(height: 16),
                Text(
                  "Création de compte",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Pour utiliser certaines fonctionnalités de l’application, l’utilisateur doit créer un compte avec :\n"
                  "• Une adresse email valide\n"
                  "• Un pseudo\n"
                  "• Un mot de passe\n\n"
                  "L’utilisateur est responsable des informations fournies et de la confidentialité de ses identifiants.",
                ),
                SizedBox(height: 16),
                Text(
                  "Règles de la communauté",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Les utilisateurs s’engagent à :\n"
                  "• Respecter les autres membres\n"
                  "• Ne pas publier de contenu haineux, violent, discriminatoire ou illégal\n"
                  "• Ne pas harceler ni insulter les autres utilisateurs\n"
                  "• Ne pas publier de contenu pornographique ou choquant\n\n"
                  "Tout non-respect peut entraîner la suppression de contenus, la suspension ou le bannissement du compte.",
                ),
                SizedBox(height: 16),
                Text(
                  "Contenus publiés",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Les utilisateurs restent responsables des contenus qu’ils publient (messages, posts, images, etc.). "
                  "Leader Drive se réserve le droit de supprimer tout contenu jugé inapproprié ou contraire aux règles.",
                ),
                SizedBox(height: 16),
                Text(
                  "Signalement et modération",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Les utilisateurs peuvent signaler un joueur ou un contenu inapproprié. Les signalements sont examinés "
                  "par l’équipe de modération de Leader Drive qui peut prendre les mesures nécessaires pour protéger la communauté.",
                ),
                SizedBox(height: 16),
                Text(
                  "Suspension de compte",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Leader Drive peut suspendre ou supprimer un compte en cas de non-respect des présentes conditions ou en cas "
                  "d’abus répété.",
                ),
                SizedBox(height: 16),
                Text(
                  "Responsabilité",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Leader Drive met tout en œuvre pour assurer le bon fonctionnement de l’application mais ne peut garantir "
                  "une disponibilité permanente ni l’absence totale de bugs. L’application est fournie « en l’état ».",
                ),
                SizedBox(height: 16),
                Text(
                  "Modification des conditions",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Les présentes conditions peuvent être modifiées à tout moment afin d’améliorer le fonctionnement de l’application "
                  "ou de se conformer aux obligations légales. La version à jour est disponible dans l’application.",
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LegalMentionsScreen extends StatelessWidget {
  const LegalMentionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: NeonTheme.bgDark,
        title: const Text("Mentions légales"),
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  "MENTIONS LÉGALES – LD Connect",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  "Éditeur de l’application",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text("Leader Drive"),
                Text("Association loi 1901"),
                Text("Adresse : Pipriac, France"),
                Text("Email : Leader.driveld@gmail.com"),
                SizedBox(height: 16),
                Text(
                  "Directrice de la publication",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text("Kayza"),
                SizedBox(height: 16),
                Text(
                  "Hébergement et services",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "L’application utilise notamment les services Firebase (Google) pour l’authentification, "
                  "le stockage des données et les notifications.",
                ),
                SizedBox(height: 16),
                Text(
                  "Propriété intellectuelle",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Le logo Leader Drive, l’identité visuelle et les éléments graphiques de l’application sont la propriété "
                  "de l’association Leader Drive. Toute reproduction, modification ou utilisation non autorisée est interdite "
                  "sans l’autorisation préalable de l’association.",
                ),
                SizedBox(height: 16),
                Text(
                  "Contact",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  "Pour toute question concernant l’application ou les mentions légales :\n"
                  "Leader.driveld@gmail.com",
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> deleteAccountAndData(BuildContext context) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  final uid = user.uid;
  final fs = FirebaseFirestore.instance;

  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text("Suppression du compte en cours...")),
  );

  try {
    // Notifications
    final notifSnap = await fs
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .get();
    for (final doc in notifSnap.docs) {
      await doc.reference.delete();
    }

    // Friendships
    final friendsSnap = await fs
        .collection('friendships')
        .where('userIds', arrayContains: uid)
        .get();
    for (final doc in friendsSnap.docs) {
      await doc.reference.delete();
    }

    // Follows
    final followsSnap = await fs
        .collection('follows')
        .where('followerId', isEqualTo: uid)
        .get();
    for (final doc in followsSnap.docs) {
      await doc.reference.delete();
    }
    final followsTargetSnap = await fs
        .collection('follows')
        .where('targetId', isEqualTo: uid)
        .get();
    for (final doc in followsTargetSnap.docs) {
      await doc.reference.delete();
    }

    // Posts de l'utilisateur
    final postsSnap = await fs
        .collection('posts')
        .where('authorId', isEqualTo: uid)
        .get();
    for (final post in postsSnap.docs) {
      final commentsSnap = await post.reference.collection('comments').get();
      for (final c in commentsSnap.docs) {
        await c.reference.delete();
      }
      await post.reference.delete();
    }

    // Conversations
    final convSnap = await fs
        .collection('conversations')
        .where('participants', arrayContains: uid)
        .get();
    for (final doc in convSnap.docs) {
      await doc.reference.delete();
    }

    // User doc
    await fs.collection('users').doc(uid).delete();

    try {
      await user.delete();
    } catch (_) {
      // Si la suppression Auth échoue (manque de reauth), on se contente de supprimer les données.
    }

    await FirebaseAuth.instance.signOut();

    rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Erreur lors de la suppression: $e")),
    );
  }
}

Future<void> openReportDialog({
  required BuildContext context,
  required String type,
  String? reportedUserId,
  String? reportedUserName,
  String? postId,
  String? commentId,
  String? messageId,
  String? roomId,
  String? mediaUrl,
}) async {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) return;

  final TextEditingController reasonCtrl = TextEditingController();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text("Signaler"),
      content: TextField(
        controller: reasonCtrl,
        maxLines: 3,
        decoration: const InputDecoration(
          labelText: "Raison du signalement",
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text("Annuler"),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text("Envoyer"),
        ),
      ],
    ),
  );

  if (confirmed != true) return;
  final reason = reasonCtrl.text.trim();
  if (reason.isEmpty) return;

  final userSnap = await FirebaseFirestore.instance
      .collection('users')
      .doc(currentUser.uid)
      .get();
  final u = userSnap.data() ?? <String, dynamic>{};
  final reporterName =
      (u['pseudo'] ?? u['email'] ?? 'Inconnu').toString();

  await FirebaseFirestore.instance.collection('reports').add({
    'type': type,
    'reportedUserId': reportedUserId,
    'reportedUserName': reportedUserName,
    'reporterId': currentUser.uid,
    'reporterName': reporterName,
    'postId': postId,
    'commentId': commentId,
    'messageId': messageId,
    'roomId': roomId,
    'mediaUrl': mediaUrl,
    'reason': reason,
    'resolved': false,
    'createdAt': FieldValue.serverTimestamp(),
  });

  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text("Signalement envoyé.")),
  );
}

// --- 3. HOME & SALONS ---
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 50),
        const Text(
          "LD Connect",
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w900,
            color: NeonTheme.accent,
          ),
        ),
        const SizedBox(height: 16),
        _actionTile(
          context,
          "Safe Place",
          Colors.blue,
          Icons.security,
          () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const SafePlaceScreen(),
                ),
              ),
        ),
      ],
    );
  }

  Widget _actionTile(
    BuildContext context,
    String t,
    Color c,
    IconData i,
    VoidCallback tap,
  ) {
    return GestureDetector(
      onTap: tap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        height: 60,
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [Icon(i), const SizedBox(width: 10), Text(t)],
        ),
      ),
    );
  }

  void _showCreate(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => const CreateRoomSheet(),
    );
  }

  void _enterRoom(BuildContext context, String id, String name) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatRoomScreen(roomId: id, roomName: name),
      ),
    );
  }
}

class PrivateChatScreen extends StatefulWidget {
  final String conversationId;
  final String otherUserId;
  final String otherPseudo;

  const PrivateChatScreen({
    super.key,
    required this.conversationId,
    required this.otherUserId,
    required this.otherPseudo,
  });

  @override
  State<PrivateChatScreen> createState() => _PrivateChatScreenState();
}

class _PrivateChatScreenState extends State<PrivateChatScreen> {
  final TextEditingController _ctrl = TextEditingController();
  String? _myPseudo;
  bool _uploadingImage = false;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      FirebaseFirestore.instance.collection('users').doc(uid).get().then((s) {
        if (!mounted) return;
        final d = s.data();
        setState(() {
          _myPseudo = (d?['pseudo'] ?? d?['email'] ?? 'Moi').toString();
        });
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
      });
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final currentUid = currentUser.uid;

    final convoRef = FirebaseFirestore.instance
        .collection('conversations')
        .doc(widget.conversationId);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: NeonTheme.bgDark,
        title: GestureDetector(
          onTap: () {
            if (widget.otherUserId == currentUid) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const UserProfileScreen(),
                ),
              );
            } else {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PublicProfileScreen(userId: widget.otherUserId),
                ),
              );
            }
          },
          child: Text(widget.otherPseudo),
        ),
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<DocumentSnapshot>(
                stream: convoRef.snapshots(),
                builder: (context, convoSnap) {
                  if (!convoSnap.hasData || !convoSnap.data!.exists) {
                    return const Center(
                      child: Text("Conversation introuvable."),
                    );
                  }
                  final convo =
                      convoSnap.data!.data() as Map<String, dynamic>;
                  final status = (convo['status'] ?? '').toString();
                  final requestTo = (convo['requestTo'] ?? '').toString();

                  final isRequest = status == 'request';
                  final isRecipient = isRequest && requestTo == currentUid;
                  final isDeclined = status == 'declined';

                  return Column(
                    children: [
                      if (isDeclined)
                        Container(
                          width: double.infinity,
                          color: Colors.red.withValues(alpha: 0.2),
                          padding: const EdgeInsets.all(8),
                          child: const Text(
                            "Cette demande de message a été refusée.",
                            textAlign: TextAlign.center,
                          ),
                        )
                      else if (isRecipient)
                        Container(
                          width: double.infinity,
                          color: NeonTheme.surface.withValues(alpha: 0.8),
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            children: [
                              const Text(
                                "Nouvelle demande de message",
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                "Accepter pour discuter avec cette personne ou refuser pour ignorer.",
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  TextButton(
                                    onPressed: () async {
                                      await convoRef.update({
                                        'status': 'declined',
                                      });
                                    },
                                    child: const Text(
                                      "Refuser",
                                      style: TextStyle(color: Colors.redAccent),
                                    ),
                                  ),
                                  ElevatedButton(
                                    onPressed: () async {
                                      await convoRef.update({
                                        'status': 'accepted',
                                        'requestTo': null,
                                      });
                                    },
                                    child: const Text("Accepter"),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        )
                      else if (isRequest)
                        Container(
                          width: double.infinity,
                          color: NeonTheme.surface.withValues(alpha: 0.8),
                          padding: const EdgeInsets.all(8),
                          child: const Text(
                            "Demande envoyée. En attente d’acceptation.",
                            textAlign: TextAlign.center,
                          ),
                        ),
                      Expanded(
                        child: StreamBuilder<QuerySnapshot>(
                          stream: convoRef
                              .collection('messages')
                              .orderBy('timestamp', descending: true)
                              .limit(100)
                              .snapshots(),
                          builder: (context, snap) {
                            if (!snap.hasData) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            final docs = snap.data!.docs;
                            if (docs.isEmpty) {
                              return const Center(
                                child: Text(
                                  "Aucun message pour le moment.",
                                  textAlign: TextAlign.center,
                                ),
                              );
                            }
                            return ListView.builder(
                              reverse: true,
                              itemCount: docs.length,
                              itemBuilder: (context, index) {
                                final doc = docs[index];
                                final data =
                                    doc.data() as Map<String, dynamic>;
                                final text =
                                    (data['text'] ?? '').toString();
                                final imageUrl =
                                    data['imageUrl'] as String?;
                                final sender =
                                    (data['senderId'] ?? '').toString();
                                final isMe = sender == currentUid;
                                final nameLabel =
                                    isMe ? (_myPseudo ?? 'Moi') : widget.otherPseudo;

                                return Align(
                                  alignment: isMe
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 4,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    child: Column(
                                      crossAxisAlignment: isMe
                                          ? CrossAxisAlignment.end
                                          : CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: EdgeInsets.only(
                                            left: isMe ? 0 : 4,
                                            right: isMe ? 4 : 0,
                                            bottom: 2,
                                          ),
                                          child: Text(
                                            nameLabel,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isMe
                                                ? NeonTheme.neonBlue
                                                    .withValues(alpha: 0.9)
                                                : Colors.black
                                                    .withValues(alpha: 0.55),
                                            borderRadius:
                                                BorderRadius.circular(18),
                                            boxShadow: [
                                              if (isMe)
                                                BoxShadow(
                                                  color: NeonTheme.neonBlue
                                                      .withValues(alpha: 0.4),
                                                  blurRadius: 16,
                                                  offset:
                                                      const Offset(0, 4),
                                                ),
                                            ],
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (imageUrl != null &&
                                                  imageUrl.isNotEmpty)
                                                GestureDetector(
                                                  onTap: () =>
                                                      openFullscreenImageUrl(
                                                    context,
                                                    imageUrl,
                                                  ),
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
                                                    child: ConstrainedBox(
                                                      constraints:
                                                          const BoxConstraints(
                                                        maxWidth: 220,
                                                        maxHeight: 220,
                                                      ),
                                                      child: Image.network(
                                                        imageUrl,
                                                        fit: BoxFit.cover,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              if (text.isNotEmpty) ...[
                                                if (imageUrl != null &&
                                                    imageUrl.isNotEmpty)
                                                  const SizedBox(height: 6),
                                                Text(
                                                  text,
                                                  style: TextStyle(
                                                    color: isMe
                                                        ? Colors.black
                                                        : Colors.white,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            _buildInputBar(convoRef, currentUid),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(
    DocumentReference convoRef,
    String currentUid,
  ) {
    return StreamBuilder<DocumentSnapshot>(
      stream: convoRef.snapshots(),
      builder: (context, snap) {
        bool canSend = true;
        if (snap.hasData && snap.data!.exists) {
          final convo = snap.data!.data() as Map<String, dynamic>;
          final status = (convo['status'] ?? '').toString();
          final requestTo = (convo['requestTo'] ?? '').toString();
          final isRecipient = status == 'request' && requestTo == currentUid;
          final isDeclined = status == 'declined';
          if (isRecipient || isDeclined) {
            canSend = false;
          }
        }

        return SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            color: NeonTheme.surface2.withValues(alpha: 0.9),
            child: Row(
              children: [
                if (_uploadingImage)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.photo_library_outlined),
                    color: canSend ? NeonTheme.neonBlue : Colors.grey,
                    onPressed: canSend
                        ? () => _pickAndSendImage(convoRef, currentUid)
                        : null,
                  ),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    enabled: canSend && !_uploadingImage,
                    decoration: InputDecoration(
                      hintText: canSend
                          ? "Écrire un message..."
                          : "En attente d’acceptation",
                      border: InputBorder.none,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  color: canSend && !_uploadingImage
                      ? NeonTheme.neonBlue
                      : Colors.grey,
                  onPressed: canSend && !_uploadingImage
                      ? () => _send(convoRef, currentUid)
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _send(DocumentReference convoRef, String currentUid) async {
    if (_ctrl.text.trim().isEmpty) return;
    if (!await _checkUserNotBannedForAction(context)) {
      return;
    }
    final text = _ctrl.text.trim();
    _ctrl.clear();

    final messagesRef = convoRef.collection('messages');
    await messagesRef.add({
      'text': text,
      'senderId': currentUid,
      'timestamp': FieldValue.serverTimestamp(),
    });

    await convoRef.update({
      'lastMessage': text,
      'lastMessageAt': FieldValue.serverTimestamp(),
    });

    // XP pour message privé envoyé
    await _awardXp(currentUid, 1);
  }

  Future<void> _pickAndSendImage(
    DocumentReference convoRef,
    String currentUid,
  ) async {
    if (!await _checkUserNotBannedForAction(context)) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 88,
    );
    if (picked == null || !mounted) return;
    setState(() => _uploadingImage = true);
    try {
      final file = File(picked.path);
      final ref = FirebaseStorage.instance.ref().child(
            'conversations/${widget.conversationId}/${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
      await ref.putFile(file);
      final url = await ref.getDownloadURL();
      final messagesRef = convoRef.collection('messages');
      await messagesRef.add({
        'text': '',
        'imageUrl': url,
        'senderId': currentUid,
        'timestamp': FieldValue.serverTimestamp(),
      });
      await convoRef.update({
        'lastMessage': '📷 Photo',
        'lastMessageAt': FieldValue.serverTimestamp(),
      });
      await _awardXp(currentUid, 1);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Envoi de la photo : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }
}

// --- 4. MATES (RECHERCHE DE JOUEURS + MESSAGES PRIVÉS) ---
class MatesScreen extends StatefulWidget {
  const MatesScreen({super.key});

  @override
  State<MatesScreen> createState() => _MatesScreenState();
}

class _MatesScreenState extends State<MatesScreen>
    with SingleTickerProviderStateMixin {
  String _gameFilter = 'Tous';
  String _rankFilter = 'Tous';
  String _modeFilter = 'Tous';
  String _micFilter = 'Tous';
  String _playerSearch = '';

  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 1, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
      });
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        const SizedBox(height: 40),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              Text(
                "TROUVER DES JOUEURS",
                style: NeonTheme.sectionTitle(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: NeonTheme.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: NeonTheme.accent.withValues(alpha: 0.25),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: NeonTheme.accent.withValues(alpha: 0.08),
                blurRadius: 16,
                spreadRadius: 1,
              ),
            ],
          ),
          child: TabBar(
            controller: _tabController,
            indicator: BoxDecoration(
              color: NeonTheme.neonBlue.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorPadding: const EdgeInsets.all(4),
            dividerColor: Colors.transparent,
            labelColor: NeonTheme.neonBlue,
            unselectedLabelColor: Colors.white70,
            labelStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
            unselectedLabelStyle: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            tabs: const [
              Tab(text: "Joueurs"),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildPlayersTab(currentUid),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlayersTab(String currentUid) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            decoration:
                NeonTheme.inputStyle("Rechercher un joueur...", icon: Icons.search),
            onChanged: (value) {
              setState(() {
                _playerSearch = value.trim().toLowerCase();
              });
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              onPressed: _openFiltersSheet,
              icon: const Icon(Icons.filter_list),
              label: const Text("Filtres"),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .orderBy('pseudo')
                  .limit(50)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(
                    child: Text("Erreur de chargement des joueurs."),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snap.data!.docs;

                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('friendships')
                      .where('userIds', arrayContains: currentUid)
                      .snapshots(),
                  builder: (context, friendsSnap) {
                    final Map<String, Map<String, dynamic>> relations = {};
                    if (friendsSnap.hasData) {
                      for (final d in friendsSnap.data!.docs) {
                        final data = d.data() as Map<String, dynamic>;
                        final ids =
                            List<String>.from((data['userIds'] as List?) ?? []);
                        if (ids.length != 2) continue;
                        final otherId =
                            ids.firstWhere((id) => id != currentUid, orElse: () => '');
                        if (otherId.isEmpty) continue;
                        relations[otherId] = {
                          'status': (data['status'] ?? 'accepted').toString(),
                          'requestFrom': (data['requestFrom'] ?? '').toString(),
                          'requestTo': (data['requestTo'] ?? '').toString(),
                          'blockedBy': (data['blockedBy'] ?? '').toString(),
                        };
                      }
                    }

                    final filtered = docs.where((d) {
                      final data = d.data() as Map<String, dynamic>;
                      final uid = (data['uid'] ?? d.id).toString();
                      if (uid == currentUid) return false;

                       final relation = relations[uid];
                       if (relation != null &&
                           relation['status'] == 'blocked' &&
                           (relation['blockedBy'] as String).isNotEmpty) {
                         return false;
                       }

                      final game = (data['game'] ?? '').toString();
                      final rank = (data['rank'] ?? '').toString();
                      final mode = (data['mode'] ?? '').toString();
                      final hasMic = (data['hasMic'] ?? false) as bool;

                      if (_playerSearch.isNotEmpty) {
                        final pseudo =
                            (data['pseudo'] ?? data['email'] ?? '')
                                .toString()
                                .toLowerCase();
                        if (!pseudo.contains(_playerSearch)) {
                          return false;
                        }
                      }

                      if (_gameFilter != 'Tous' && game != _gameFilter) {
                        return false;
                      }
                      if (_rankFilter != 'Tous' && rank != _rankFilter) {
                        return false;
                      }
                      if (_modeFilter != 'Tous' && mode != _modeFilter) {
                        return false;
                      }
                      if (_micFilter == 'Avec micro' && !hasMic) {
                        return false;
                      }
                      if (_micFilter == 'Sans micro' && hasMic) {
                        return false;
                      }
                      return true;
                    }).toList();

                    if (filtered.isEmpty) {
                      return const Center(
                        child: Text(
                          "Aucun joueur ne correspond à ces filtres.",
                          textAlign: TextAlign.center,
                        ),
                      );
                    }

                    return ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final doc = filtered[index];
                        final data = doc.data() as Map<String, dynamic>;
                        final uid = (data['uid'] ?? doc.id).toString();
                        final pseudo =
                            (data['pseudo'] ?? data['email'] ?? 'Joueur')
                                .toString();
                        final game = (data['game'] ?? '').toString();
                        final rank = (data['rank'] ?? '').toString();
                        final avatarUrl = data['avatarUrl'] as String?;
                        final hasMic = (data['hasMic'] ?? false) as bool;
                        final relation = relations[uid];

                        return _MateCard(
                          uid: uid,
                          pseudo: pseudo,
                          game: game,
                          rank: rank,
                          avatarUrl: avatarUrl,
                          hasMic: hasMic,
                          friendshipStatus:
                              relation != null ? relation['status'] as String : null,
                          friendshipRequestFrom: relation != null
                              ? relation['requestFrom'] as String
                              : null,
                          friendshipRequestTo: relation != null
                              ? relation['requestTo'] as String
                              : null,
                          friendshipBlockedBy: relation != null
                              ? relation['blockedBy'] as String
                              : null,
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _openFiltersSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: NeonTheme.surface2.withValues(alpha: 0.98),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.only(
            left: 18,
            right: 18,
            top: 12,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 18,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  "Filtres",
                  style: NeonTheme.sectionTitle(),
                  textAlign: TextAlign.left,
                ),
                const SizedBox(height: 12),
                _buildFilters(),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("Appliquer"),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFilters() {
    const ranks = [
      'Tous',
      'Bronze',
      'Argent',
      'Or',
      'Platine',
      'Diamant',
      'Champion 1',
      'Champion 2',
      'Champion 3',
      'Grand Champion 1',
      'Grand Champion 2',
      'Grand Champion 3',
      'Supersonic Legend',
    ];

    const modes = ['Tous', '1v1', '2v2', '3v3'];

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _gameFilter,
                decoration: NeonTheme.inputStyle("Jeu"),
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'Tous', child: Text("Tous les jeux")),
                  DropdownMenuItem(
                    value: 'Rocket League',
                    child: Text("Rocket League"),
                  ),
                ],
                onChanged: (v) =>
                    setState(() => _gameFilter = v ?? 'Tous'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _rankFilter,
                decoration: NeonTheme.inputStyle("Niveau"),
                isExpanded: true,
                items: ranks
                    .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _rankFilter = v ?? 'Tous'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _modeFilter,
                decoration: NeonTheme.inputStyle("Mode"),
                isExpanded: true,
                items: modes
                    .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _modeFilter = v ?? 'Tous'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _micFilter,
                decoration: NeonTheme.inputStyle("Micro"),
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'Tous', child: Text("Tous")),
                  DropdownMenuItem(
                      value: 'Avec micro', child: Text("Avec micro")),
                  DropdownMenuItem(
                      value: 'Sans micro', child: Text("Sans micro")),
                ],
                onChanged: (v) =>
                    setState(() => _micFilter = v ?? 'Tous'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMessagesTab(String currentUid) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Conversations",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('conversations')
                  .where('participants', arrayContains: currentUid)
                  .where('status', isEqualTo: 'accepted')
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(
                    child: Text("Erreur de chargement des conversations."),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      "Aucune conversation pour le moment.",
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final userAId = (data['userAId'] ?? '').toString();
                    final userBId = (data['userBId'] ?? '').toString();
                    final userAName =
                        (data['userAName'] ?? 'Joueur').toString();
                    final userBName =
                        (data['userBName'] ?? 'Joueur').toString();
                    final lastMessage =
                        (data['lastMessage'] ?? '').toString();

                    final isA = currentUid == userAId;
                    final otherId = isA ? userBId : userAId;
                    final otherName = isA ? userBName : userAName;

                    return _ConversationTile(
                      otherId: otherId,
                      otherName: otherName,
                      lastMessage: lastMessage,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PrivateChatScreen(
                              conversationId: doc.id,
                              otherUserId: otherId,
                              otherPseudo: otherName,
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            "Demandes de messages",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 160,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('conversations')
                  .where('requestTo', isEqualTo: currentUid)
                  .where('status', isEqualTo: 'request')
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(
                    child: Text("Erreur de chargement des demandes."),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      "Aucune demande pour l’instant.",
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final userAId = (data['userAId'] ?? '').toString();
                    final userBId = (data['userBId'] ?? '').toString();
                    final userAName =
                        (data['userAName'] ?? 'Joueur').toString();
                    final userBName =
                        (data['userBName'] ?? 'Joueur').toString();

                    final isA = currentUid == userAId;
                    final otherId = isA ? userBId : userAId;
                    final otherName = isA ? userBName : userAName;

                    return GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PrivateChatScreen(
                              conversationId: doc.id,
                              otherUserId: otherId,
                              otherPseudo: otherName,
                            ),
                          ),
                        );
                      },
                      child: Container(
                        width: 220,
                        padding: const EdgeInsets.all(12),
                        decoration: NeonTheme.neonCardDecoration(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => PublicProfileScreen(userId: otherId),
                                  ),
                                );
                              },
                              child: Text(
                                otherName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              "Souhaite te contacter.",
                              style: TextStyle(color: Colors.white70),
                            ),
                            const Spacer(),
                            const Text(
                              "Appuie pour voir la demande",
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildFriendsTab(String currentUid) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('friendships')
            .where('userIds', arrayContains: currentUid)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(
              child: Text("Erreur de chargement des amis."),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text(
                "Aucun ami pour le moment.\nAjoute des joueurs depuis l’onglet Joueurs.",
                textAlign: TextAlign.center,
              ),
            );
          }

          final List<Map<String, dynamic>> incomingRequests = [];
          final List<Map<String, dynamic>> friends = [];
          final List<Map<String, dynamic>> blocked = [];

          for (final d in docs) {
            final data = d.data() as Map<String, dynamic>;
            final ids =
                List<String>.from((data['userIds'] as List?) ?? const <String>[]);
            if (ids.length != 2) continue;
            final otherId =
                ids.firstWhere((id) => id != currentUid, orElse: () => '');
            if (otherId.isEmpty) continue;
            final status = (data['status'] ?? 'accepted').toString();
            final requestTo = (data['requestTo'] ?? '').toString();
            final blockedBy = (data['blockedBy'] ?? '').toString();

            if (status == 'request' && requestTo == currentUid) {
              incomingRequests.add({
                'userId': otherId,
              });
            } else if (status == 'accepted') {
              friends.add({
                'userId': otherId,
              });
            } else if (status == 'blocked' && blockedBy == currentUid) {
              blocked.add({
                'userId': otherId,
              });
            }
          }

          return ListView(
            children: [
              if (incomingRequests.isNotEmpty) ...[
                const Text(
                  "Demandes d’amis",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 8),
                ...incomingRequests.map((item) {
                  final otherId = item['userId'] as String;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: FutureBuilder<DocumentSnapshot>(
                      future: FirebaseFirestore.instance
                          .collection('users')
                          .doc(otherId)
                          .get(),
                      builder: (context, userSnap) {
                        if (!userSnap.hasData || !userSnap.data!.exists) {
                          return const SizedBox.shrink();
                        }
                        final u = userSnap.data!.data() as Map<String, dynamic>;
                        final pseudo =
                            (u['pseudo'] ?? u['email'] ?? 'Joueur').toString();
                        final rank = (u['rank'] ?? '').toString();
                        final avatarUrl = u['avatarUrl'] as String?;
                        return _FriendTile(
                          otherId: otherId,
                          pseudo: pseudo,
                          subtitle: rank.isNotEmpty ? "Niveau: $rank" : null,
                          avatarUrl: avatarUrl,
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PublicProfileScreen(userId: otherId),
                              ),
                            );
                          },
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.red),
                                onPressed: () {
                                  _MateCard.removeFriendship(
                                    context,
                                    currentUid: currentUid,
                                    otherUid: otherId,
                                  );
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.check, color: Colors.green),
                                onPressed: () {
                                  _MateCard._acceptFriendRequest(
                                    context,
                                    currentUid: currentUid,
                                    otherUid: otherId,
                                  );
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  );
                }),
                const SizedBox(height: 16),
              ],
              const Text(
                "Amis",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 8),
              if (friends.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    "Aucun ami pour le moment.",
                    style: TextStyle(color: Colors.white60),
                  ),
                )
              else
                ...friends.map((item) {
                  final otherId = item['userId'] as String;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: FutureBuilder<DocumentSnapshot>(
                      future: FirebaseFirestore.instance
                          .collection('users')
                          .doc(otherId)
                          .get(),
                      builder: (context, userSnap) {
                        if (!userSnap.hasData || !userSnap.data!.exists) {
                          return const SizedBox.shrink();
                        }
                        final u = userSnap.data!.data() as Map<String, dynamic>;
                        final pseudo =
                            (u['pseudo'] ?? u['email'] ?? 'Joueur').toString();
                        final rank = (u['rank'] ?? '').toString();
                        final avatarUrl = u['avatarUrl'] as String?;
                        return _FriendTile(
                          otherId: otherId,
                          pseudo: pseudo,
                          subtitle: rank.isNotEmpty ? "Niveau: $rank" : null,
                          avatarUrl: avatarUrl,
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PublicProfileScreen(userId: otherId),
                              ),
                            );
                          },
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon:
                                    const Icon(Icons.block, color: Colors.orange),
                                onPressed: () {
                                  _MateCard.blockUser(
                                    context,
                                    currentUid: currentUid,
                                    otherUid: otherId,
                                  );
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.red),
                                onPressed: () {
                                  _MateCard.removeFriendship(
                                    context,
                                    currentUid: currentUid,
                                    otherUid: otherId,
                                  );
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  );
                }),
              const SizedBox(height: 16),
              const Text(
                "Bloqués",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 8),
              if (blocked.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: NeonTheme.neonCardDecoration(),
                  child: const Text(
                  "Personne n’est bloqué.",
                    style: TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                ...blocked.map((item) {
                  final otherId = item['userId'] as String;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: FutureBuilder<DocumentSnapshot>(
                      future: FirebaseFirestore.instance
                          .collection('users')
                          .doc(otherId)
                          .get(),
                      builder: (context, userSnap) {
                        if (!userSnap.hasData || !userSnap.data!.exists) {
                          return const SizedBox.shrink();
                        }
                        final u = userSnap.data!.data() as Map<String, dynamic>;
                        final pseudo =
                            (u['pseudo'] ?? u['email'] ?? 'Joueur').toString();
                        final avatarUrl = u['avatarUrl'] as String?;
                        return _FriendTile(
                          otherId: otherId,
                          pseudo: pseudo,
                          subtitle: null,
                          avatarUrl: avatarUrl,
                          blockedStyle: true,
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PublicProfileScreen(userId: otherId),
                              ),
                            );
                          },
                          trailing: OutlinedButton.icon(
                            onPressed: () {
                              _MateCard.unblockUser(
                                context,
                                currentUid: currentUid,
                                otherUid: otherId,
                              );
                            },
                            icon: const Icon(Icons.block_outlined, size: 18),
                            label: const Text("Débloquer"),
                          ),
                        );
                      },
                    ),
                  );
                }),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}

class _FriendTile extends StatelessWidget {
  final String otherId;
  final String pseudo;
  final String? subtitle;
  final String? avatarUrl;
  final VoidCallback onTap;
  final Widget trailing;
  final bool blockedStyle;

  const _FriendTile({
    required this.otherId,
    required this.pseudo,
    this.subtitle,
    this.avatarUrl,
    required this.onTap,
    required this.trailing,
    this.blockedStyle = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: _NeonCard(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: NeonTheme.surface2.withValues(alpha: 0.8),
                backgroundImage:
                    avatarUrl != null ? NetworkImage(avatarUrl!) : null,
                child: avatarUrl == null
                    ? Icon(
                        blockedStyle ? Icons.block : Icons.person,
                        size: 32,
                        color: blockedStyle ? Colors.orangeAccent : Colors.white70,
                      )
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pseudo,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: Colors.white,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _FriendRequestTile extends StatelessWidget {
  final String friendshipId;
  final String currentUid;
  final String otherId;

  const _FriendRequestTile({
    required this.friendshipId,
    required this.currentUid,
    required this.otherId,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future:
          FirebaseFirestore.instance.collection('users').doc(otherId).get(),
      builder: (context, userSnap) {
        if (!userSnap.hasData || !userSnap.data!.exists) {
          return const SizedBox.shrink();
        }
        final u = userSnap.data!.data() as Map<String, dynamic>;
        final pseudo =
            (u['pseudo'] ?? u['email'] ?? 'Joueur').toString();
        final rank = (u['rank'] ?? '').toString();
        final avatarUrl = u['avatarUrl'] as String?;
        return _FriendTile(
          otherId: otherId,
          pseudo: pseudo,
          subtitle: rank.isNotEmpty ? "Niveau: $rank" : null,
          avatarUrl: avatarUrl,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PublicProfileScreen(userId: otherId),
              ),
            );
          },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.red),
                onPressed: () {
                  _MateCard.removeFriendship(
                    context,
                    currentUid: currentUid,
                    otherUid: otherId,
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.check, color: Colors.green),
                onPressed: () {
                  _MateCard._acceptFriendRequest(
                    context,
                    currentUid: currentUid,
                    otherUid: otherId,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FriendItem extends StatelessWidget {
  final String friendshipId;
  final String currentUid;
  final String otherId;

  const _FriendItem({
    required this.friendshipId,
    required this.currentUid,
    required this.otherId,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future:
          FirebaseFirestore.instance.collection('users').doc(otherId).get(),
      builder: (context, userSnap) {
        if (!userSnap.hasData || !userSnap.data!.exists) {
          return const SizedBox.shrink();
        }
        final u = userSnap.data!.data() as Map<String, dynamic>;
        final pseudo =
            (u['pseudo'] ?? u['email'] ?? 'Joueur').toString();
        final rank = (u['rank'] ?? '').toString();
        final avatarUrl = u['avatarUrl'] as String?;
        return _FriendTile(
          otherId: otherId,
          pseudo: pseudo,
          subtitle: rank.isNotEmpty ? "Niveau: $rank" : null,
          avatarUrl: avatarUrl,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PublicProfileScreen(userId: otherId),
              ),
            );
          },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.block, color: Colors.orange),
                onPressed: () {
                  _MateCard.blockUser(
                    context,
                    currentUid: currentUid,
                    otherUid: otherId,
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () {
                  _MateCard.removeFriendship(
                    context,
                    currentUid: currentUid,
                    otherUid: otherId,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OutgoingFriendRequestTile extends StatelessWidget {
  final String friendshipId;
  final String currentUid;
  final String otherId;

  const _OutgoingFriendRequestTile({
    required this.friendshipId,
    required this.currentUid,
    required this.otherId,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future:
          FirebaseFirestore.instance.collection('users').doc(otherId).get(),
      builder: (context, userSnap) {
        if (!userSnap.hasData || !userSnap.data!.exists) {
          return const SizedBox.shrink();
        }
        final u = userSnap.data!.data() as Map<String, dynamic>;
        final pseudo =
            (u['pseudo'] ?? u['email'] ?? 'Joueur').toString();
        final avatarUrl = u['avatarUrl'] as String?;
        return _FriendTile(
          otherId: otherId,
          pseudo: pseudo,
          subtitle: "Demande envoyée",
          avatarUrl: avatarUrl,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PublicProfileScreen(userId: otherId),
              ),
            );
          },
          trailing: TextButton(
            onPressed: () {
              _MateCard.removeFriendship(
                context,
                currentUid: currentUid,
                otherUid: otherId,
              );
            },
            child: const Text("Annuler"),
          ),
        );
      },
    );
  }
}

class _BlockedFriendTile extends StatelessWidget {
  final String friendshipId;
  final String currentUid;
  final String otherId;

  const _BlockedFriendTile({
    required this.friendshipId,
    required this.currentUid,
    required this.otherId,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future:
          FirebaseFirestore.instance.collection('users').doc(otherId).get(),
      builder: (context, userSnap) {
        if (!userSnap.hasData || !userSnap.data!.exists) {
          return const SizedBox.shrink();
        }
        final u = userSnap.data!.data() as Map<String, dynamic>;
        final pseudo =
            (u['pseudo'] ?? u['email'] ?? 'Joueur').toString();
        final avatarUrl = u['avatarUrl'] as String?;
        return _FriendTile(
          otherId: otherId,
          pseudo: pseudo,
          subtitle: null,
          avatarUrl: avatarUrl,
          blockedStyle: true,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PublicProfileScreen(userId: otherId),
              ),
            );
          },
          trailing: OutlinedButton.icon(
            onPressed: () {
              _MateCard.unblockUser(
                context,
                currentUid: currentUid,
                otherUid: otherId,
              );
            },
            icon: const Icon(Icons.block_outlined, size: 18),
            label: const Text("Débloquer"),
          ),
        );
      },
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final String otherId;
  final String otherName;
  final String lastMessage;
  final VoidCallback onTap;

  const _ConversationTile({
    required this.otherId,
    required this.otherName,
    required this.lastMessage,
    required this.onTap,
  });

  void _openProfile(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (otherId == currentUid) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const UserProfileScreen(),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PublicProfileScreen(userId: otherId),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: _NeonCard(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: FutureBuilder<DocumentSnapshot>(
            future: FirebaseFirestore.instance
                .collection('users')
                .doc(otherId)
                .get(),
            builder: (context, snap) {
              String? avatarUrl;
              var displayName = otherName.trim();
              if (snap.hasData &&
                  snap.data!.exists &&
                  snap.data!.data() != null) {
                final data =
                    snap.data!.data() as Map<String, dynamic>? ?? {};
                avatarUrl = data['avatarUrl'] as String?;
                final p = (data['pseudo'] ?? '').toString().trim();
                final e = (data['email'] ?? '').toString().trim();
                if (p.isNotEmpty) {
                  displayName = p;
                } else if (e.isNotEmpty) {
                  displayName = e;
                }
              }
              if (displayName.isEmpty) {
                displayName = 'Joueur';
              }

              return Row(
                children: [
                  GestureDetector(
                    onTap: () => _openProfile(context),
                    child: CircleAvatar(
                      radius: 28,
                      backgroundColor:
                          NeonTheme.surface2.withValues(alpha: 0.8),
                      backgroundImage: avatarUrl != null
                          ? NetworkImage(avatarUrl)
                          : null,
                      child: avatarUrl == null
                          ? const Icon(Icons.person,
                              size: 32, color: Colors.white70)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: () => _openProfile(context),
                          child: Text(
                            displayName,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              color: NeonTheme.neonBlue,
                              shadows: [
                                Shadow(
                                  color: NeonTheme.neonBlue.withValues(alpha: 0.35),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (lastMessage.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            lastMessage,
                            style: TextStyle(
                              fontSize: 13,
                              color:
                                  Colors.white.withValues(alpha: 0.72),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: NeonTheme.neonBlue.withValues(alpha: 0.8),
                    size: 24,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MateCard extends StatelessWidget {
  final String uid;
  final String pseudo;
  final String game;
  final String rank;
  final String? avatarUrl;
  final bool hasMic;
  final String? friendshipStatus;
  final String? friendshipRequestFrom;
  final String? friendshipRequestTo;
  final String? friendshipBlockedBy;

  const _MateCard({
    required this.uid,
    required this.pseudo,
    required this.game,
    required this.rank,
    required this.avatarUrl,
    required this.hasMic,
    this.friendshipStatus,
    this.friendshipRequestFrom,
    this.friendshipRequestTo,
    this.friendshipBlockedBy,
  });

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser!.uid;
    final isSelf = currentUid == uid;

    final status = friendshipStatus ?? '';
    final isBlocked =
        status == 'blocked' && (friendshipBlockedBy ?? '').isNotEmpty;

    String mainButtonText = "Ajouter";
    VoidCallback? mainButtonOnPressed;
    bool mainButtonEnabled = true;

    if (isSelf) {
      mainButtonEnabled = false;
    } else if (status.isEmpty) {
      mainButtonText = "Ajouter";
      mainButtonOnPressed = () => _sendFriendRequest(
            context: context,
            currentUid: currentUid,
            otherUid: uid,
          );
    } else if (status == 'request') {
      final isRequester = friendshipRequestFrom == currentUid;
      final isRecipient = friendshipRequestTo == currentUid;
      if (isRequester) {
        mainButtonText = "En attente";
        mainButtonEnabled = false;
      } else if (isRecipient) {
        mainButtonText = "Accepter";
        mainButtonOnPressed = () => _acceptFriendRequest(
              context,
              currentUid: currentUid,
              otherUid: uid,
            );
      } else {
        mainButtonText = "En attente";
        mainButtonEnabled = false;
      }
    } else if (status == 'accepted') {
      mainButtonText = "Ami";
      mainButtonEnabled = false;
    } else if (status == 'blocked') {
      mainButtonText = "Bloqué";
      mainButtonEnabled = false;
    }

    return _NeonCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            GestureDetector(
              onTap: () {
                if (uid == currentUid) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const UserProfileScreen(),
                    ),
                  );
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PublicProfileScreen(userId: uid),
                    ),
                  );
                }
              },
              child: CircleAvatar(
                radius: 24,
                backgroundColor: NeonTheme.surface2,
                backgroundImage:
                    avatarUrl != null ? NetworkImage(avatarUrl!) : null,
                child: avatarUrl == null
                    ? const Icon(Icons.person, color: Colors.white70)
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTap: () {
                  if (uid == currentUid) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const UserProfileScreen(),
                      ),
                    );
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PublicProfileScreen(userId: uid),
                      ),
                    );
                  }
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  Text(
                    pseudo,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "$game • $rank",
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        hasMic ? Icons.mic : Icons.mic_off,
                        size: 16,
                        color: hasMic ? NeonTheme.neonBlue : Colors.white38,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        hasMic ? "Micro" : "Sans micro",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white60,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
            if (!isSelf)
              Column(
                children: [
                  SizedBox(
                    height: 32,
                    child: ElevatedButton(
                      onPressed: mainButtonEnabled ? mainButtonOnPressed : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            mainButtonEnabled ? NeonTheme.neonBlue : Colors.grey,
                      ),
                      child: Text(mainButtonText),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 32,
                    child: OutlinedButton(
                      onPressed: isBlocked
                          ? null
                          : () => _openChat(context, uid, pseudo),
                      child: const Text("Message"),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static Future<void> _sendFriendRequest({
    required BuildContext context,
    required String currentUid,
    required String otherUid,
  }) async {
    if (!await _checkUserNotBannedForAction(context)) {
      return;
    }
    try {
      final ids = [currentUid, otherUid]..sort();
      final friendshipId = "${ids[0]}_${ids[1]}";
      final ref = FirebaseFirestore.instance
          .collection('friendships')
          .doc(friendshipId);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) {
          tx.set(ref, {
            'userIds': ids,
            'userAId': ids[0],
            'userBId': ids[1],
            'createdAt': FieldValue.serverTimestamp(),
            'status': 'request',
            'requestFrom': currentUid,
            'requestTo': otherUid,
            'blockedBy': null,
          });
        } else {
          final data = snap.data() as Map<String, dynamic>;
          final currentStatus = (data['status'] ?? '').toString();
          final requestTo = (data['requestTo'] ?? '').toString();
          final requestFrom = (data['requestFrom'] ?? '').toString();

          if (currentStatus == 'request' &&
              requestTo == currentUid &&
              requestFrom == otherUid) {
            // L'autre t’avait déjà envoyé une demande, on accepte automatiquement
            tx.update(ref, {
              'status': 'accepted',
              'requestFrom': null,
              'requestTo': null,
              'blockedBy': null,
            });
            final users = FirebaseFirestore.instance.collection('users');
            tx.update(
              users.doc(currentUid),
              {'friendsCount': FieldValue.increment(1)},
            );
            tx.update(
              users.doc(otherUid),
              {'friendsCount': FieldValue.increment(1)},
            );
          }
        }
      });

      try {
        final currentUserSnap = await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUid)
            .get();
        final currentUserData =
            currentUserSnap.data() ?? <String, dynamic>{};
        final fromName = (currentUserData['pseudo'] ??
                currentUserData['email'] ??
                'Quelqu\'un')
            .toString();

        await FirebaseFirestore.instance
            .collection('users')
            .doc(otherUid)
            .collection('notifications')
            .add({
          'type': 'friend_request',
          'message': "$fromName t'a envoyé une demande d'ami",
          'postId': '',
          'commentId': null,
          'fromUserId': currentUid,
          'fromUserName': fromName,
          'timestamp': FieldValue.serverTimestamp(),
          'read': false,
        });
      } catch (_) {}

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Demande d’ami envoyée.")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur: $e")),
      );
    }
  }

  static Future<void> _acceptFriendRequest(
    BuildContext context, {
    required String currentUid,
    required String otherUid,
  }) async {
    if (!await _checkUserNotBannedForAction(context)) {
      return;
    }
    try {
      final ids = [currentUid, otherUid]..sort();
      final friendshipId = "${ids[0]}_${ids[1]}";
      final ref = FirebaseFirestore.instance
          .collection('friendships')
          .doc(friendshipId);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) return;
        final data = snap.data() as Map<String, dynamic>;
        final currentStatus = (data['status'] ?? '').toString();
        if (currentStatus == 'accepted') return;

        tx.update(ref, {
          'status': 'accepted',
          'requestFrom': null,
          'requestTo': null,
          'blockedBy': null,
        });
        final users = FirebaseFirestore.instance.collection('users');
        tx.update(
          users.doc(currentUid),
          {'friendsCount': FieldValue.increment(1)},
        );
        tx.update(
          users.doc(otherUid),
          {'friendsCount': FieldValue.increment(1)},
        );
      });

      try {
        final currentUserSnap = await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUid)
            .get();
        final currentUserData =
            currentUserSnap.data() ?? <String, dynamic>{};
        final fromName = (currentUserData['pseudo'] ??
                currentUserData['email'] ??
                'Quelqu\'un')
            .toString();

        await FirebaseFirestore.instance
            .collection('users')
            .doc(otherUid)
            .collection('notifications')
            .add({
          'type': 'friend_accept',
          'message': "$fromName a accepté ta demande d'ami",
          'postId': '',
          'commentId': null,
          'fromUserId': currentUid,
          'fromUserName': fromName,
          'timestamp': FieldValue.serverTimestamp(),
          'read': false,
        });
      } catch (_) {}

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Demande d’ami acceptée.")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur: $e")),
      );
    }
  }

  static Future<void> removeFriendship(
    BuildContext context, {
    required String currentUid,
    required String otherUid,
  }) async {
    try {
      final ids = [currentUid, otherUid]..sort();
      final friendshipId = "${ids[0]}_${ids[1]}";
      final ref = FirebaseFirestore.instance
          .collection('friendships')
          .doc(friendshipId);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) return;
        final data = snap.data() as Map<String, dynamic>;
        final status = (data['status'] ?? '').toString();

        if (status == 'accepted') {
          final users = FirebaseFirestore.instance.collection('users');
          tx.update(
            users.doc(currentUid),
            {'friendsCount': FieldValue.increment(-1)},
          );
          tx.update(
            users.doc(otherUid),
            {'friendsCount': FieldValue.increment(-1)},
          );
        }
        tx.delete(ref);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Ami supprimé.")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur: $e")),
      );
    }
  }

  static Future<void> blockUser(
    BuildContext context, {
    required String currentUid,
    required String otherUid,
  }) async {
    try {
      final ids = [currentUid, otherUid]..sort();
      final friendshipId = "${ids[0]}_${ids[1]}";
      final ref = FirebaseFirestore.instance
          .collection('friendships')
          .doc(friendshipId);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) {
          tx.set(ref, {
            'userIds': ids,
            'userAId': ids[0],
            'userBId': ids[1],
            'createdAt': FieldValue.serverTimestamp(),
            'status': 'blocked',
            'requestFrom': null,
            'requestTo': null,
            'blockedBy': currentUid,
          });
        } else {
          final data = snap.data() as Map<String, dynamic>;
          final status = (data['status'] ?? '').toString();
          if (status == 'accepted') {
            final users = FirebaseFirestore.instance.collection('users');
            tx.update(
              users.doc(currentUid),
              {'friendsCount': FieldValue.increment(-1)},
            );
            tx.update(
              users.doc(otherUid),
              {'friendsCount': FieldValue.increment(-1)},
            );
          }
          tx.update(ref, {
            'status': 'blocked',
            'requestFrom': null,
            'requestTo': null,
            'blockedBy': currentUid,
          });
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Utilisateur bloqué.")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur: $e")),
      );
    }
  }

  static Future<void> unblockUser(
    BuildContext context, {
    required String currentUid,
    required String otherUid,
  }) async {
    try {
      final ids = [currentUid, otherUid]..sort();
      final friendshipId = "${ids[0]}_${ids[1]}";
      final ref = FirebaseFirestore.instance
          .collection('friendships')
          .doc(friendshipId);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) return;
        tx.delete(ref);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Utilisateur débloqué.")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur: $e")),
      );
    }
  }

  static Future<void> _openChat(
    BuildContext context,
    String otherUid,
    String otherPseudo,
  ) async {
    if (!await _checkUserNotBannedForAction(context)) {
      return;
    }
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    final currentUid = currentUser.uid;

    final ids = [currentUid, otherUid]..sort();
    final conversationId = "${ids[0]}_${ids[1]}";
    final convoRef = FirebaseFirestore.instance
        .collection('conversations')
        .doc(conversationId);

    final convoSnap = await convoRef.get();

    if (!convoSnap.exists) {
      // Vérifie si vous êtes amis
    final friendshipId = conversationId;
    final friendshipSnap = await FirebaseFirestore.instance
        .collection('friendships')
        .doc(friendshipId)
        .get();
    bool areFriends = false;
    if (friendshipSnap.exists) {
      final fData = friendshipSnap.data() as Map<String, dynamic>;
      final status = (fData['status'] ?? '').toString();
      final blockedBy = (fData['blockedBy'] ?? '').toString();
      if (status == 'blocked' && blockedBy.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Impossible de discuter, un blocage est actif."),
          ),
        );
        return;
      }
      areFriends = status == 'accepted';
    }

      await convoRef.set({
        'participants': ids,
        'userAId': ids[0],
        'userBId': ids[1],
        'userAName':
            ids[0] == currentUid ? currentUser.displayName ?? 'Moi' : otherPseudo,
        'userBName':
            ids[1] == currentUid ? currentUser.displayName ?? 'Moi' : otherPseudo,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': currentUid,
        'status': areFriends ? 'accepted' : 'request',
        'requestTo': areFriends ? null : otherUid,
        'lastMessage': '',
        'lastMessageAt': FieldValue.serverTimestamp(),
      });
    } else {
      final data = convoSnap.data() as Map<String, dynamic>;
      final status = (data['status'] ?? '').toString();
      if (status == 'declined') {
        // Relance une demande si la conversation avait été refusée
        await convoRef.update({
          'status': 'request',
          'requestTo': otherUid,
        });
      }
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PrivateChatScreen(
          conversationId: conversationId,
          otherUserId: otherUid,
          otherPseudo: otherPseudo,
        ),
      ),
    );
  }
}

// --- 4. CHAT ---
class ChatRoomScreen extends StatefulWidget {
  final String roomId;
  final String roomName;
  const ChatRoomScreen({
    super.key,
    required this.roomId,
    required this.roomName,
  });
  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final TextEditingController _ctrl = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
      });
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final currentUid = currentUser.uid;

    final roomRef =
        FirebaseFirestore.instance.collection('rooms').doc(widget.roomId);

    return StreamBuilder<DocumentSnapshot>(
      stream: roomRef.snapshots(),
      builder: (context, roomSnap) {
        if (roomSnap.hasError) {
          return const Scaffold(
            body: Center(
              child: Text(
                "Erreur de chargement du salon.",
                style: TextStyle(color: Colors.white70),
              ),
            ),
          );
        }
        if (!roomSnap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (!roomSnap.data!.exists) {
          return const Scaffold(
            body: Center(
              child: Text("Ce salon n'existe plus."),
            ),
          );
        }
        final data = roomSnap.data!.data() as Map<String, dynamic>? ?? {};
        final memberIds =
            List<String>.from((data['memberIds'] as List?) ?? []);
        final isPrivate = (data['isPrivate'] ?? false) as bool;
        if (isPrivate && !memberIds.contains(currentUid)) {
          return Scaffold(
            appBar: AppBar(title: Text(widget.roomName)),
            body: const Center(
              child: Text(
                "Tu n'as pas accès à ce groupe privé.",
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(title: Text(widget.roomName)),
          body: Column(
            children: [
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: roomRef
                      .collection('messages')
                      .orderBy('timestamp', descending: true)
                      .snapshots(),
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return const Center(
                          child: CircularProgressIndicator());
                    }
                    return ListView.builder(
                      reverse: true,
                      itemCount: snap.data!.docs.length,
                      itemBuilder: (context, i) {
                        final msg =
                            snap.data!.docs[i].data() as Map<String, dynamic>;
                        final text = (msg['text'] ?? '').toString();
                        return ListTile(title: Text(text));
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        decoration: NeonTheme.inputStyle("Message..."),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: () async {
                        if (_ctrl.text.isEmpty) return;
                        roomRef.collection('messages').add({
                          'text': _ctrl.text,
                          'senderId': currentUid,
                          'timestamp': FieldValue.serverTimestamp(),
                        });
                        _ctrl.clear();
                        await _awardXp(currentUid, 1);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// --- 4b. SAFE PLACE (forum anonyme, réponses signées) ---
const String _safePlaceThreadsCollection = 'safe_place_threads';
const String _safePlacePinnedId = 'why_safe_place';

class SafePlaceScreen extends StatelessWidget {
  const SafePlaceScreen({super.key});

  Future<void> _ensurePinnedThread() async {
    final ref = FirebaseFirestore.instance
        .collection(_safePlaceThreadsCollection)
        .doc(_safePlacePinnedId);
    final snap = await ref.get();
    if (snap.exists) return;

    const body =
        "Ici, tu peux poser tes questions, parler de ce que tu ressens, partager tes doutes ou tes peurs, sans jugement.\n\n"
        "Ce n’est pas un espace de performance, ni de comparaison. C’est un endroit où le jeu vidéo devient un prétexte pour créer du lien, "
        "se sentir moins seul et trouver du soutien.\n\n"
        "Que tu aies passé une mauvaise journée, que tu te poses des questions sur toi-même, ou que tu aies simplement besoin d’un endroit "
        "pour vider ton sac : cet espace est pour toi.\n\n"
        "Les réponses sont signées, mais le respect est obligatoire. On ne se moque pas, on ne minimise pas les émotions des autres.\n\n"
        "Tu n’es pas obligé d’aller bien pour avoir le droit de parler. Ici, tu as le droit d’être toi.\n\n"
        "Le jeu vidéo n’isole pas,\n"
        "Il unit,\n"
        "Il sauve.";

    await ref.set({
      'title': 'Pourquoi cet espace ?',
      'body': body,
      'createdAt': FieldValue.serverTimestamp(),
      'replyCount': 0,
      'pinned': true,
    });
  }

  @override
  Widget build(BuildContext context) {
    _ensurePinnedThread();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: NeonTheme.bgDark,
        title: const Text("Safe Place"),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection(_safePlaceThreadsCollection)
              .where(FieldPath.documentId, isNotEqualTo: _safePlacePinnedId)
              .orderBy('createdAt', descending: true)
              .snapshots(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? [];

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
              itemCount: docs.length + 1, // bloc intro + épinglé
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Espace de discussion anonyme. Crée un fil avec un titre et un message ; les réponses sont signées.",
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SafePlaceThreadScreen(
                                threadId: _safePlacePinnedId,
                                threadTitle: "Pourquoi cet espace ?",
                              ),
                            ),
                          );
                        },
                        child: _NeonCard(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                Icon(Icons.push_pin,
                                    size: 20, color: NeonTheme.neonBlue),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    "Pourquoi cet espace ?",
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 16,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                const Icon(Icons.chevron_right,
                                    color: Colors.white70),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (docs.isEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          "Aucun autre fil pour le moment.\nCrée le premier !",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ],
                  );
                }

                final doc = docs[index - 1];
                final data = doc.data() as Map<String, dynamic>;
                final title = (data['title'] ?? 'Sans titre').toString();
                final body = (data['body'] ?? '').toString();
                final createdAt = data['createdAt'] as Timestamp?;
                final replyCount = (data['replyCount'] ?? 0) as int;
                final preview = body.length > 120
                    ? '${body.substring(0, 120)}...'
                    : body;
                final dateStr = createdAt != null
                    ? DateFormat('dd/MM à HH:mm').format(createdAt.toDate())
                    : '';

                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SafePlaceThreadScreen(
                          threadId: doc.id,
                          threadTitle: title,
                        ),
                      ),
                    );
                  },
                  child: _NeonCard(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.chat_bubble_outline,
                                  size: 20, color: NeonTheme.neonBlue),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (preview.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              preview,
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.white
                                    .withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.forum,
                                      size: 16, color: Colors.white70),
                                  const SizedBox(width: 4),
                                  Text(
                                    "$replyCount réponse${replyCount > 1 ? 's' : ''}",
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                dateStr,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateThread(context),
        backgroundColor: NeonTheme.neonBlue,
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showCreateThread(BuildContext context) {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: NeonTheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                "Nouveau fil (anonyme)",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: titleCtrl,
                decoration: NeonTheme.inputStyle("Titre du fil"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bodyCtrl,
                decoration: NeonTheme.inputStyle("Message"),
                maxLines: 4,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  if (titleCtrl.text.trim().isEmpty) return;
                  if (!await _checkUserNotBannedForAction(ctx)) {
                    return;
                  }
                  await FirebaseFirestore.instance
                      .collection(_safePlaceThreadsCollection)
                      .add({
                    'title': titleCtrl.text.trim(),
                    'body': bodyCtrl.text.trim(),
                    'createdAt': FieldValue.serverTimestamp(),
                    'replyCount': 0,
                  });
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                },
                child: const Text("Publier (anonyme)"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SafePlaceThreadScreen extends StatefulWidget {
  final String threadId;
  final String threadTitle;

  const SafePlaceThreadScreen({
    super.key,
    required this.threadId,
    required this.threadTitle,
  });

  @override
  State<SafePlaceThreadScreen> createState() => _SafePlaceThreadScreenState();
}

class _SafePlaceThreadScreenState extends State<SafePlaceThreadScreen> {
  final TextEditingController _replyCtrl = TextEditingController();

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) {
      return const Scaffold(
        body: Center(child: Text("Connecte-toi pour participer.")),
      );
    }

    final threadRef = FirebaseFirestore.instance
        .collection(_safePlaceThreadsCollection)
        .doc(widget.threadId);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: NeonTheme.bgDark,
        title: Text(widget.threadTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<DocumentSnapshot>(
                stream: threadRef.snapshots(),
                builder: (context, threadSnap) {
                  if (!threadSnap.hasData || !threadSnap.data!.exists) {
                    return const Center(
                        child: Text("Ce fil n'existe plus."));
                  }
                  final data =
                      threadSnap.data!.data() as Map<String, dynamic>? ?? {};
                  final body = (data['body'] ?? '').toString();
                  final createdAt = data['createdAt'] as Timestamp?;
                  final dateStr = createdAt != null
                      ? DateFormat('dd/MM/yyyy à HH:mm')
                          .format(createdAt.toDate())
                      : '';

                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _NeonCard(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.person_off,
                                        size: 18, color: Colors.white54),
                                    const SizedBox(width: 6),
                                    Text(
                                      "Anonyme",
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.white54,
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      dateStr,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.white38,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  body,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: Colors.white,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (widget.threadId != _safePlacePinnedId) ...[
                          const Text(
                            "Réponses",
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: Colors.white70,
                            ),
                          ),
                          const SizedBox(height: 8),
                          StreamBuilder<QuerySnapshot>(
                            stream: threadRef
                                .collection('replies')
                                .orderBy('timestamp', descending: false)
                                .snapshots(),
                            builder: (context, replySnap) {
                              if (!replySnap.hasData) {
                                return const Center(
                                    child: CircularProgressIndicator());
                              }
                              final replies = replySnap.data!.docs;
                              if (replies.isEmpty) {
                                return Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Text(
                                    "Aucune réponse. Sois le premier !",
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: 14,
                                    ),
                                  ),
                                );
                              }
                              return ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: replies.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, i) {
                                  final r = replies[i].data()
                                      as Map<String, dynamic>;
                                  final text =
                                      (r['text'] ?? '').toString();
                                  final authorName =
                                      (r['authorName'] ?? 'Joueur').toString();
                                  final ts = r['timestamp'] as Timestamp?;
                                  final replyDateStr = ts != null
                                      ? DateFormat('dd/MM HH:mm')
                                          .format(ts.toDate())
                                      : '';

                                  return _NeonCard(
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(Icons.person,
                                                  size: 16,
                                                  color: NeonTheme.neonBlue),
                                              const SizedBox(width: 6),
                                              Text(
                                                authorName,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  color: NeonTheme.neonBlue,
                                                ),
                                              ),
                                              const Spacer(),
                                              Text(
                                                replyDateStr,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.white38,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            text,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
            if (widget.threadId != _safePlacePinnedId)
              SafeArea(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  color: NeonTheme.surface2.withValues(alpha: 0.95),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _replyCtrl,
                          decoration: const InputDecoration(
                            hintText: "Répondre (signé avec ton pseudo)...",
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.send),
                        color: NeonTheme.neonBlue,
                        onPressed: () => _sendReply(
                          context,
                          threadRef: threadRef,
                          currentUid: currentUid,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendReply(
    BuildContext context, {
    required DocumentReference threadRef,
    required String currentUid,
  }) async {
    if (!await _checkUserNotBannedForAction(context)) {
      return;
    }
    if (_replyCtrl.text.trim().isEmpty) return;
    final text = _replyCtrl.text.trim();
    _replyCtrl.clear();

    final userSnap = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUid)
        .get();
    final userData = userSnap.data() ?? {};
    final authorName =
        (userData['pseudo'] ?? userData['email'] ?? 'Joueur').toString();

    await threadRef.collection('replies').add({
      'text': text,
      'authorId': currentUid,
      'authorName': authorName,
      'timestamp': FieldValue.serverTimestamp(),
    });
    await threadRef.update({
      'replyCount': FieldValue.increment(1),
    });
  }
}

// --- 5. CRÉATION SALON ---
class CreateRoomSheet extends StatefulWidget {
  const CreateRoomSheet({super.key});
  @override
  State<CreateRoomSheet> createState() => _CreateRoomSheetState();
}

class _CreateRoomSheetState extends State<CreateRoomSheet> {
  final TextEditingController _name = TextEditingController();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20,
        right: 20,
        top: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: NeonTheme.inputStyle("Nom du salon"),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () async {
              if (_name.text.isEmpty) return;
              await FirebaseFirestore.instance.collection('rooms').add({
                'name': _name.text,
                'timestamp': FieldValue.serverTimestamp(),
              });
              if (!mounted) return;
              Navigator.pop(context);
            },
            child: const Text("CRÉER"),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

// --- 5b. GROUPES PRIVÉS ENTRE AMIS ---

class PrivateGroupsScreen extends StatelessWidget {
  const PrivateGroupsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Gardé pour compatibilité éventuelle, mais l'affichage
    // principal des groupes privés se fait désormais dans SocialScreen.
    return const Scaffold(
      body: Center(
        child: Text(
          "Les groupes privés sont disponibles dans l’onglet Social.",
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _CreatePrivateGroupSheet extends StatefulWidget {
  const _CreatePrivateGroupSheet({super.key});

  @override
  State<_CreatePrivateGroupSheet> createState() =>
      _CreatePrivateGroupSheetState();
}

class _CreatePrivateGroupSheetState extends State<_CreatePrivateGroupSheet> {
  final TextEditingController _nameCtrl = TextEditingController();
  final Set<String> _selectedFriendIds = <String>{};
  bool _loadingFriends = true;
  List<Map<String, String>> _friends = <Map<String, String>>[];

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  Future<void> _loadFriends() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      setState(() {
        _loadingFriends = false;
      });
      return;
    }
    final currentUid = currentUser.uid;
    try {
      final friendshipsSnap = await FirebaseFirestore.instance
          .collection('friendships')
          .where('userIds', arrayContains: currentUid)
          .get();
      final friendIds = <String>{};
      for (final doc in friendshipsSnap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final ids = List<String>.from((data['userIds'] as List?) ?? []);
        final status = (data['status'] ?? '').toString();
        if (status != 'accepted') continue;
        for (final id in ids) {
          if (id != currentUid) friendIds.add(id);
        }
      }
      final friends = <Map<String, String>>[];
      for (final fid in friendIds) {
        final snap =
            await FirebaseFirestore.instance.collection('users').doc(fid).get();
        if (!snap.exists) continue;
        final data = snap.data() as Map<String, dynamic>? ?? {};
        final pseudo = (data['pseudo'] ?? data['email'] ?? 'Joueur').toString();
        friends.add({'id': fid, 'pseudo': pseudo});
      }
      setState(() {
        _friends = friends;
        _loadingFriends = false;
      });
    } catch (_) {
      setState(() {
        _loadingFriends = false;
      });
    }
  }

  Future<void> _createGroup() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    final currentUid = currentUser.uid;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    final memberIds = <String>{currentUid, ..._selectedFriendIds}.toList();
    if (memberIds.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Ajoute au moins un ami pour créer un groupe privé."),
        ),
      );
      return;
    }
    try {
      await FirebaseFirestore.instance.collection('rooms').add({
        'name': name,
        'ownerId': currentUid,
        'memberIds': memberIds,
        'isPrivate': true,
        'timestamp': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur lors de la création du groupe: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20,
        right: 20,
        top: 20,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: NeonTheme.surface.withValues(alpha: 0.97),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(20),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  "Nouveau groupe privé",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _nameCtrl,
                  decoration: NeonTheme.inputStyle("Nom du groupe"),
                ),
                const SizedBox(height: 16),
                const Text(
                  "Choisis les amis à inviter :",
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 8),
                if (_loadingFriends)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_friends.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      "Tu n'as pas encore d'amis.\nAjoute des mates avant de créer un groupe privé.",
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  Column(
                    children: _friends.map((f) {
                      final id = f['id']!;
                      final pseudo = f['pseudo']!;
                      final selected = _selectedFriendIds.contains(id);
                      return CheckboxListTile(
                        value: selected,
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selectedFriendIds.add(id);
                            } else {
                              _selectedFriendIds.remove(id);
                            }
                          });
                        },
                        title: Text(pseudo),
                      );
                    }).toList(),
                  ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _createGroup,
                  child: const Text("Créer le groupe"),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- 5c. SOCIAL (AMIS + MESSAGES + GROUPES PRIVÉS) ---

class SocialScreen extends StatefulWidget {
  const SocialScreen({super.key});

  @override
  State<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends State<SocialScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
      });
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        const SizedBox(height: 40),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              Text(
                "SOCIAL",
                style: NeonTheme.sectionTitle(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container
        (
          margin: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: NeonTheme.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: NeonTheme.accent.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          child: TabBar(
            controller: _tabController,
            indicator: BoxDecoration(
              color: NeonTheme.neonBlue.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorPadding: const EdgeInsets.all(4),
            dividerColor: Colors.transparent,
            labelColor: NeonTheme.neonBlue,
            unselectedLabelColor: Colors.white70,
            labelStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
            unselectedLabelStyle: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            tabs: const [
              Tab(text: "Messages"),
              Tab(text: "Amis"),
              Tab(text: "Groupes"),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _MessagesTab(currentUid: currentUid),
              _FriendsTab(currentUid: currentUid),
              _GroupsTab(currentUid: currentUid),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessagesTab extends StatelessWidget {
  final String currentUid;
  const _MessagesTab({required this.currentUid});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Conversations",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('conversations')
                  .where('participants', arrayContains: currentUid)
                  .where('status', isEqualTo: 'accepted')
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(
                    child: Text("Erreur de chargement des conversations."),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      "Aucune conversation pour le moment.",
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final userAId = (data['userAId'] ?? '').toString();
                    final userBId = (data['userBId'] ?? '').toString();
                    final userAName =
                        (data['userAName'] ?? 'Joueur').toString();
                    final userBName =
                        (data['userBName'] ?? 'Joueur').toString();
                    final lastMessage =
                        (data['lastMessage'] ?? '').toString();

                    final isA = currentUid == userAId;
                    final otherId = isA ? userBId : userAId;
                    final otherName = isA ? userBName : userAName;

                    return _ConversationTile(
                      otherId: otherId,
                      otherName: otherName,
                      lastMessage: lastMessage,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PrivateChatScreen(
                              conversationId: doc.id,
                              otherUserId: otherId,
                              otherPseudo: otherName,
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            "Demandes de messages",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 160,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('conversations')
                  .where('requestTo', isEqualTo: currentUid)
                  .where('status', isEqualTo: 'request')
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(
                    child: Text("Erreur de chargement des demandes."),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      "Aucune demande pour l’instant.",
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final userAId = (data['userAId'] ?? '').toString();
                    final userBId = (data['userBId'] ?? '').toString();
                    final userAName =
                        (data['userAName'] ?? 'Joueur').toString();
                    final userBName =
                        (data['userBName'] ?? 'Joueur').toString();

                    final isA = currentUid == userAId;
                    final otherId = isA ? userBId : userAId;
                    final otherName = isA ? userBName : userAName;

                    return GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PrivateChatScreen(
                              conversationId: doc.id,
                              otherUserId: otherId,
                              otherPseudo: otherName,
                            ),
                          ),
                        );
                      },
                      child: Container(
                        width: 220,
                        padding: const EdgeInsets.all(12),
                        decoration: NeonTheme.neonCardDecoration(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        PublicProfileScreen(userId: otherId),
                                  ),
                                );
                              },
                              child: Text(
                                otherName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              "Souhaite te contacter.",
                              style: TextStyle(color: Colors.white70),
                            ),
                            const Spacer(),
                            const Text(
                              "Appuie pour voir la demande",
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _FriendsTab extends StatelessWidget {
  final String currentUid;
  const _FriendsTab({required this.currentUid});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('friendships')
            .where('userIds', arrayContains: currentUid)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(
              child: Text("Erreur de chargement des amis."),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text(
                "Aucun ami pour l’instant.\nAjoute des joueurs depuis l’onglet Mates.",
                textAlign: TextAlign.center,
              ),
            );
          }

          final accepted = <QueryDocumentSnapshot>[];
          final requestsIncoming = <QueryDocumentSnapshot>[];
          final requestsOutgoing = <QueryDocumentSnapshot>[];
          final blocked = <QueryDocumentSnapshot>[];

          for (final d in docs) {
            final data = d.data() as Map<String, dynamic>;
            final status = (data['status'] ?? '').toString();
            final blockedBy = (data['blockedBy'] ?? '').toString();
            final requestFrom = (data['requestFrom'] ?? '').toString();
            final requestTo = (data['requestTo'] ?? '').toString();

            if (status == 'blocked' && blockedBy.isNotEmpty) {
              blocked.add(d);
            } else if (status == 'accepted') {
              accepted.add(d);
            } else if (status == 'request') {
              if (requestTo == currentUid) {
                requestsIncoming.add(d);
              } else if (requestFrom == currentUid) {
                requestsOutgoing.add(d);
              }
            }
          }

          return ListView(
            children: [
              if (requestsIncoming.isNotEmpty) ...[
                const Text(
                  "Demandes d’amis",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 8),
                ...requestsIncoming.map((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final userIds =
                      List<String>.from((data['userIds'] as List?) ?? []);
                  final otherId = userIds.firstWhere(
                    (id) => id != currentUid,
                    orElse: () => '',
                  );
                  if (otherId.isEmpty) return const SizedBox.shrink();
                  return _FriendRequestTile(
                    friendshipId: d.id,
                    currentUid: currentUid,
                    otherId: otherId,
                  );
                }),
                const SizedBox(height: 16),
              ],
              if (accepted.isNotEmpty) ...[
                const Text(
                  "Amis",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 8),
                ...accepted.map((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final userIds =
                      List<String>.from((data['userIds'] as List?) ?? []);
                  final otherId = userIds.firstWhere(
                    (id) => id != currentUid,
                    orElse: () => '',
                  );
                  if (otherId.isEmpty) return const SizedBox.shrink();
                  return _FriendItem(
                    friendshipId: d.id,
                    currentUid: currentUid,
                    otherId: otherId,
                  );
                }),
                const SizedBox(height: 16),
              ],
              if (requestsOutgoing.isNotEmpty) ...[
                const Text(
                  "Demandes envoyées",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 8),
                ...requestsOutgoing.map((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final userIds =
                      List<String>.from((data['userIds'] as List?) ?? []);
                  final otherId = userIds.firstWhere(
                    (id) => id != currentUid,
                    orElse: () => '',
                  );
                  if (otherId.isEmpty) return const SizedBox.shrink();
                  return _OutgoingFriendRequestTile(
                    friendshipId: d.id,
                    currentUid: currentUid,
                    otherId: otherId,
                  );
                }),
                const SizedBox(height: 16),
              ],
              if (blocked.isNotEmpty) ...[
                const Text(
                  "Bloqués",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 8),
                ...blocked.map((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final userIds =
                      List<String>.from((data['userIds'] as List?) ?? []);
                  final otherId = userIds.firstWhere(
                    (id) => id != currentUid,
                    orElse: () => '',
                  );
                  if (otherId.isEmpty) return const SizedBox.shrink();
                  return _BlockedFriendTile(
                    friendshipId: d.id,
                    currentUid: currentUid,
                    otherId: otherId,
                  );
                }),
                const SizedBox(height: 16),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _GroupsTab extends StatelessWidget {
  final String currentUid;
  const _GroupsTab({required this.currentUid});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('rooms')
                  .where('memberIds', arrayContains: currentUid)
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(
                    child: Text(
                      "Impossible de charger les groupes.",
                      style: TextStyle(color: Colors.white70),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      "Aucun groupe privé pour l’instant.\nCrée-en un avec tes amis !",
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data =
                        docs[index].data() as Map<String, dynamic>? ?? {};
                    final name = (data['name'] ?? 'Groupe').toString();
                    final memberIds =
                        List<String>.from((data['memberIds'] as List?) ?? []);
                    final isOwner =
                        (data['ownerId'] ?? '').toString() == currentUid;
                    final subtitle = isOwner
                        ? "Créateur du groupe • ${memberIds.length} membres"
                        : "${memberIds.length} membres";
                    return ListTile(
                      title: Text(name),
                      subtitle: Text(
                        subtitle,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatRoomScreen(
                              roomId: docs[index].id,
                              roomName: name,
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => const _CreatePrivateGroupSheet(),
                );
              },
              icon: const Icon(Icons.add),
              label: const Text("Créer un groupe privé"),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// --- 6. COMMU (POSTS, LIKES, COMMENTAIRES, NOTIFS) ---
class CommunityFeedScreen extends StatefulWidget {
  const CommunityFeedScreen({super.key});
  @override
  State<CommunityFeedScreen> createState() => _CommunityFeedScreenState();
}

class _CommunityFeedScreenState extends State<CommunityFeedScreen> {
  final ScrollController _feedScroll = ScrollController();
  bool _showScrollTopFab = false;
  /// Ne pas recréer ce future à chaque build : sinon [FutureBuilder] redémarre
  /// et la liste perd le scroll (ex. quand le bouton « remonter » appelle setState).
  late final Future<Map<String, dynamic>?> _userFuture;

  @override
  void initState() {
    super.initState();
    _userFuture = _loadCurrentUser();
    _feedScroll.addListener(_onFeedScroll);
  }

  void _onFeedScroll() {
    final show = _feedScroll.hasClients && _feedScroll.offset > 280;
    if (show != _showScrollTopFab) {
      setState(() => _showScrollTopFab = show);
    }
  }

  @override
  void dispose() {
    _feedScroll.removeListener(_onFeedScroll);
    _feedScroll.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _loadCurrentUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    return snap.data();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _userFuture,
      builder: (context, userSnap) {
        if (userSnap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final userData = userSnap.data ?? {};
        final currentUid = FirebaseAuth.instance.currentUser?.uid;
        if (currentUid == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
          });
          return const Center(child: CircularProgressIndicator());
        }
        final currentName =
            (userData['pseudo'] ?? userData['email'] ?? 'Joueur').toString();
        final currentAvatar = userData['avatarUrl'] as String?;
        final currentRole = (userData['role'] ?? 'user').toString();

        final banPermanent = (userData['banPermanent'] ?? false) as bool;
        final banUntilTs = userData['banUntil'] as Timestamp?;
        final now = DateTime.now();
        final bool isTempBanned =
            banUntilTs != null && banUntilTs.toDate().isAfter(now);
        final bool isBanned = banPermanent || isTempBanned;

        return Stack(
          children: [
            Column(
              children: [
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Text(
                    "SOCIAL",
                    style: NeonTheme.sectionTitle(),
                  ),
                  const Spacer(),
                  StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('users')
                        .doc(currentUid)
                        .collection('notifications')
                        .where('read', isEqualTo: false)
                        .snapshots(),
                    builder: (context, snap) {
                      final count = snap.hasData ? snap.data!.docs.length : 0;
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.notifications,
                              color: Colors.white70,
                            ),
                            onPressed: () {
                              showModalBottomSheet(
                                context: context,
                                backgroundColor: Colors.transparent,
                                isScrollControlled: true,
                                builder: (_) =>
                                    NotificationsSheet(userId: currentUid),
                              );
                            },
                          ),
                          if (count > 0)
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: NeonTheme.accent,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  count > 9 ? '9+' : '$count',
                                  style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: GestureDetector(
                onTap: isBanned
                    ? () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              "Tu es actuellement banni de la publication.",
                            ),
                          ),
                        );
                      }
                    : () => _openCreatePostSheet(
                          context,
                          currentUid: currentUid,
                          currentName: currentName,
                          currentAvatar: currentAvatar,
                        ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: NeonTheme.surface.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: NeonTheme.neonBlue.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundImage: currentAvatar != null
                            ? NetworkImage(currentAvatar)
                            : null,
                        child: currentAvatar == null
                            ? const Icon(Icons.person, size: 18)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          isBanned
                              ? "Tu ne peux pas publier pour le moment"
                              : "Exprime-toi...",
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                      const Icon(
                        Icons.edit,
                        size: 18,
                        color: NeonTheme.neonBlue,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('friendships')
                    .where('userIds', arrayContains: currentUid)
                    .snapshots(),
                builder: (context, friendSnap) {
                  final Set<String> allowedAuthorIds = {currentUid};
                  if (friendSnap.hasData) {
                    for (final doc in friendSnap.data!.docs) {
                      final userIds = List<String>.from(
                        (doc.data() as Map<String, dynamic>)['userIds'] ?? [],
                      );
                      for (final id in userIds) {
                        if (id != currentUid) allowedAuthorIds.add(id);
                      }
                    }
                  }
                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('posts')
                        .orderBy('timestamp', descending: true)
                        .snapshots(),
                    builder: (context, snap) {
                      if (!snap.hasData) {
                        return const Center(
                            child: CircularProgressIndicator());
                      }
                      final allDocs = snap.data!.docs;
                      final filtered = allDocs.where((doc) {
                        final data =
                            doc.data() as Map<String, dynamic>? ?? {};
                        final authorId =
                            (data['authorId'] ?? '').toString();
                        final visibility =
                            (data['visibility'] ?? 'friends').toString();

                        // L'auteur voit toujours ses propres posts
                        if (authorId == currentUid) return true;

                        // Posts publics visibles par tout le monde
                        if (visibility == 'public') return true;

                        // Posts pour amis uniquement : nécessite une relation d'amitié
                        if (visibility == 'friends') {
                          return allowedAuthorIds.contains(authorId);
                        }

                        // Posts privés : seulement l'auteur (déjà géré plus haut)
                        if (visibility == 'private') return false;

                        // Valeur inattendue : on reste prudent et on filtre
                        return false;
                      }).toList();
                      if (filtered.isEmpty) {
                        return const Center(
                          child: Text(
                        "Aucun post de tes amis pour l’instant.\nAjoute des amis ou publie toi-même !",
                        textAlign: TextAlign.center,
                      ),
                    );
                      }
                      return ListView.builder(
                        controller: _feedScroll,
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final doc = filtered[i];
                      final data = doc.data() as Map<String, dynamic>;
                      return _PostCard(
                        postId: doc.id,
                        data: data,
                        currentUid: currentUid,
                        authorId: (data['authorId'] ?? '').toString(),
                        currentUserRole: currentRole,
                        onNotify: _sendNotification,
                      );
                    },
                  );
                },
              );
            },
              ),
            ),
          ],
            ),
            if (_showScrollTopFab)
              Positioned(
                right: 12,
                bottom: 12,
                child: Material(
                  color: NeonTheme.surface.withValues(alpha: 0.95),
                  shape: const CircleBorder(),
                  elevation: 6,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      if (_feedScroll.hasClients) {
                        _feedScroll.animateTo(
                          0,
                          duration: const Duration(milliseconds: 450),
                          curve: Curves.easeOutCubic,
                        );
                      }
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(
                        Icons.keyboard_arrow_up,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _openCreatePostSheet(
    BuildContext context, {
    required String currentUid,
    required String currentName,
    required String? currentAvatar,
  }) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CreatePostSheetContent(
        currentUid: currentUid,
        currentName: currentName,
        currentAvatar: currentAvatar,
        onNotifyMentions: (text, postId) => _notifyMentionsInText(
          text: text,
          fromUserId: currentUid,
          fromUserName: currentName,
          postId: postId,
          commentId: null,
        ),
      ),
    );
  }

  Future<void> _sendNotification({
    required String targetUid,
    required String type,
    required String message,
    required String postId,
    String? commentId,
  }) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null || currentUid == targetUid) return;

    final currentUserSnap = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUid)
        .get();
    final currentUserData =
        currentUserSnap.data() ?? <String, dynamic>{};
    final fromName = (currentUserData['pseudo'] ??
            currentUserData['email'] ??
            'Quelqu\'un')
        .toString();
    final fullMessage = "$fromName $message";

    await FirebaseFirestore.instance
        .collection('users')
        .doc(targetUid)
        .collection('notifications')
        .add({
          'type': type,
          'message': fullMessage,
          'postId': postId,
          'commentId': commentId,
          'fromUserId': currentUid,
          'fromUserName': fromName,
          'timestamp': FieldValue.serverTimestamp(),
          'read': false,
        });
  }

  Future<void> _notifyMentionsInText({
    required String text,
    required String fromUserId,
    required String fromUserName,
    required String postId,
    String? commentId,
  }) async {
    final exp = RegExp(r'@([A-Za-z0-9_]+)');
    final matches = exp.allMatches(text);
    final pseudos = <String>{};
    for (final m in matches) {
      pseudos.add(m.group(1)!);
    }
    if (pseudos.isEmpty) return;

    for (final pseudo in pseudos) {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where('pseudo', isEqualTo: pseudo)
          .limit(5)
          .get();
      for (final doc in snap.docs) {
        final uid = doc.id;
        if (uid == fromUserId) continue;
        await _sendNotification(
          targetUid: uid,
          type: commentId == null ? 'mention_post' : 'mention_comment',
          message: "$fromUserName t'a mentionné",
          postId: postId,
          commentId: commentId,
        );
      }
    }
  }
}

class _CreatePostSheetContent extends StatefulWidget {
  final String currentUid;
  final String currentName;
  final String? currentAvatar;
  final Future<void> Function(String text, String postId)? onNotifyMentions;

  const _CreatePostSheetContent({
    required this.currentUid,
    required this.currentName,
    this.currentAvatar,
    this.onNotifyMentions,
  });

  @override
  State<_CreatePostSheetContent> createState() =>
      _CreatePostSheetContentState();
}

class _CreatePostSheetContentState extends State<_CreatePostSheetContent> {
  final _controller = TextEditingController();
  File? _selectedMedia;
  String? _mediaType;
  String _visibility = 'friends'; // 'friends', 'public', 'private'
  bool _publishing = false;

  Future<void> _pickImage() async {
    final picked =
        await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _selectedMedia = File(picked.path);
      _mediaType = 'image';
    });
  }

  Future<void> _pickVideo() async {
    final picked =
        await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _selectedMedia = File(picked.path);
      _mediaType = 'video';
    });
  }

  Future<void> _openMentionFriendsPicker(BuildContext context) async {
    final currentUid = widget.currentUid;
    try {
      final friendshipsSnap = await FirebaseFirestore.instance
          .collection('friendships')
          .where('userIds', arrayContains: currentUid)
          .get();
      final friendIds = <String>{};
      for (final doc in friendshipsSnap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final ids = List<String>.from((data['userIds'] as List?) ?? []);
        final status = (data['status'] ?? '').toString();
        if (status != 'accepted') continue;
        for (final id in ids) {
          if (id != currentUid) friendIds.add(id);
        }
      }
      if (friendIds.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Tu n'as pas encore d'amis à mentionner.")),
        );
        return;
      }

      final friends = <Map<String, String>>[];
      for (final fid in friendIds) {
        final snap =
            await FirebaseFirestore.instance.collection('users').doc(fid).get();
        if (!snap.exists) continue;
        final data = snap.data() as Map<String, dynamic>? ?? {};
        final pseudo = (data['pseudo'] ?? '').toString();
        if (pseudo.isEmpty) continue;
        friends.add({'id': fid, 'pseudo': pseudo});
      }
      if (friends.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Aucun pseudo d'ami disponible pour @.")),
        );
        return;
      }

      await showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (ctx) {
          return Container(
            decoration: BoxDecoration(
              color: NeonTheme.surface.withValues(alpha: 0.97),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: friends.length,
              itemBuilder: (context, index) {
                final f = friends[index];
                final pseudo = f['pseudo']!;
                return ListTile(
                  leading: const Icon(Icons.person, color: Colors.white70),
                  title: Text(pseudo),
                  onTap: () {
                    final text = _controller.text;
                    final needsSpace =
                        text.isNotEmpty && !text.endsWith(' ');
                    final toInsert =
                        "${needsSpace ? ' ' : ''}@$pseudo ";
                    _controller.text = text + toInsert;
                    _controller.selection = TextSelection.fromPosition(
                      TextPosition(offset: _controller.text.length),
                    );
                    Navigator.pop(ctx);
                  },
                );
              },
            ),
          );
        },
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Impossible de charger la liste d'amis pour @."),
        ),
      );
    }
  }

  Future<void> _publish() async {
    if (_publishing) return;
    final text = _controller.text.trim();
    if (text.isEmpty && _selectedMedia == null) return;

    setState(() => _publishing = true);
    try {
      final postsRef = FirebaseFirestore.instance.collection('posts');
      final newDoc = postsRef.doc();

      String? mediaUrl;
      String? mediaTypeToSave = _mediaType;

      if (_selectedMedia != null && mediaTypeToSave != null) {
        final fileName =
            "${newDoc.id}.${mediaTypeToSave == 'image' ? 'jpg' : 'mp4'}";
        final ref = FirebaseStorage.instance
            .ref()
            .child('posts_media/$fileName');
        await ref.putFile(_selectedMedia!);
        mediaUrl = await ref.getDownloadURL();
      }

      await newDoc.set({
        'text': text,
        'authorId': widget.currentUid,
        'authorName': widget.currentName,
        'authorAvatar': widget.currentAvatar,
        'timestamp': FieldValue.serverTimestamp(),
        'likesCount': 0,
        'commentsCount': 0,
        'likedBy': <String>[],
        'mediaUrl': mediaUrl,
        'mediaType': mediaTypeToSave,
        'visibility': _visibility,
      });

      // XP pour création de post
      await _awardXp(widget.currentUid, 20);

      // Notifications pour les abonnés (follow) quand un nouveau post est publié
      try {
        final followersSnap = await FirebaseFirestore.instance
            .collection('follows')
            .where('targetId', isEqualTo: widget.currentUid)
            .get();
        for (final doc in followersSnap.docs) {
          final data = doc.data() as Map<String, dynamic>;
          final followerId = (data['followerId'] ?? '').toString();
          if (followerId.isEmpty || followerId == widget.currentUid) continue;
          await FirebaseFirestore.instance
              .collection('users')
              .doc(followerId)
              .collection('notifications')
              .add({
            'type': 'follow_post',
            'message': "${widget.currentName} a publié un nouveau post",
            'postId': newDoc.id,
            'commentId': null,
            'fromUserId': widget.currentUid,
            'timestamp': FieldValue.serverTimestamp(),
            'read': false,
          });
        }
      } catch (_) {
        // En cas d'erreur sur les notifs de followers, on ne bloque pas la publication.
      }

      await widget.onNotifyMentions?.call(text, newDoc.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur lors de la publication: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: NeonTheme.surface.withValues(alpha: 0.96),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(24),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text(
                    "Nouveau post",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _controller,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: "Partage une pensée, un tilt, un GG...",
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.alternate_email, color: Colors.white70),
                    tooltip: "Mentionner un ami",
                    onPressed: () => _openMentionFriendsPicker(context),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _pickImage,
                    icon: const Icon(Icons.image, color: Colors.white70),
                    label: const Text("Photo"),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _pickVideo,
                    icon: const Icon(Icons.videocam, color: Colors.white70),
                    label: const Text("Vidéo"),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text(
                    "Visibilité :",
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: _visibility,
                    dropdownColor: NeonTheme.surface2,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(
                        value: 'friends',
                        child: Text("Amis uniquement"),
                      ),
                      DropdownMenuItem(
                        value: 'public',
                        child: Text("Public"),
                      ),
                      DropdownMenuItem(
                        value: 'private',
                        child: Text("Privé (moi seulement)"),
                      ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _visibility = v);
                    },
                  ),
                ],
              ),
              if (_selectedMedia != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.white10,
                    ),
                    padding: const EdgeInsets.all(6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _mediaType == 'image'
                              ? Icons.image
                              : Icons.videocam,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _mediaType == 'image'
                              ? "Photo ajoutée"
                              : "Vidéo ajoutée",
                          style: const TextStyle(fontSize: 12),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            setState(() {
                              _selectedMedia = null;
                              _mediaType = null;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _publishing ? null : _publish,
                  child: _publishing
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 12),
                            Text("Envoi en cours..."),
                          ],
                        )
                      : const Text("Publier"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  final String postId;
  final Map<String, dynamic> data;
  final String currentUid;
  final String authorId;
  final String currentUserRole;
  final Future<void> Function({
    required String targetUid,
    required String type,
    required String message,
    required String postId,
    String? commentId,
  })
  onNotify;

  const _PostCard({
    required this.postId,
    required this.data,
    required this.currentUid,
    required this.authorId,
    required this.currentUserRole,
    required this.onNotify,
  });

  @override
  Widget build(BuildContext context) {
    final authorName = (data['authorName'] ?? 'Joueur').toString();
    final authorAvatar = data['authorAvatar'] as String?;
    final text = (data['text'] ?? '').toString();
    final mediaUrl = data['mediaUrl'] as String?;
    final mediaType = data['mediaType'] as String?;
    final likesCount = (data['likesCount'] ?? 0) as int;
    final commentsCount = (data['commentsCount'] ?? 0) as int;
    final likedBy = List<String>.from(
      (data['likedBy'] as List?) ?? const <String>[],
    );
    final isLiked = likedBy.contains(currentUid);
    final ts = data['timestamp'] as Timestamp?;
    final dateStr = ts != null
        ? DateFormat('dd/MM HH:mm').format(ts.toDate())
        : "";

    final isOwner = currentUid == authorId;
    final isStaff = _isStaffRole(currentUserRole);
    final canDelete = isOwner || isStaff;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NeonTheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () {
                  final currentUid =
                      FirebaseAuth.instance.currentUser?.uid;
                  if (authorId == currentUid) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const UserProfileScreen(),
                      ),
                    );
                  } else if (authorId.isNotEmpty) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            PublicProfileScreen(userId: authorId),
                      ),
                    );
                  }
                },
                child: CircleAvatar(
                  radius: 18,
                  backgroundImage: authorAvatar != null
                      ? NetworkImage(authorAvatar)
                      : null,
                  child: authorAvatar == null
                      ? const Icon(Icons.person, size: 18)
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: () {
                        final currentUid =
                            FirebaseAuth.instance.currentUser?.uid;
                        if (authorId == currentUid) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const UserProfileScreen(),
                            ),
                          );
                        } else {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  PublicProfileScreen(userId: authorId),
                            ),
                          );
                        }
                      },
                      child: Text(
                        authorName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: NeonTheme.neonBlue,
                        ),
                      ),
                    ),
                    if (dateStr.isNotEmpty)
                      Text(
                        dateStr,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white38,
                        ),
                      ),
                  ],
                ),
              ),
              if (isOwner || isStaff)
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert,
                    color: Colors.white70,
                    size: 18,
                  ),
                  onSelected: (value) {
                    if (value == 'edit') {
                      if (isOwner) {
                        _openEditPost(
                          context,
                          initialText: text,
                          initialMediaUrl: mediaUrl,
                          initialMediaType: mediaType,
                        );
                      }
                    } else if (value == 'delete') {
                      _confirmDelete(context, mediaUrl: mediaUrl);
                    } else if (value == 'ban_24h') {
                      _banUser(context, const Duration(hours: 24));
                    } else if (value == 'ban_7d') {
                      _banUser(context, const Duration(days: 7));
                    } else if (value == 'ban_perm') {
                      _banUser(context, null);
                    }
                  },
                  itemBuilder: (context) => [
                    if (isOwner)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Modifier'),
                      ),
                    if (canDelete)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Supprimer'),
                      ),
                    if (isStaff && authorId.isNotEmpty && authorId != currentUid)
                      const PopupMenuItem(
                        value: 'ban_24h',
                        child: Text('Bannir 24h'),
                      ),
                    if (isStaff && authorId.isNotEmpty && authorId != currentUid)
                      const PopupMenuItem(
                        value: 'ban_7d',
                        child: Text('Bannir 7 jours'),
                      ),
                    if (isStaff && authorId.isNotEmpty && authorId != currentUid)
                      const PopupMenuItem(
                        value: 'ban_perm',
                        child: Text('Ban définitif'),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(text),
          if (mediaUrl != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: mediaType == 'image'
                  ? GestureDetector(
                      onTap: () =>
                          openFullscreenImageUrl(context, mediaUrl),
                      child: Image.network(
                        mediaUrl,
                        fit: BoxFit.cover,
                      ),
                    )
                  : Container(
                      height: 180,
                      color: Colors.black26,
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(Icons.videocam, color: Colors.white70),
                            SizedBox(width: 8),
                            Text(
                              "Vidéo jointe",
                              style: TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              InkWell(
                onTap: () => _toggleLike(context, isLiked),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isLiked ? Icons.favorite : Icons.favorite_border,
                        color: isLiked ? Colors.pinkAccent : Colors.white70,
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      Text(likesCount.toString()),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              InkWell(
                onTap: () => _openComments(context),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.mode_comment_outlined,
                        size: 18,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 4),
                      Text(commentsCount.toString()),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _toggleLike(BuildContext context, bool isLiked) async {
    if (!await _checkUserNotBannedForAction(context)) {
      return;
    }
    final ref = FirebaseFirestore.instance.collection('posts').doc(postId);
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>;
      final likedBy = List<String>.from(
        (data['likedBy'] as List?) ?? const <String>[],
      );
      final already = likedBy.contains(currentUid);

      if (isLiked && already) {
        tx.update(ref, {
          'likedBy': FieldValue.arrayRemove([currentUid]),
          'likesCount': FieldValue.increment(-1),
        });
      } else if (!isLiked && !already) {
        tx.update(ref, {
          'likedBy': FieldValue.arrayUnion([currentUid]),
          'likesCount': FieldValue.increment(1),
        });
      }
    });

    // XP pour like (seulement lorsqu'on like, pas quand on enlève)
    if (!isLiked) {
      await _awardXp(currentUid, 2);
    }

    if (!isLiked && authorId.isNotEmpty) {
      await onNotify(
        targetUid: authorId,
        type: 'like',
        message: "a aimé ton post",
        postId: postId,
      );
    }
  }

  Future<void> _openComments(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return CommentsSheet(
          postId: postId,
          postAuthorId: authorId,
          onNotify: onNotify,
        );
      },
    );
  }

  Future<void> _openEditPost(
    BuildContext context, {
    required String initialText,
    required String? initialMediaUrl,
    required String? initialMediaType,
  }) async {
    final controller = TextEditingController(text: initialText);
    String? existingType = initialMediaType;
    File? pickedFile;
    String? pickedType; // 'image' ou 'video'
    bool removeExisting = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> pickImage() async {
              final picked =
                  await ImagePicker().pickImage(source: ImageSource.gallery);
              if (picked == null) return;
              setModalState(() {
                pickedFile = File(picked.path);
                pickedType = 'image';
                removeExisting = false;
              });
            }

            Future<void> pickVideo() async {
              final picked =
                  await ImagePicker().pickVideo(source: ImageSource.gallery);
              if (picked == null) return;
              setModalState(() {
                pickedFile = File(picked.path);
                pickedType = 'video';
                removeExisting = false;
              });
            }

            Future<void> save() async {
              final newText = controller.text.trim();
              final hasOldMedia = initialMediaUrl != null && !removeExisting;
              final hasNewMedia = pickedFile != null;
              if (newText.isEmpty && !hasOldMedia && !hasNewMedia) return;

              String? finalUrl = initialMediaUrl;
              String? finalType = initialMediaType;

              // Si un nouveau média est choisi, on remplace l'ancien
              if (pickedFile != null && pickedType != null) {
                if (initialMediaUrl != null && initialMediaUrl.isNotEmpty) {
                  try {
                    final oldRef =
                        FirebaseStorage.instance.refFromURL(initialMediaUrl);
                    await oldRef.delete();
                  } catch (_) {}
                }

                final ref = FirebaseStorage.instance
                    .ref()
                    .child('posts_media/$postId.${pickedType == 'image' ? 'jpg' : 'mp4'}');
                await ref.putFile(pickedFile!);
                finalUrl = await ref.getDownloadURL();
                finalType = pickedType;
              } else if (removeExisting &&
                  initialMediaUrl != null &&
                  initialMediaUrl.isNotEmpty) {
                try {
                  final oldRef =
                      FirebaseStorage.instance.refFromURL(initialMediaUrl);
                  await oldRef.delete();
                } catch (_) {}
                finalUrl = null;
                finalType = null;
              }

              await FirebaseFirestore.instance
                  .collection('posts')
                  .doc(postId)
                  .update({
                'text': newText,
                'mediaUrl': finalUrl,
                'mediaType': finalType,
              });

              if (Navigator.canPop(ctx)) Navigator.pop(ctx);
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: NeonTheme.surface.withValues(alpha: 0.96),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Text(
                            "Modifier le post",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: controller,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          hintText: "Édite ton message...",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: pickImage,
                            icon: const Icon(Icons.image, color: Colors.white70),
                            label: const Text("Photo"),
                          ),
                          const SizedBox(width: 8),
                          TextButton.icon(
                            onPressed: pickVideo,
                            icon:
                                const Icon(Icons.videocam, color: Colors.white70),
                            label: const Text("Vidéo"),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (initialMediaUrl != null &&
                          initialMediaUrl.isNotEmpty &&
                          !removeExisting &&
                          pickedFile == null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "Média actuel",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: existingType == 'image'
                                    ? Image.network(
                                        initialMediaUrl,
                                        height: 120,
                                        fit: BoxFit.cover,
                                      )
                                    : Container(
                                        height: 80,
                                        width: 140,
                                        color: Colors.black26,
                                        child: const Center(
                                          child: Icon(
                                            Icons.videocam,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ),
                              ),
                              TextButton(
                                onPressed: () {
                                  setModalState(() {
                                    removeExisting = true;
                                    existingType = null;
                                  });
                                },
                                child: const Text(
                                  "Supprimer ce média",
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (pickedFile != null) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.white10,
                            ),
                            padding: const EdgeInsets.all(6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  pickedType == 'image'
                                      ? Icons.image
                                      : Icons.videocam,
                                  size: 18,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  pickedType == 'image'
                                      ? "Nouvelle photo ajoutée"
                                      : "Nouvelle vidéo ajoutée",
                                  style: const TextStyle(fontSize: 12),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close, size: 16),
                                  onPressed: () {
                                    setModalState(() {
                                      pickedFile = null;
                                      pickedType = null;
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: save,
                          child: const Text("Enregistrer"),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context, {
    required String? mediaUrl,
  }) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text("Supprimer le post"),
          content: const Text(
            "Es-tu sûr de vouloir supprimer définitivement ce post ?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                "Supprimer",
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    // Supprimer le média associé s'il existe
    if (mediaUrl != null && mediaUrl.isNotEmpty) {
      try {
        final ref = FirebaseStorage.instance.refFromURL(mediaUrl);
        await ref.delete();
      } catch (_) {}
    }

    final postRef = FirebaseFirestore.instance.collection('posts').doc(postId);

    // Supprimer les commentaires liés
    try {
      final commentsSnap = await postRef.collection('comments').get();
      for (final doc in commentsSnap.docs) {
        await doc.reference.delete();
      }
    } catch (_) {}

    await postRef.delete();
  }

  Future<void> _banUser(BuildContext context, Duration? duration) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String label;
        if (duration == null) {
          label = "ban définitif";
        } else if (duration.inDays >= 7) {
          label = "ban 7 jours";
        } else {
          label = "ban 24 heures";
        }
        return AlertDialog(
          title: const Text("Bannir l'utilisateur"),
          content: Text(
            "Es-tu sûr de vouloir appliquer un $label à cet utilisateur ?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                "Confirmer",
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    final userRef =
        FirebaseFirestore.instance.collection('users').doc(authorId);

    DateTime? until;
    final bool permanent = duration == null;
    if (!permanent) {
      until = DateTime.now().add(duration!);
    }

    if (permanent) {
      await userRef.update({
        'banPermanent': true,
        'banUntil': null,
      });
    } else {
      await userRef.update({
        'banPermanent': false,
        'banUntil': Timestamp.fromDate(until!),
      });
    }

    try {
      final moderatorId = FirebaseAuth.instance.currentUser?.uid;
      await FirebaseFirestore.instance.collection('bans').add({
        'userId': authorId,
        'moderatorId': moderatorId,
        'permanent': permanent,
        'banUntil': permanent ? null : Timestamp.fromDate(until!),
        'createdAt': FieldValue.serverTimestamp(),
        'active': true,
      });
    } catch (_) {}
  }
}

class CommentsSheet extends StatefulWidget {
  final String postId;
  final String postAuthorId;
  final Future<void> Function({
    required String targetUid,
    required String type,
    required String message,
    required String postId,
    String? commentId,
  })
  onNotify;

  const CommentsSheet({
    super.key,
    required this.postId,
    required this.postAuthorId,
    required this.onNotify,
  });

  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final TextEditingController _controller = TextEditingController();
  String? _replyToCommentId;
  String? _replyToAuthorName;

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser!.uid;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color: NeonTheme.surface.withValues(alpha: 0.97),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const Text(
              "Commentaires",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('posts')
                    .doc(widget.postId)
                    .collection('comments')
                    .orderBy('timestamp', descending: false)
                    .snapshots(),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data!.docs;
                  if (docs.isEmpty) {
                    return const Center(
                      child: Text(
                        "Pas encore de commentaires.\nLance la discussion !",
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final doc = docs[i];
                      final data = doc.data() as Map<String, dynamic>;
                      final authorName =
                          (data['authorName'] ?? 'Joueur').toString();
                      final authorId = (data['authorId'] ?? '').toString();
                      final text = (data['text'] ?? '').toString();
                      final parentId = data['parentId'] as String?;
                      final ts = data['timestamp'] as Timestamp?;
                      final dateStr = ts != null
                          ? DateFormat('HH:mm').format(ts.toDate())
                          : "";
                      final isReply = parentId != null;
                      final indent = isReply ? 32.0 : 0.0;
                      final likedBy = List<String>.from(
                        (data['likedBy'] as List?) ?? const <String>[],
                      );
                      final likesCount = (data['likesCount'] ?? 0) as int;
                      final isLiked = likedBy.contains(currentUid);

                      return Padding(
                        padding: EdgeInsets.only(
                          left: 12 + indent,
                          right: 12,
                          bottom: 8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      final currentUid =
                                          FirebaseAuth.instance.currentUser?.uid;
                                      if (authorId == currentUid) {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                const UserProfileScreen(),
                                          ),
                                        );
                                      } else if (authorId.isNotEmpty) {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => PublicProfileScreen(
                                              userId: authorId,
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                    child: Text(
                                      authorName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: NeonTheme.neonBlue,
                                      ),
                                    ),
                                  ),
                                ),
                                if (dateStr.isNotEmpty)
                                  Text(
                                    dateStr,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Colors.white38,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(text),
                            Row(
                              children: [
                                InkWell(
                                  onTap: () => _toggleCommentLike(
                                    commentId: doc.id,
                                    isLiked: isLiked,
                                    commentAuthorId: authorId,
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isLiked
                                              ? Icons.favorite
                                              : Icons.favorite_border,
                                          color: isLiked
                                              ? Colors.pinkAccent
                                              : Colors.white70,
                                          size: 14,
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          likesCount.toString(),
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    setState(() {
                                      _replyToCommentId = doc.id;
                                      _replyToAuthorName = authorName;
                                    });
                                    FocusScope.of(
                                      context,
                                    ).requestFocus(FocusNode());
                                  },
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                    ),
                                    minimumSize: const Size(0, 20),
                                  ),
                                  child: const Text(
                                    "Répondre",
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                                if (authorId == currentUid)
                                  TextButton(
                                    onPressed: () => _deleteComment(doc.id),
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      minimumSize: const Size(0, 20),
                                    ),
                                    child: const Text(
                                      "Supprimer",
                                      style: TextStyle(fontSize: 12, color: Colors.redAccent),
                                    ),
                                  ),
                                TextButton(
                                  onPressed: () => openReportDialog(
                                    context: context,
                                    type: 'report_comment',
                                    postId: widget.postId,
                                    commentId: doc.id,
                                    reportedUserId: authorId,
                                    reportedUserName: authorName,
                                  ),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                    ),
                                    minimumSize: const Size(0, 20),
                                  ),
                                  child: const Text(
                                    "Signaler",
                                    style: TextStyle(fontSize: 12, color: Colors.orange),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            if (_replyToAuthorName != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        "Réponse à $_replyToAuthorName",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () {
                        setState(() {
                          _replyToCommentId = null;
                          _replyToAuthorName = null;
                        });
                      },
                    ),
                  ],
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: NeonTheme.inputStyle(
                          "Ajouter un commentaire",
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.send, color: NeonTheme.neonBlue),
                      onPressed: () => _send(currentUid),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteComment(String commentId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Supprimer le commentaire ?"),
        content: const Text(
          "Cette action est irréversible.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Annuler"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Supprimer", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await FirebaseFirestore.instance
          .collection('posts')
          .doc(widget.postId)
          .collection('comments')
          .doc(commentId)
          .delete();
      await FirebaseFirestore.instance
          .collection('posts')
          .doc(widget.postId)
          .update({'commentsCount': FieldValue.increment(-1)});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Commentaire supprimé.")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur: $e")),
        );
      }
    }
  }

  Future<void> _toggleCommentLike({
    required String commentId,
    required bool isLiked,
    required String commentAuthorId,
  }) async {
    if (!await _checkUserNotBannedForAction(context)) {
      return;
    }
    final currentUid = FirebaseAuth.instance.currentUser!.uid;
    final ref = FirebaseFirestore.instance
        .collection('posts')
        .doc(widget.postId)
        .collection('comments')
        .doc(commentId);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>;
      final likedBy = List<String>.from(
        (data['likedBy'] as List?) ?? const <String>[],
      );
      final already = likedBy.contains(currentUid);

      if (isLiked && already) {
        tx.update(ref, {
          'likedBy': FieldValue.arrayRemove([currentUid]),
          'likesCount': FieldValue.increment(-1),
        });
      } else if (!isLiked && !already) {
        tx.update(ref, {
          'likedBy': FieldValue.arrayUnion([currentUid]),
          'likesCount': FieldValue.increment(1),
        });
      }
    });

    if (!isLiked) {
      await _awardXp(currentUid, 1);
    }

    if (!isLiked &&
        commentAuthorId.isNotEmpty &&
        commentAuthorId != currentUid) {
      await widget.onNotify(
        targetUid: commentAuthorId,
        type: 'comment_like',
        message: "a aimé ton commentaire",
        postId: widget.postId,
        commentId: commentId,
      );
    }
  }

  Future<void> _send(String currentUid) async {
    if (!await _checkUserNotBannedForAction(context)) {
      return;
    }
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final userSnap = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUid)
        .get();
    final userData = userSnap.data();
    final authorName = (userData?['pseudo'] ?? userData?['email'] ?? 'Joueur')
        .toString();

    final commentsRef = FirebaseFirestore.instance
        .collection('posts')
        .doc(widget.postId)
        .collection('comments');

    final newComment = await commentsRef.add({
      'text': text,
      'authorId': currentUid,
      'authorName': authorName,
      'parentId': _replyToCommentId,
      'timestamp': FieldValue.serverTimestamp(),
      'likesCount': 0,
      'likedBy': <String>[],
    });

    await FirebaseFirestore.instance
        .collection('posts')
        .doc(widget.postId)
        .update({'commentsCount': FieldValue.increment(1)});

    // Notifications : au créateur du post + à l’auteur du commentaire parent le cas échéant
    if (widget.postAuthorId.isNotEmpty && widget.postAuthorId != currentUid) {
      await widget.onNotify(
        targetUid: widget.postAuthorId,
        type: 'comment',
        message: "a commenté ton post",
        postId: widget.postId,
        commentId: newComment.id,
      );
    }

    if (_replyToCommentId != null) {
      final parentSnap = await commentsRef.doc(_replyToCommentId).get();
      final parentData = parentSnap.data();
      final parentAuthorId = parentData?['authorId'] as String?;
      if (parentAuthorId != null &&
          parentAuthorId.isNotEmpty &&
          parentAuthorId != currentUid) {
        await widget.onNotify(
          targetUid: parentAuthorId,
          type: 'reply',
          message: "t'a répondu dans un fil",
          postId: widget.postId,
          commentId: newComment.id,
        );
      }
    }

    // Notifications pour les mentions dans ce commentaire
    await _notifyMentionsInComment(
      text: text,
      fromUserId: currentUid,
      fromUserName: authorName,
      postId: widget.postId,
      commentId: newComment.id,
    );

    setState(() {
      _controller.clear();
      _replyToCommentId = null;
      _replyToAuthorName = null;
    });

    // XP pour commentaire posté
    await _awardXp(currentUid, 5);
  }

  Future<void> _notifyMentionsInComment({
    required String text,
    required String fromUserId,
    required String fromUserName,
    required String postId,
    required String commentId,
  }) async {
    final exp = RegExp(r'@([A-Za-z0-9_]+)');
    final matches = exp.allMatches(text);
    final pseudos = <String>{};
    for (final m in matches) {
      pseudos.add(m.group(1)!);
    }
    if (pseudos.isEmpty) return;

    for (final pseudo in pseudos) {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where('pseudo', isEqualTo: pseudo)
          .limit(5)
          .get();
      for (final doc in snap.docs) {
        final uid = doc.id;
        if (uid == fromUserId) continue;
        await widget.onNotify(
          targetUid: uid,
          type: 'mention_comment',
          message: "$fromUserName t'a mentionné dans un commentaire",
          postId: postId,
          commentId: commentId,
        );
      }
    }
  }
}

Future<void> _markAllNotificationsAsRead(String userId) async {
  final snap = await FirebaseFirestore.instance
      .collection('users')
      .doc(userId)
      .collection('notifications')
      .where('read', isEqualTo: false)
      .get();
  for (final doc in snap.docs) {
    await doc.reference.update({'read': true});
  }
}

class NotificationsSheet extends StatelessWidget {
  final String userId;
  const NotificationsSheet({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF1E1C33),
            Color(0xFF030315),
          ],
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Notifications",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text("Tout supprimer ?"),
                        content: const Text(
                          "Supprimer toutes les notifications ?",
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text("Annuler"),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text("Supprimer", style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    final snap = await FirebaseFirestore.instance
                        .collection('users')
                        .doc(userId)
                        .collection('notifications')
                        .get();
                    for (final doc in snap.docs) {
                      await doc.reference.delete();
                    }
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Toutes les notifications ont été supprimées.")),
                      );
                    }
                  },
                  child: const Text("Tout supprimer", style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(userId)
                  .collection('notifications')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      "Aucune notification pour l’instant.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final doc = docs[i];
                    final data = doc.data() as Map<String, dynamic>;
                    final message = (data['message'] ?? '').toString();
                    final type = (data['type'] ?? '').toString();
                    final ts = data['timestamp'] as Timestamp?;
                    final dateStr = ts != null
                        ? DateFormat('dd/MM HH:mm').format(ts.toDate())
                        : "";
                    final read = (data['read'] ?? false) as bool;

                    IconData icon;
                    switch (type) {
                      case 'like':
                      case 'comment_like':
                        icon = Icons.favorite;
                        break;
                      case 'comment':
                        icon = Icons.mode_comment;
                        break;
                      case 'mention_post':
                      case 'mention_comment':
                        icon = Icons.alternate_email;
                        break;
                      case 'follow':
                        icon = Icons.person_add;
                        break;
                      case 'follow_post':
                        icon = Icons.campaign;
                        break;
                      default:
                        icon = Icons.notifications;
                    }

                    return _NeonCard(
                      child: ListTile(
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor:
                              NeonTheme.neonBlue.withValues(alpha: 0.15),
                          child: Icon(
                            icon,
                            color: NeonTheme.neonBlue,
                            size: 18,
                          ),
                        ),
                        title: Text(
                          message,
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: dateStr.isNotEmpty
                            ? Text(
                                dateStr,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              )
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!read)
                              const Icon(
                                Icons.brightness_1,
                                size: 10,
                                color: NeonTheme.accent,
                              ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white54),
                              onPressed: () async {
                                await doc.reference.delete();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text("Notification supprimée.")),
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                        onTap: () async {
                          await doc.reference.update({'read': true});
                          if (!context.mounted) return;
                          final nav = Map<String, dynamic>.from(data);
                          Navigator.of(context).pop();
                          navigateFromNotificationData(nav);
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// --- Édition du profil ---
const _editProfileRanks = [
  'Bronze',
  'Argent',
  'Or',
  'Platine',
  'Diamant',
  'Champion 1',
  'Champion 2',
  'Champion 3',
  'Grand Champion 1',
  'Grand Champion 2',
  'Grand Champion 3',
  'Supersonic Legend',
];

class EditProfileScreen extends StatefulWidget {
  final String uid;
  final Map<String, dynamic> initialData;

  const EditProfileScreen({
    super.key,
    required this.uid,
    required this.initialData,
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _bioController = TextEditingController();
  File? _avatarFile;
  File? _bannerFile;
  String? _avatarUrl;
  String? _bannerUrl;
  String _selectedGame = 'Rocket League';
  String _selectedRank = 'Champion 2';
  final Set<String> _selectedModes = {'2v2'};
  bool _hasMic = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final d = widget.initialData;
    _bioController.text = (d['bio'] ?? '').toString();
    _avatarUrl = d['avatarUrl'] as String?;
    _bannerUrl = d['bannerUrl'] as String?;
    _selectedGame = (d['game'] ?? 'Rocket League').toString();
    _selectedRank = (d['rank'] ?? 'Champion 2').toString();
    final modes = (d['modes'] as List?)?.cast<String>() ?? const <String>[];
    if (modes.isNotEmpty) {
      _selectedModes
        ..clear()
        ..addAll(modes);
    } else {
      _selectedModes
        ..clear()
        ..add((d['mode'] ?? '2v2').toString());
    }
    _hasMic = (d['hasMic'] ?? true) as bool;
  }

  @override
  void dispose() {
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final f = await pickAndCropImage(
      context,
      aspectRatioX: 1,
      aspectRatioY: 1,
      circular: true,
      maxWidth: 512,
      maxHeight: 512,
    );
    if (f != null && mounted) setState(() => _avatarFile = f);
  }

  Future<void> _pickBanner() async {
    final f = await pickAndCropImage(
      context,
      aspectRatioX: 3,
      aspectRatioY: 1,
      circular: false,
      maxWidth: 1200,
      maxHeight: 400,
    );
    if (f != null && mounted) setState(() => _bannerFile = f);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      String? newAvatarUrl = _avatarUrl;
      String? newBannerUrl = _bannerUrl;

      if (_avatarFile != null) {
        final ref =
            FirebaseStorage.instance.ref().child('avatars/${widget.uid}.jpg');
        await ref.putFile(_avatarFile!);
        newAvatarUrl = await ref.getDownloadURL();
      }
      if (_bannerFile != null) {
        final ref =
            FirebaseStorage.instance.ref().child('banners/${widget.uid}.jpg');
        await ref.putFile(_bannerFile!);
        newBannerUrl = await ref.getDownloadURL();
      }

      final primaryMode =
          _selectedModes.isNotEmpty ? _selectedModes.first : '2v2';

      final updates = <String, dynamic>{
        'bio': _bioController.text.trim(),
        'game': _selectedGame,
        'rank': _selectedRank,
        'bestRank': _selectedRank,
        'mode': primaryMode,
        'modes': _selectedModes.toList(),
        'hasMic': _hasMic,
      };
      if (newAvatarUrl != null) updates['avatarUrl'] = newAvatarUrl;
      if (newBannerUrl != null) updates['bannerUrl'] = newBannerUrl;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .update(updates);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Profil enregistré")),
      );
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pseudo = (widget.initialData['pseudo'] ?? '...').toString();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Modifier le profil"),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: NeonTheme.galaxyBgConnected(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  "Photo de profil",
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: _pickAvatar,
                  child: CircleAvatar(
                    radius: 50,
                    backgroundColor: NeonTheme.surface,
                    backgroundImage: _avatarFile != null
                        ? FileImage(_avatarFile!)
                        : (_avatarUrl != null
                            ? NetworkImage(_avatarUrl!) as ImageProvider
                            : null),
                    child: _avatarFile == null && _avatarUrl == null
                        ? const Icon(Icons.add_a_photo, size: 36)
                        : null,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  "Bannière",
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: _pickBanner,
                  child: Container(
                    height: 120,
                    decoration: BoxDecoration(
                      color: NeonTheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      image: _bannerFile != null
                          ? DecorationImage(
                              image: FileImage(_bannerFile!),
                              fit: BoxFit.cover,
                            )
                          : (_bannerUrl != null && _bannerUrl!.isNotEmpty)
                              ? DecorationImage(
                                  image: NetworkImage(_bannerUrl!),
                                  fit: BoxFit.cover,
                                )
                              : null,
                    ),
                    child: _bannerFile == null &&
                            (_bannerUrl == null || _bannerUrl!.isEmpty)
                        ? const Center(
                            child: Icon(Icons.add_photo_alternate, size: 40),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  "Pseudo",
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          "Modification du pseudo disponible dans une prochaine mise à jour.",
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: NeonTheme.surface.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Row(
                      children: [
                        Text(
                          pseudo,
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: Colors.white54,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  "Bio",
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _bioController,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: "Décris-toi en quelques mots...",
                    filled: true,
                    fillColor: NeonTheme.surface.withValues(alpha: 0.6),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 20),
                const Text(
                  "Jeu principal (filtres Mates)",
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _selectedGame,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: NeonTheme.surface.withValues(alpha: 0.6),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  dropdownColor: NeonTheme.surface2,
                  items: const [
                    DropdownMenuItem(
                      value: 'Rocket League',
                      child: Text('Rocket League'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _selectedGame = v);
                  },
                ),
                const SizedBox(height: 16),
                const Text(
                  "Rang (Rocket League)",
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _selectedRank.isNotEmpty &&
                          _editProfileRanks.contains(_selectedRank)
                      ? _selectedRank
                      : 'Champion 2',
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: NeonTheme.surface.withValues(alpha: 0.6),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  dropdownColor: NeonTheme.surface2,
                  items: _editProfileRanks
                      .map(
                        (r) => DropdownMenuItem(
                          value: r,
                          child: Text(r),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _selectedRank = v);
                  },
                ),
                const SizedBox(height: 16),
                const Text(
                  "Mode (1v1 / 2v2 / 3v3)",
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: ['1v1', '2v2', '3v3'].map((m) {
                    final selected = _selectedModes.contains(m);
                    return ChoiceChip(
                      label: Text(m),
                      selected: selected,
                      onSelected: (value) {
                        setState(() {
                          if (value) {
                            _selectedModes.add(m);
                          } else {
                            _selectedModes.remove(m);
                          }
                          if (_selectedModes.isEmpty) {
                            _selectedModes.add('2v2');
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text(
                      "J'utilise un micro",
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Switch(
                      value: _hasMic,
                      onChanged: (v) => setState(() => _hasMic = v),
                      activeColor: NeonTheme.neonBlue,
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text("Enregistrer"),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- 7. PROFIL ---
class UserProfileScreen extends StatelessWidget {
  const UserProfileScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final uid = user.uid;
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final u =
            (snap.data!.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
        final pseudo = (u['pseudo'] ?? '...').toString();
        final rank = (u['rank'] ?? 'Champion 2').toString();
        final role = (u['role'] ?? '').toString();
        final friendsCount = (u['friendsCount'] ?? 0).toString();
        final roomsCount = (u['roomsCount'] ?? 0).toString();
        final avatarUrl = u['avatarUrl'] as String?;
        final rawXp = u['xp'];
        final int xp = rawXp is int ? rawXp : 0;
        final rawLevel = u['level'];
        final int level =
            rawLevel is int ? rawLevel : _computeLevelFromXp(xp);
        final levelTitle =
            (u['levelTitle'] ?? _levelTitleFromLevel(level)).toString();
        final bannerUrl = u['bannerUrl'] as String?;
        final bio = (u['bio'] ?? '').toString();

        String? rankAsset;
        final r = rank.toLowerCase();
        if (r.contains('supersonic') || r.contains('ssl')) {
          rankAsset = 'assets/rl_ssl.png';
        } else if (r.contains('grand')) {
          rankAsset = 'assets/rl_grand_champion.png';
        } else if (r.contains('champion')) {
          rankAsset = 'assets/rl_champion.png';
        } else if (r.contains('diamant') || r.contains('diamond')) {
          rankAsset = 'assets/rl_diamant.png';
        } else if (r.contains('platine') || r.contains('platinum')) {
          rankAsset = 'assets/rl_platine.png';
        } else if (r.contains('or') || r.contains('gold')) {
          rankAsset = 'assets/rl_or.png';
        } else if (r.contains('argent') || r.contains('silver')) {
          rankAsset = 'assets/rl_argent.png';
        } else if (r.contains('bronze')) {
          rankAsset = 'assets/rl_bronze.png';
        } else {
          rankAsset = null;
        }

        return Scaffold(
          body: Container(
            decoration: NeonTheme.galaxyBgConnected(),
            child: SafeArea(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.home, color: Colors.white),
                                onPressed: () => Navigator.pop(context, 'goToHome'),
                                tooltip: 'Accueil',
                              ),
                              Expanded(
                                child: Text(
                                  'Profil',
                                  textAlign: TextAlign.center,
                                  style: NeonTheme.titleGlow(20),
                                ),
                              ),
                              PopupMenuButton<String>(
                                icon: const Icon(
                                    Icons.settings, color: Colors.white),
                                color: NeonTheme.surface2,
                                onSelected: (value) {
                                  if (value == 'edit') {
                                    _openEditProfile(context, uid, u);
                                  } else if (value == 'logout') {
                                    FirebaseAuth.instance.signOut();
                                  }
                                },
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Row(
                                      children: [
                                        Icon(Icons.edit, size: 20),
                                        SizedBox(width: 12),
                                        Text('Modifier le profil'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'logout',
                                    child: Row(
                                      children: [
                                        Icon(Icons.logout, size: 20),
                                        SizedBox(width: 12),
                                        Text('Déconnexion'),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (level > 0)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _NeonPill(text: "Niveau $level"),
                                if (levelTitle.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  _NeonPill(text: levelTitle),
                                ],
                              ],
                            ),
                          const SizedBox(height: 12),
                          if (bannerUrl != null && bannerUrl.isNotEmpty) ...[
                            SizedBox(
                              height: 140 + 52,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: SizedBox(
                                        height: 140,
                                        width: double.infinity,
                                        child: Image.network(
                                          bannerUrl,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 140 - 52,
                                    left: 0,
                                    right: 0,
                                    child: Center(
                                      child: _ProfileAvatar(
                                        avatarUrl: avatarUrl,
                                        rankAsset: rankAsset,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            _ProfileHeader(
                              pseudo: pseudo,
                              rank: rank,
                              role: role.isEmpty ? null : role,
                              avatarUrl: avatarUrl,
                              rankAsset: rankAsset,
                              showAvatar: false,
                            ),
                          ] else
                            _ProfileHeader(
                              pseudo: pseudo,
                              rank: rank,
                              role: role.isEmpty ? null : role,
                              avatarUrl: avatarUrl,
                              rankAsset: rankAsset,
                            ),
                          const SizedBox(height: 8),
                          if (level > 0)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _NeonPill(text: "Niveau $level"),
                                if (levelTitle.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  _NeonPill(text: levelTitle),
                                ],
                              ],
                            ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _QuickStat(
                                    value: friendsCount, label: "Amis"),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _QuickStat(
                                    value: roomsCount, label: "Salons"),
                              ),
                            ],
                          ),
                          if (bio.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            _NeonCard(
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Text(
                                  bio,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.white,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 18),
                          const Text(
                            "Mes publications",
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: Colors.white70,
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                  StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('posts')
                        .where('authorId', isEqualTo: uid)
                        .snapshots(),
                    builder: (context, postSnap) {
                      if (postSnap.hasError) {
                        return SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              children: [
                                Text(
                                  'Impossible de charger les publications.',
                                  style: TextStyle(color: Colors.white70),
                                  textAlign: TextAlign.center,
                                ),
                                if (postSnap.error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                      '${postSnap.error}',
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                      ),
                                      textAlign: TextAlign.center,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      }
                      if (!postSnap.hasData) {
                        return const SliverFillRemaining(
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final allDocs = postSnap.data!.docs;
                      final docs = allDocs.toList()
                        ..sort((a, b) {
                          final ma = a.data() as Map<String, dynamic>?;
                          final mb = b.data() as Map<String, dynamic>?;
                          final ta = ma?['timestamp'] as Timestamp?;
                          final tb = mb?['timestamp'] as Timestamp?;
                          if (ta == null && tb == null) return 0;
                          if (ta == null) return 1;
                          if (tb == null) return -1;
                          return tb.millisecondsSinceEpoch
                              .compareTo(ta.millisecondsSinceEpoch);
                        });
                      if (docs.isEmpty) {
                        return SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              "Aucune publication.\nPublie depuis ici ou depuis l’onglet Social !",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        );
                      }
                      return SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final doc = docs[i];
                            final data =
                                doc.data() as Map<String, dynamic>;
                            return _PostCard(
                              postId: doc.id,
                              data: data,
                              currentUid: uid,
                              authorId: (data['authorId'] ?? '').toString(),
                              currentUserRole: (u['role'] ?? 'user').toString(),
                              onNotify: ({required String targetUid, required String type, required String message, required String postId, String? commentId}) async {},
                            );
                          },
                          childCount: docs.length,
                        ),
                      );
                    },
                  ),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: 80),
                  ),
                ],
              ),
            ),
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _openCreatePostFromProfile(context, uid, pseudo, avatarUrl),
            backgroundColor: NeonTheme.neonBlue,
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  static void _openEditProfile(
    BuildContext context,
    String uid,
    Map<String, dynamic> userData,
  ) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditProfileScreen(uid: uid, initialData: userData),
      ),
    );
  }

  static Future<void> _openCreatePostFromProfile(
    BuildContext context,
    String uid,
    String currentName, String? currentAvatar,
  ) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CreatePostSheetContent(
        currentUid: uid,
        currentName: currentName,
        currentAvatar: currentAvatar,
        onNotifyMentions: null,
      ),
    );
  }

  String? _rankAsset(String rank) {
    final r = rank.toLowerCase();
    if (r.contains('supersonic') || r.contains('ssl')) {
      return 'assets/rl_ssl.png';
    }
    if (r.contains('grand')) return 'assets/rl_grand_champion.png';
    if (r.contains('champion')) return 'assets/rl_champion.png';
    if (r.contains('diamant') || r.contains('diamond')) {
      return 'assets/rl_diamant.png';
    }
    if (r.contains('platine') || r.contains('platinum')) {
      return 'assets/rl_platine.png';
    }
    if (r.contains('or') || r.contains('gold')) return 'assets/rl_or.png';
    if (r.contains('argent') || r.contains('silver')) {
      return 'assets/rl_argent.png';
    }
    if (r.contains('bronze')) return 'assets/rl_bronze.png';
    return null;
  }
}

class PublicProfileScreen extends StatelessWidget {
  final String userId;
  const PublicProfileScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
      });
      return const Center(child: CircularProgressIndicator());
    }
    if (currentUid == userId) {
      return const UserProfileScreen();
    }

    final ids = [currentUid, userId]..sort();
    final friendshipId = "${ids[0]}_${ids[1]}";

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData || !snap.data!.exists) {
          return const Center(child: CircularProgressIndicator());
        }
        final u =
            (snap.data!.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
        final pseudo = (u['pseudo'] ?? '...').toString();
        final rank = (u['rank'] ?? 'Champion 2').toString();
        final friendsCount = (u['friendsCount'] ?? 0).toString();
        final roomsCount = (u['roomsCount'] ?? 0).toString();
        final avatarUrl = u['avatarUrl'] as String?;
        final role = (u['role'] ?? '').toString();
        final rawXp = u['xp'];
        final int xp = rawXp is int ? rawXp : 0;
        final rawLevel = u['level'];
        final int level =
            rawLevel is int ? rawLevel : _computeLevelFromXp(xp);
        final levelTitle =
            (u['levelTitle'] ?? _levelTitleFromLevel(level)).toString();

        final mode = (u['mode'] ?? '2v2').toString();
        final bestRank = (u['bestRank'] ?? rank).toString();
        final playerSince = (u['playerSince'] ?? '2018').toString();
        final mainCar = (u['mainCar'] ?? 'Fennec').toString();
        final searchRank = (u['searchRank'] ?? 'C3').toString();

        final rankAsset = _rankAssetFromRank(rank);

        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('friendships')
              .doc(friendshipId)
              .snapshots(),
          builder: (context, relSnap) {
            String? status;
            String? requestFrom;
            String? requestTo;
            String? blockedBy;
            if (relSnap.hasData && relSnap.data!.exists) {
              final data =
                  relSnap.data!.data() as Map<String, dynamic>? ?? {};
              status = (data['status'] ?? 'accepted').toString();
              requestFrom = (data['requestFrom'] ?? '').toString();
              requestTo = (data['requestTo'] ?? '').toString();
              blockedBy = (data['blockedBy'] ?? '').toString();
            }

            final isBlocked =
                status == 'blocked' && (blockedBy ?? '').isNotEmpty;
            final bool isSelfProfile = currentUid == userId;

            String mainButtonText = "Ajouter en ami";
            VoidCallback? mainButtonOnPressed;
            bool mainButtonEnabled = true;
            String secondaryText = "Bloquer";
            VoidCallback? secondaryOnPressed;
            String? tertiaryText;
            VoidCallback? tertiaryOnPressed;

            if (isBlocked && blockedBy == currentUid) {
              mainButtonText = "Bloqué";
              mainButtonEnabled = false;
              secondaryText = "Débloquer";
              secondaryOnPressed = () {
                _MateCard.unblockUser(
                  context,
                  currentUid: currentUid,
                  otherUid: userId,
                );
              };
            } else if (status == null || status.isEmpty) {
              mainButtonText = "Ajouter en ami";
              mainButtonOnPressed = () {
                _MateCard._sendFriendRequest(
                  context: context,
                  currentUid: currentUid,
                  otherUid: userId,
                );
              };
              secondaryOnPressed = () {
                _MateCard.blockUser(
                  context,
                  currentUid: currentUid,
                  otherUid: userId,
                );
              };
            } else if (status == 'request') {
              final isRecipient = requestTo == currentUid;
              final isRequester = requestFrom == currentUid;
              if (isRecipient) {
                mainButtonText = "Accepter la demande";
                mainButtonOnPressed = () {
                  _MateCard._acceptFriendRequest(
                    context,
                    currentUid: currentUid,
                    otherUid: userId,
                  );
                };
                secondaryOnPressed = () {
                  _MateCard.removeFriendship(
                    context,
                    currentUid: currentUid,
                    otherUid: userId,
                  );
                };
              } else if (isRequester) {
                mainButtonText = "Demande envoyée";
                mainButtonEnabled = false;
                secondaryOnPressed = () {
                  _MateCard.removeFriendship(
                    context,
                    currentUid: currentUid,
                    otherUid: userId,
                  );
                };
              }
            } else if (status == 'accepted') {
              mainButtonText = "Ami";
              mainButtonEnabled = false;
              secondaryText = "Supprimer";
              secondaryOnPressed = () {
                _MateCard.removeFriendship(
                  context,
                  currentUid: currentUid,
                  otherUid: userId,
                );
              };
              tertiaryText = "Bloquer";
              tertiaryOnPressed = () {
                _MateCard.blockUser(
                  context,
                  currentUid: currentUid,
                  otherUid: userId,
                );
              };
            }

            return Scaffold(
      appBar: AppBar(
        backgroundColor: NeonTheme.bgDark,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(pseudo),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'report_profile') {
                openReportDialog(
                  context: context,
                  type: 'profile',
                  reportedUserId: userId,
                  reportedUserName: pseudo,
                );
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'report_profile',
                child: Text('Signaler ce profil'),
              ),
            ],
          ),
        ],
      ),
              body: Container(
                decoration: NeonTheme.galaxyBgConnected(),
                child: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 10, 18, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    const SizedBox(height: 16),
                    _ProfileHeader(
                      pseudo: pseudo,
                      rank: rank,
                      role: role.isEmpty ? null : role,
                      avatarUrl: avatarUrl,
                      rankAsset: rankAsset,
                    ),
                    const SizedBox(height: 8),
                    if (level > 0)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _NeonPill(text: "Niveau $level"),
                          if (levelTitle.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            _NeonPill(text: levelTitle),
                          ],
                        ],
                      ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _QuickStat(
                              value: friendsCount, label: "Amis"),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _QuickStat(
                              value: roomsCount, label: "Salons"),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    StreamBuilder<DocumentSnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('users')
                          .doc(currentUid)
                          .snapshots(),
                      builder: (context, staffSnap) {
                        if (!staffSnap.hasData || !staffSnap.data!.exists) {
                          return const SizedBox.shrink();
                        }
                        final sdata = staffSnap.data!.data()
                                as Map<String, dynamic>? ??
                            {};
                        final srole =
                            (sdata['role'] ?? 'user').toString().toLowerCase();
                        final bool isStaff = _isStaffRole(srole);
                        if (!isStaff || isSelfProfile) {
                          return const SizedBox.shrink();
                        }
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'ban_24h') {
                                  _banUserFromProfile(
                                    context,
                                    userId,
                                    duration: const Duration(hours: 24),
                                  );
                                } else if (value == 'ban_7d') {
                                  _banUserFromProfile(
                                    context,
                                    userId,
                                    duration: const Duration(days: 7),
                                  );
                                } else if (value == 'ban_perm') {
                                  _banUserFromProfile(
                                    context,
                                    userId,
                                    duration: null,
                                  );
                                }
                              },
                              itemBuilder: (ctx) => const [
                                PopupMenuItem(
                                  value: 'ban_24h',
                                  child: Text('Bannir 24h'),
                                ),
                                PopupMenuItem(
                                  value: 'ban_7d',
                                  child: Text('Bannir 7 jours'),
                                ),
                                PopupMenuItem(
                                  value: 'ban_perm',
                                  child: Text('Ban définitif'),
                                ),
                              ],
                              child: ElevatedButton.icon(
                                onPressed: null,
                                icon: const Icon(Icons.gavel),
                                label: const Text("Modération"),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    if (!isSelfProfile)
              StreamBuilder<DocumentSnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('follows')
                            .doc("${currentUid}_$userId")
                            .snapshots(),
                        builder: (context, followSnap) {
                          final isFollowing = followSnap.hasData &&
                              followSnap.data != null &&
                              followSnap.data!.exists;
                          return ElevatedButton(
                            onPressed: () async {
                              if (!await _checkUserNotBannedForAction(context)) {
                                return;
                              }
                              try {
                                final docRef = FirebaseFirestore.instance
                                    .collection('follows')
                                    .doc("${currentUid}_$userId");
                                if (isFollowing) {
                                  await docRef.delete();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content:
                                          Text("Tu ne suis plus ce joueur."),
                                    ),
                                  );
                                } else {
                                  await docRef.set({
                                    'followerId': currentUid,
                                    'targetId': userId,
                                    'createdAt':
                                        FieldValue.serverTimestamp(),
                                  });
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text("Tu suis maintenant ce joueur."),
                                    ),
                                  );
                                  try {
                                    final currentUserSnap =
                                        await FirebaseFirestore.instance
                                            .collection('users')
                                            .doc(currentUid)
                                            .get();
                                    final currentUserData =
                                        currentUserSnap.data() ?? <String, dynamic>{};
                                    final fromName = (currentUserData['pseudo'] ??
                                            currentUserData['email'] ??
                                            'Quelqu\'un')
                                        .toString();

                                    await FirebaseFirestore.instance
                                        .collection('users')
                                        .doc(userId)
                                        .collection('notifications')
                                        .add({
                                      'type': 'follow',
                                      'message': "$fromName te suit maintenant.",
                                      'postId': '',
                                      'commentId': null,
                                      'fromUserId': currentUid,
                                      'fromUserName': fromName,
                                      'timestamp': FieldValue.serverTimestamp(),
                                      'read': false,
                                    });
                                  } catch (_) {}
                                }
                              } catch (e) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      "Erreur lors de la mise à jour du follow: $e",
                                    ),
                                  ),
                                );
                              }
                            },
                            child: Text(
                              isFollowing ? "Ne plus suivre" : "Suivre",
                            ),
                          );
                        },
                      ),
                    const SizedBox(height: 18),
                    const Text(
                      "Ses publications",
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 8),
                    StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('posts')
                          .where('authorId', isEqualTo: userId)
                          .snapshots(),
                      builder: (context, postSnap) {
                        if (!postSnap.hasData) {
                          return const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(
                                child: SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)),
                          ),
                          );
                        }
                        final allDocs = postSnap.data!.docs;
                        final docs = allDocs.toList()
                          ..sort((a, b) {
                            final ma =
                                a.data() as Map<String, dynamic>?;
                            final mb =
                                b.data() as Map<String, dynamic>?;
                            final ta = ma?['timestamp'] as Timestamp?;
                            final tb = mb?['timestamp'] as Timestamp?;
                            if (ta == null && tb == null) return 0;
                            if (ta == null) return 1;
                            if (tb == null) return -1;
                            return tb.millisecondsSinceEpoch
                                .compareTo(ta.millisecondsSinceEpoch);
                          });
                        final bool isFriend = status == 'accepted';
                        final visibleDocs = docs.where((doc) {
                          final data =
                              doc.data() as Map<String, dynamic>? ?? {};
                          final visibility =
                              (data['visibility'] ?? 'friends').toString();
                          if (isSelfProfile) return true;
                          if (visibility == 'public') return true;
                          if (visibility == 'friends') return isFriend;
                          if (visibility == 'private') return false;
                          return false;
                        }).toList();
                        if (visibleDocs.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              isSelfProfile
                                  ? "Aucune publication pour l'instant."
                                  : "Aucune publication visible pour l'instant.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 14,
                              ),
                            ),
                          );
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: visibleDocs.map((doc) {
                            final data =
                                doc.data() as Map<String, dynamic>;
                            return _PostCard(
                              postId: doc.id,
                              data: data,
                              currentUid: currentUid,
                              authorId: (data['authorId'] ?? '')
                                  .toString(),
                              currentUserRole: 'user',
                              onNotify: ({required String targetUid,
                                  required String type,
                                  required String message,
                                  required String postId,
                                  String? commentId}) async {},
                            );
                          }).toList(),
                        );
                      },
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed:
                                mainButtonEnabled ? mainButtonOnPressed : null,
                            child: Text(mainButtonText),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: secondaryOnPressed,
                            child: Text(secondaryText),
                          ),
                        ),
                        if (tertiaryText != null && tertiaryOnPressed != null) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: tertiaryOnPressed,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.orange,
                                side: const BorderSide(color: Colors.orange),
                              ),
                              child: Text(tertiaryText!),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: isBlocked
                          ? null
                          : () {
                              _MateCard._openChat(
                                context,
                                userId,
                                pseudo,
                              );
                            },
                      child: const Text("Envoyer un message"),
                    ),
                  ],
                ),
              ),
            ),
                  ),
                );
          },
        );
      },
    );
  }
}

class _ProfileTopBar extends StatelessWidget {
  final String title;
  final VoidCallback onSettingsTap;
  const _ProfileTopBar({required this.title, required this.onSettingsTap});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 42),
        Expanded(
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: NeonTheme.titleGlow(20),
          ),
        ),
        SizedBox(
          width: 42,
          height: 42,
          child: IconButton(
            onPressed: onSettingsTap,
            icon: const Icon(Icons.settings, color: Colors.white),
            splashRadius: 22,
          ),
        ),
      ],
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String? rankAsset;
  const _ProfileAvatar({this.avatarUrl, this.rankAsset});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [
                NeonTheme.accent,
                NeonTheme.neonBlue.withValues(alpha: 0.8),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: NeonTheme.accent.withValues(alpha: 0.25),
                blurRadius: 18,
                spreadRadius: 2,
              ),
            ],
          ),
          child: CircleAvatar(
            radius: 52,
            backgroundColor: NeonTheme.surface2.withValues(alpha: 0.75),
            backgroundImage: avatarUrl != null
                ? NetworkImage(avatarUrl!)
                : null,
            child: avatarUrl == null
                ? const Icon(Icons.person, size: 44, color: Colors.white70)
                : null,
          ),
        ),
        if (rankAsset != null)
          Positioned(
            bottom: -4,
            right: -4,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: NeonTheme.surface2.withValues(alpha: 0.85),
                shape: BoxShape.circle,
                border: Border.all(
                  color: NeonTheme.neonBlue.withValues(alpha: 0.35),
                ),
                boxShadow: [
                  BoxShadow(
                    color: NeonTheme.neonBlue.withValues(alpha: 0.20),
                    blurRadius: 14,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Image.asset(rankAsset!, width: 26, height: 26),
            ),
          ),
      ],
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  final String pseudo;
  final String rank;
  final String? role;
  final String? avatarUrl;
  final String? rankAsset;
  final bool showAvatar;
  const _ProfileHeader({
    required this.pseudo,
    required this.rank,
    this.role,
    this.avatarUrl,
    this.rankAsset,
    this.showAvatar = true,
  });

  @override
  Widget build(BuildContext context) {
    String? badgeRole;
    if (role != null && role!.isNotEmpty) {
      final rl = role!.toLowerCase();
      if (rl == 'admin') {
        badgeRole = 'Admin';
      } else if (rl == 'community_manager') {
        badgeRole = 'Com.';
      } else if (rl == 'founder') {
        badgeRole = 'Fondateur';
      } else if (rl == 'cofounder') {
        badgeRole = 'Co-fondateur';
      } else {
        badgeRole = role;
      }
    }

    return Column(
      children: [
        if (showAvatar) _ProfileAvatar(avatarUrl: avatarUrl, rankAsset: rankAsset),
        if (showAvatar) const SizedBox(height: 12),
        Text(
          pseudo,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _NeonPill(text: rank),
            if (badgeRole != null && badgeRole!.isNotEmpty) ...[
              const SizedBox(width: 8),
              _NeonPill(text: badgeRole!),
            ],
          ],
        ),
      ],
    );
  }
}

class _QuickStat extends StatelessWidget {
  final String value;
  final String label;
  const _QuickStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return _NeonCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Colors.white60)),
          ],
        ),
      ),
    );
  }
}

class _NeonPill extends StatelessWidget {
  final String text;
  const _NeonPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: NeonTheme.neonBlue.withValues(alpha: 0.55)),
        color: NeonTheme.surface2.withValues(alpha: 0.50),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(text, style: NeonTheme.labelGlow()),
      ),
    );
  }
}

class _NeonCard extends StatelessWidget {
  final Widget child;
  const _NeonCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: NeonTheme.neonCardDecoration(),
          child: child,
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final String label;
  final String value;
  const _InfoLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white60,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  final int index;
  const _ActivityCard({required this.index});

  @override
  Widget build(BuildContext context) {
    final titles = ["Matchmaking", "Tournoi", "Highlights"];
    return SizedBox(
      width: 180,
      child: _NeonCard(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    index == 0
                        ? Icons.sports_esports
                        : index == 1
                        ? Icons.emoji_events
                        : Icons.movie,
                    color: NeonTheme.neonBlue,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      titles[index % titles.length],
                      style: const TextStyle(fontWeight: FontWeight.w800),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(
                      colors: [
                        NeonTheme.accent.withValues(alpha: 0.35),
                        NeonTheme.neonBlue.withValues(alpha: 0.20),
                        Colors.white10,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: const Center(
                    child: Icon(Icons.image, color: Colors.white30),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NeonOutlinedButton extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _NeonOutlinedButton({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        decoration: BoxDecoration(
          color: NeonTheme.surface2.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: NeonTheme.accent.withValues(alpha: 0.45)),
          boxShadow: [
            BoxShadow(
              color: NeonTheme.accent.withValues(alpha: 0.10),
              blurRadius: 20,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}
