import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as walkmatesMath;
import 'dart:ui';

import 'package:appsflyer_sdk/appsflyer_sdk.dart'
    show AppsFlyerOptions, AppsflyerSdk;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, SystemUiOverlayStyle, SystemChrome;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as walkmatesTimezoneData;
import 'package:timezone/timezone.dart' as walkmatesTimezone;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// Если эти классы есть в main.dart – оставь импорт.
import 'main.dart' show MafiaHarbor, CaptainHarbor, BillHarbor;

// ============================================================================
// NCUP инфраструктура (бывшая Dress Retro инфраструктура)
// ============================================================================

class WalkmatesLogger {
  const WalkmatesLogger();

  void walkmatesLogInfo(Object walkmatesMessage) =>
      debugPrint('[DressRetroLogger] $walkmatesMessage');

  void walkmatesLogWarn(Object walkmatesMessage) =>
      debugPrint('[DressRetroLogger/WARN] $walkmatesMessage');

  void walkmatesLogError(Object walkmatesMessage) =>
      debugPrint('[DressRetroLogger/ERR] $walkmatesMessage');
}

class WalkmatesVault {
  static final WalkmatesVault sharedInstance =
  WalkmatesVault._internalConstructor();
  WalkmatesVault._internalConstructor();
  factory WalkmatesVault() => sharedInstance;

  final WalkmatesLogger walkmatesLoggerInstance = const WalkmatesLogger();
}

// ============================================================================
// Константы (статистика/кеш) — строки в кавычках не меняем
// ============================================================================

const String walkmatesLoadedOnceKey = 'wheel_loaded_once';
const String walkmatesStatEndpoint = 'https://getgame.portalroullete.bar/stat';
const String walkmatesCachedFcmKey = 'wheel_cached_fcm';

// НОВОЕ: ключи для сохранения SafeArea и цвета в SharedPreferences
const String walkmatesSafeAreaEnabledKey = 'safearea_enabled';
const String walkmatesSafeAreaColorKey = 'safearea_color';

// ---------------- Bank constants (из первого main.dart) ----------------

const Set<String> kBankSchemes = {
  'td',
  'rbc',
  'cibc',
  'scotiabank',
  'bmo',
  'bmodigitalbanking',
  'desjardins',
  'tangerine',
  'nationalbank',
  'simplii',
  'dominotoronto',
};

const Set<String> kBankDomains = {
  'td.com',
  'tdcanadatrust.com',
  'easyweb.td.com',
  'rbc.com',
  'royalbank.com',
  'online.royalbank.com',
  'cibc.com',
  'cibc.ca',
  'online.cibc.com',
  'scotiabank.com',
  'scotiaonline.scotiabank.com',
  'bmo.com',
  'bmo.ca',
  'bmodigitalbanking.com',
  'desjardins.com',
  'tangerine.ca',
  'nbc.ca',
  'nationalbank.ca',
  'simplii.com',
  'simplii.ca',
  'dominotoronto.com',
  'dominobank.com',
};

// ============================================================================
// Утилиты: WalkmatesKit (бывший DressRetroKit / NcupKit)
// ============================================================================

class WalkmatesKit {
  static bool walkmatesLooksLikeBareMail(Uri walkmatesUri) {
    final String walkmatesScheme = walkmatesUri.scheme;
    if (walkmatesScheme.isNotEmpty) return false;
    final String walkmatesRaw = walkmatesUri.toString();
    return walkmatesRaw.contains('@') && !walkmatesRaw.contains(' ');
  }

  static Uri walkmatesToMailto(Uri walkmatesUri) {
    final String walkmatesFull = walkmatesUri.toString();
    final List<String> walkmatesBits = walkmatesFull.split('?');
    final String walkmatesWho = walkmatesBits.first;
    final Map<String, String> walkmatesQuery =
    walkmatesBits.length > 1 ? Uri.splitQueryString(walkmatesBits[1]) : <String, String>{};
    return Uri(
      scheme: 'mailto',
      path: walkmatesWho,
      queryParameters: walkmatesQuery.isEmpty ? null : walkmatesQuery,
    );
  }

  static Uri walkmatesGmailize(Uri walkmatesMailUri) {
    final Map<String, String> walkmatesQp = walkmatesMailUri.queryParameters;
    final Map<String, String> walkmatesParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (walkmatesMailUri.path.isNotEmpty) 'to': walkmatesMailUri.path,
      if ((walkmatesQp['subject'] ?? '').isNotEmpty) 'su': walkmatesQp['subject']!,
      if ((walkmatesQp['body'] ?? '').isNotEmpty) 'body': walkmatesQp['body']!,
      if ((walkmatesQp['cc'] ?? '').isNotEmpty) 'cc': walkmatesQp['cc']!,
      if ((walkmatesQp['bcc'] ?? '').isNotEmpty) 'bcc': walkmatesQp['bcc']!,
    };
    return Uri.https('mail.google.com', '/mail/', walkmatesParams);
  }

  static String walkmatesDigitsOnly(String walkmatesSource) =>
      walkmatesSource.replaceAll(RegExp(r'[^0-9+]'), '');
}

// ============================================================================
// Сервис открытия ссылок: WalkmatesLinker (бывший DressRetroLinker / NcupLinker)
// ============================================================================

class WalkmatesLinker {
  static Future<bool> walkmatesOpen(Uri walkmatesUri) async {
    try {
      if (await launchUrl(
        walkmatesUri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }
      return await launchUrl(
        walkmatesUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (walkmatesError) {
      debugPrint('DressRetroLinker error: $walkmatesError; url=$walkmatesUri');
      try {
        return await launchUrl(
          walkmatesUri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }
}

// ============================================================================
// Bank helpers (из первого main.dart)
// ============================================================================

bool walkmatesIsBankScheme(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  return kBankSchemes.contains(scheme);
}

bool walkmatesIsBankDomain(Uri uri) {
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return false;

  for (final String bank in kBankDomains) {
    final String bankHost = bank.toLowerCase();
    if (host == bankHost || host.endsWith('.$bankHost')) {
      return true;
    }
  }
  return false;
}

Future<bool> walkmatesOpenBank(Uri uri) async {
  try {
    if (walkmatesIsBankScheme(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }

    if ((uri.scheme == 'http' || uri.scheme == 'https') &&
        walkmatesIsBankDomain(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }
  } catch (e) {
    debugPrint('walkmatesOpenBank error: $e; url=$uri');
  }
  return false;
}

// ============================================================================
// FCM Background Handler
// ============================================================================

@pragma('vm:entry-point')
Future<void> walkmatesFcmBackgroundHandler(RemoteMessage walkmatesMessage) async {
  debugPrint("Spin ID: ${walkmatesMessage.messageId}");
  debugPrint("Spin Data: ${walkmatesMessage.data}");
}

// ============================================================================
// WalkmatesDeviceProfile (бывший DressRetroDeviceProfile / NcupDeviceProfile)
// ============================================================================

class WalkmatesDeviceProfile {
  String? walkmatesDeviceId;
  String? walkmatesSessionId = 'wheel-one-off';
  String? walkmatesPlatformKind;
  String? walkmatesOsBuild;
  String? walkmatesAppVersion;
  String? walkmatesLocaleCode;
  String? walkmatesTimezoneName;
  bool walkmatesPushEnabled = true;

  // Новый UA из WebView
  String? walkmatesBaseUserAgent;

  // Для SafeArea
  bool walkmatesSafeAreaEnabled = false;
  String? walkmatesSafeAreaColor;

  Future<void> walkmatesInitialize() async {
    try {
      walkmatesTimezoneData.initializeTimeZones();
    } catch (_) {}

    final DeviceInfoPlugin walkmatesInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo walkmatesAndroidInfo =
      await walkmatesInfoPlugin.androidInfo;
      walkmatesDeviceId = walkmatesAndroidInfo.id;
      walkmatesPlatformKind = 'android';
      walkmatesOsBuild = walkmatesAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo walkmatesIosInfo = await walkmatesInfoPlugin.iosInfo;
      walkmatesDeviceId = walkmatesIosInfo.identifierForVendor;
      walkmatesPlatformKind = 'ios';
      walkmatesOsBuild = walkmatesIosInfo.systemVersion;
    }

    final PackageInfo walkmatesPackageInfo = await PackageInfo.fromPlatform();
    walkmatesAppVersion = walkmatesPackageInfo.version;
    walkmatesLocaleCode = Platform.localeName.split('_').first;
    walkmatesTimezoneName = walkmatesTimezone.local.name;
    walkmatesSessionId = 'wheel-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> walkmatesAsMap({String? walkmatesFcmToken}) =>
      <String, dynamic>{
        'fcm_token': walkmatesFcmToken ?? 'missing_token',
        'device_id': walkmatesDeviceId ?? 'missing_id',
        'app_name': 'matewalk',
        'instance_id': walkmatesSessionId ?? 'missing_session',
        'platform': walkmatesPlatformKind ?? 'missing_system',
        'os_version': walkmatesOsBuild ?? 'missing_build',
        'app_version': walkmatesAppVersion ?? 'missing_app',
        'language': walkmatesLocaleCode ?? 'en',
        'timezone': walkmatesTimezoneName ?? 'UTC',
        'push_enabled': walkmatesPushEnabled,
        'fthcashier': 'true',
        'safearea': walkmatesSafeAreaEnabled,
        'safearea_color': walkmatesSafeAreaColor ?? '',
        'base_ua': walkmatesBaseUserAgent ?? '',
      };
}

// ============================================================================
// AppsFlyer шпион: WalkmatesSpy (бывший DressRetroSpy / NcupSpy)
// ============================================================================

class WalkmatesSpy {
  AppsFlyerOptions? walkmatesOptions;
  AppsflyerSdk? walkmatesSdk;

  String walkmatesAppsFlyerUid = '';
  String walkmatesAppsFlyerData = '';

  void walkmatesStart({VoidCallback? walkmatesOnUpdate}) {
    final AppsFlyerOptions walkmatesOpts = AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6756072063',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    walkmatesOptions = walkmatesOpts;
    walkmatesSdk = AppsflyerSdk(walkmatesOpts);

    walkmatesSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    walkmatesSdk?.startSDK(
      onSuccess: () =>
          WalkmatesVault().walkmatesLoggerInstance.walkmatesLogInfo('WheelSpy started'),
      onError: (walkmatesCode, walkmatesMsg) => WalkmatesVault()
          .walkmatesLoggerInstance
          .walkmatesLogError('WheelSpy error $walkmatesCode: $walkmatesMsg'),
    );

    walkmatesSdk?.onInstallConversionData((walkmatesValue) {
      walkmatesAppsFlyerData = walkmatesValue.toString();
      walkmatesOnUpdate?.call();
    });

    walkmatesSdk?.getAppsFlyerUID().then((walkmatesValue) {
      walkmatesAppsFlyerUid = walkmatesValue.toString();
      walkmatesOnUpdate?.call();
    });
  }
}

// ============================================================================
// Мост для FCM токена: WalkmatesFcmBridge (бывший DressRetroFcmBridge / NcupFcmBridge)
// ============================================================================

class WalkmatesFcmBridge {
  final WalkmatesLogger walkmatesLog = const WalkmatesLogger();
  String? walkmatesToken;
  final List<void Function(String)> walkmatesWaiters = <void Function(String)>[];

  String? get walkmatesCurrentToken => walkmatesToken;

  WalkmatesFcmBridge() {
    const MethodChannel('com.example.fcm/token')
        .setMethodCallHandler((MethodCall walkmatesCall) async {
      if (walkmatesCall.method == 'setToken') {
        final String walkmatesTokenString = walkmatesCall.arguments as String;
        if (walkmatesTokenString.isNotEmpty) {
          walkmatesSetToken(walkmatesTokenString);
        }
      }
    });

    walkmatesRestoreToken();
  }

  Future<void> walkmatesRestoreToken() async {
    try {
      final SharedPreferences walkmatesPrefs =
      await SharedPreferences.getInstance();
      final String? walkmatesCached = walkmatesPrefs.getString(walkmatesCachedFcmKey);
      if (walkmatesCached != null && walkmatesCached.isNotEmpty) {
        walkmatesSetToken(walkmatesCached, walkmatesNotify: false);
      }
    } catch (_) {}
  }

  Future<void> walkmatesPersistToken(String walkmatesNewToken) async {
    try {
      final SharedPreferences walkmatesPrefs =
      await SharedPreferences.getInstance();
      await walkmatesPrefs.setString(walkmatesCachedFcmKey, walkmatesNewToken);
    } catch (_) {}
  }

  void walkmatesSetToken(
      String walkmatesNewToken, {
        bool walkmatesNotify = true,
      }) {
    walkmatesToken = walkmatesNewToken;
    walkmatesPersistToken(walkmatesNewToken);
    if (walkmatesNotify) {
      for (final void Function(String) walkmatesCallback
      in List<void Function(String)>.from(walkmatesWaiters)) {
        try {
          walkmatesCallback(walkmatesNewToken);
        } catch (walkmatesErr) {
          walkmatesLog.walkmatesLogWarn('fcm waiter error: $walkmatesErr');
        }
      }
      walkmatesWaiters.clear();
    }
  }

  Future<void> walkmatesWaitForToken(
      Function(String walkmatesTokenValue) walkmatesOnToken,
      ) async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if ((walkmatesToken ?? '').isNotEmpty) {
        walkmatesOnToken(walkmatesToken!);
        return;
      }

      walkmatesWaiters.add(walkmatesOnToken);
    } catch (walkmatesErr) {
      walkmatesLog.walkmatesLogError('wheelWaitToken error: $walkmatesErr');
    }
  }
}

// ============================================================================
// WalkmatesLoader (новый лоадер, бывший NcupLoader)
// ============================================================================

class WalkmatesLoader extends StatefulWidget {
  const WalkmatesLoader({Key? key}) : super(key: key);

  @override
  State<WalkmatesLoader> createState() => _WalkmatesLoaderState();
}

class _WalkmatesLoaderState extends State<WalkmatesLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController walkmatesController;

  static const Color walkmatesBackgroundColor = Color(0xFF05071B);

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));
    walkmatesController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    walkmatesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: walkmatesBackgroundColor,
      child: AnimatedBuilder(
        animation: walkmatesController,
        builder: (BuildContext context, Widget? child) {
          final double walkmatesPhase =
              walkmatesController.value * 2 * walkmatesMath.pi;
          return CustomPaint(
            painter: WalkmatesLoaderPainter(
              walkmatesPhase: walkmatesPhase,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class WalkmatesLoaderPainter extends CustomPainter {
  final double walkmatesPhase;

  WalkmatesLoaderPainter({
    required this.walkmatesPhase,
  });

  @override
  void paint(Canvas walkmatesCanvas, Size walkmatesSize) {
    final double walkmatesWidth = walkmatesSize.width;
    final double walkmatesHeight = walkmatesSize.height;

    final Paint walkmatesBackgroundPaint = Paint()
      ..color = const Color(0xFF05071B)
      ..style = PaintingStyle.fill;
    walkmatesCanvas.drawRect(Offset.zero & walkmatesSize, walkmatesBackgroundPaint);

    final double walkmatesPulse = (walkmatesMath.sin(walkmatesPhase) + 1) / 2;

    final Paint walkmatesCirclePaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.red.withOpacity(0.14 + 0.16 * walkmatesPulse),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(walkmatesWidth * 0.5, walkmatesHeight * 0.45),
          radius: walkmatesHeight * (0.4 + 0.15 * walkmatesPulse),
        ),
      );

    walkmatesCanvas.drawCircle(
      Offset(walkmatesWidth * 0.5, walkmatesHeight * 0.45),
      walkmatesHeight * (0.4 + 0.15 * walkmatesPulse),
      walkmatesCirclePaint,
    );

    final Paint walkmatesOuterPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.redAccent.withOpacity(0.10 + 0.10 * (1 - walkmatesPulse)),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(walkmatesWidth * 0.5, walkmatesHeight * 0.45),
          radius: walkmatesHeight * (0.55 + 0.10 * (1 - walkmatesPulse)),
        ),
      );
    walkmatesCanvas.drawCircle(
      Offset(walkmatesWidth * 0.5, walkmatesHeight * 0.45),
      walkmatesHeight * (0.55 + 0.10 * (1 - walkmatesPulse)),
      walkmatesOuterPaint,
    );

    final double walkmatesBaseSize = walkmatesWidth * 0.35;
    final double walkmatesFontSize =
        walkmatesBaseSize + walkmatesPulse * (walkmatesBaseSize * 0.15);

    const String walkmatesLetter = 'N';
    const String walkmatesWord = 'CUP';

    final TextPainter walkmatesLetterPainter = TextPainter(
      text: TextSpan(
        text: walkmatesLetter,
        style: TextStyle(
          fontSize: walkmatesFontSize,
          fontWeight: FontWeight.w900,
          color: Colors.red.shade600,
          letterSpacing: 4,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.8),
              blurRadius: 22 + 18 * walkmatesPulse,
              offset: const Offset(0, 0),
            ),
            Shadow(
              color: Colors.black.withOpacity(0.8),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: walkmatesWidth);

    final double walkmatesLetterX =
        (walkmatesWidth - walkmatesLetterPainter.width) / 2;
    final double walkmatesLetterY =
        (walkmatesHeight - walkmatesLetterPainter.height) / 2;

    final Offset walkmatesLetterOffset =
    Offset(walkmatesLetterX, walkmatesLetterY);

    final Rect walkmatesLetterRect = Rect.fromCenter(
      center: Offset(walkmatesWidth / 2, walkmatesHeight / 2),
      width: walkmatesLetterPainter.width * 1.4,
      height: walkmatesLetterPainter.height * 1.6,
    );

    final Paint walkmatesGlowPaint = Paint()
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        28 + 24 * walkmatesPulse,
      )
      ..color = Colors.red.withOpacity(0.7 + 0.2 * walkmatesPulse);

    walkmatesCanvas.saveLayer(walkmatesLetterRect, walkmatesGlowPaint);
    walkmatesLetterPainter.paint(walkmatesCanvas, walkmatesLetterOffset);
    walkmatesCanvas.restore();

    walkmatesLetterPainter.paint(walkmatesCanvas, walkmatesLetterOffset);

    final double walkmatesCupFontSize = walkmatesWidth * 0.11;

    final TextPainter walkmatesCupPainterReal = TextPainter(
      text: TextSpan(
        text: walkmatesWord,
        style: TextStyle(
          fontSize: walkmatesCupFontSize,
          fontWeight: FontWeight.w600,
          color: Colors.red.shade100.withOpacity(0.95),
          letterSpacing: 5,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.7),
              blurRadius: 12 + 10 * walkmatesPulse,
              offset: const Offset(0, 0),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: walkmatesWidth);

    final double walkmatesCupX =
        (walkmatesWidth - walkmatesCupPainterReal.width) / 2;
    final double walkmatesCupY =
        walkmatesLetterY + walkmatesLetterPainter.height + walkmatesHeight * 0.03;

    final Offset walkmatesCupOffset = Offset(walkmatesCupX, walkmatesCupY);
    walkmatesCupPainterReal.paint(walkmatesCanvas, walkmatesCupOffset);
  }

  @override
  bool shouldRepaint(covariant WalkmatesLoaderPainter walkmatesOldDelegate) =>
      walkmatesOldDelegate.walkmatesPhase != walkmatesPhase;
}

// ============================================================================
// Статистика (walkmatesFinalUrl / walkmatesPostStat) — строки не меняем
// ============================================================================

Future<String> walkmatesFinalUrl(
    String walkmatesStartUrl, {
      int walkmatesMaxHops = 10,
    }) async {
  final HttpClient walkmatesClient = HttpClient();

  try {
    Uri walkmatesCurrentUri = Uri.parse(walkmatesStartUrl);

    for (int walkmatesI = 0; walkmatesI < walkmatesMaxHops; walkmatesI++) {
      final HttpClientRequest walkmatesRequest =
      await walkmatesClient.getUrl(walkmatesCurrentUri);
      walkmatesRequest.followRedirects = false;
      final HttpClientResponse walkmatesResponse =
      await walkmatesRequest.close();

      if (walkmatesResponse.isRedirect) {
        final String? walkmatesLoc =
        walkmatesResponse.headers.value(HttpHeaders.locationHeader);
        if (walkmatesLoc == null || walkmatesLoc.isEmpty) break;

        final Uri walkmatesNextUri = Uri.parse(walkmatesLoc);
        walkmatesCurrentUri = walkmatesNextUri.hasScheme
            ? walkmatesNextUri
            : walkmatesCurrentUri.resolveUri(walkmatesNextUri);
        continue;
      }

      return walkmatesCurrentUri.toString();
    }

    return walkmatesCurrentUri.toString();
  } catch (walkmatesError) {
    debugPrint('wheelFinalUrl error: $walkmatesError');
    return walkmatesStartUrl;
  } finally {
    walkmatesClient.close(force: true);
  }
}

Future<void> walkmatesPostStat({
  required String walkmatesEvent,
  required int walkmatesTimeStart,
  required String walkmatesUrl,
  required int walkmatesTimeFinish,
  required String walkmatesAppSid,
  int? walkmatesFirstPageTs,
}) async {
  try {
    final String walkmatesResolvedUrl = await walkmatesFinalUrl(walkmatesUrl);
    final Map<String, dynamic> walkmatesPayload = <String, dynamic>{
      'event': walkmatesEvent,
      'timestart': walkmatesTimeStart,
      'timefinsh': walkmatesTimeFinish,
      'url': walkmatesResolvedUrl,
      'appleID': '6755681349',
      'open_count': '$walkmatesAppSid/$walkmatesTimeStart',
    };

    debugPrint('wheelStat $walkmatesPayload');

    final http.Response walkmatesResp = await http.post(
      Uri.parse('$walkmatesStatEndpoint/$walkmatesAppSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(walkmatesPayload),
    );

    debugPrint('wheelStat resp=${walkmatesResp.statusCode} body=${walkmatesResp.body}');
  } catch (walkmatesError) {
    debugPrint('wheelPostStat error: $walkmatesError');
  }
}

// ============================================================================
// WebView-экран: WalkmatesTableView (бывший DressRetroTableView / NcupTableView)
// SafeArea + SafeArea color + localStorage подхватываются из SharedPreferences
// ============================================================================

class WalkmatesTableView extends StatefulWidget with WidgetsBindingObserver {
  String walkmatesStartingUrl;
  WalkmatesTableView(this.walkmatesStartingUrl, {super.key});

  @override
  State<WalkmatesTableView> createState() =>
      _WalkmatesTableViewState(walkmatesStartingUrl);
}

class _WalkmatesTableViewState extends State<WalkmatesTableView>
    with WidgetsBindingObserver {
  _WalkmatesTableViewState(this.walkmatesCurrentUrl);

  final WalkmatesVault walkmatesVaultInstance = WalkmatesVault();

  late InAppWebViewController walkmatesWebViewController;
  String? walkmatesPushToken;
  final WalkmatesDeviceProfile walkmatesDeviceProfileInstance =
  WalkmatesDeviceProfile();
  final WalkmatesSpy walkmatesSpyInstance = WalkmatesSpy();

  bool walkmatesOverlayBusy = false;
  String walkmatesCurrentUrl;
  DateTime? walkmatesLastPausedAt;

  bool walkmatesLoadedOnceSent = false;
  int? walkmatesFirstPageTimestamp;
  int walkmatesStartLoadTimestamp = 0;

  // --------- Социальные / внешние хосты / схемы ---------

  final Set<String> walkmatesExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'bnl.com',
    'www.bnl.com',
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'instagram.com',
    'www.instagram.com',
    'twitter.com',
    'www.twitter.com',
    'x.com',
    'www.x.com',
  };

  final Set<String> walkmatesExternalSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'bnl',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
  };

  final Set<String> walkmatesSpecialSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'viber',
    'skype',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
    'bnl',
  };

  // --------- UserAgent + SafeArea ---------

  String? _baseUserAgent;
  String _currentUserAgent = '';
  String? _serverUserAgent;
  bool _isInGoogleAuth = false;

  bool _safeAreaEnabled = false;
  Color _safeAreaBackgroundColor = Colors.black;

  // --------- POPUP (window.open) ---------

  InAppWebViewController? _popupWebViewController;
  bool _isPopupVisible = false;
  String? _popupUrl;
  CreateWindowAction? _popupCreateAction;
  bool _popupCanGoBack = false;
  String? _popupCurrentUrl;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    FirebaseMessaging.onBackgroundMessage(walkmatesFcmBackgroundHandler);

    walkmatesFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;

    // 1) SafeArea state (enabled + color) подхватываем из SharedPreferences
    _loadSafeAreaFromPrefs();

    // 2) Push
    walkmatesInitPushAndGetToken();

    // 3) Профиль устройства -> localStorage + SharedPreferences (app_data)
    walkmatesDeviceProfileInstance.walkmatesInitialize().then((_) async {
      if (!mounted) return;
      await _updateLocalStorage();
    });

    // 4) FCM + AppsFlyer
    walkmatesWireForegroundPushHandlers();
    walkmatesBindPlatformNotificationTap();
    walkmatesSpyInstance.walkmatesStart(walkmatesOnUpdate: () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState walkmatesState) {
    if (walkmatesState == AppLifecycleState.paused) {
      walkmatesLastPausedAt = DateTime.now();
    }
    if (walkmatesState == AppLifecycleState.resumed) {
      if (Platform.isIOS && walkmatesLastPausedAt != null) {
        final DateTime walkmatesNow = DateTime.now();
        final Duration walkmatesDrift =
        walkmatesNow.difference(walkmatesLastPausedAt!);
        if (walkmatesDrift > const Duration(minutes: 25)) {
          walkmatesForceReloadToLobby();
        }
      }
      walkmatesLastPausedAt = null;
    }
  }

  void walkmatesForceReloadToLobby() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration walkmatesDuration) {
      if (!mounted) return;
      // здесь можно вернуть в MafiaHarbor/CaptainHarbor/BillHarbor при необходимости
    });
  }

  // --------------------------------------------------------------------------
  // Push / FCM
  // --------------------------------------------------------------------------

  void walkmatesWireForegroundPushHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage walkmatesMsg) {
      if (walkmatesMsg.data['uri'] != null) {
        walkmatesNavigateTo(walkmatesMsg.data['uri'].toString());
      } else {
        walkmatesReturnToCurrentUrl();
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage walkmatesMsg) {
      if (walkmatesMsg.data['uri'] != null) {
        walkmatesNavigateTo(walkmatesMsg.data['uri'].toString());
      } else {
        walkmatesReturnToCurrentUrl();
      }
    });
  }

  void walkmatesNavigateTo(String walkmatesNewUrl) async {
    await walkmatesWebViewController.loadUrl(
      urlRequest: URLRequest(url: WebUri(walkmatesNewUrl)),
    );
  }

  void walkmatesReturnToCurrentUrl() async {
    Future<void>.delayed(const Duration(seconds: 3), () {
      walkmatesWebViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(walkmatesCurrentUrl)),
      );
    });
  }

  Future<void> walkmatesInitPushAndGetToken() async {
    final FirebaseMessaging walkmatesFm = FirebaseMessaging.instance;
    await walkmatesFm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    walkmatesPushToken = await walkmatesFm.getToken();
  }

  // --------------------------------------------------------------------------
  // Привязка канала: тап по уведомлению из native
  // --------------------------------------------------------------------------

  void walkmatesBindPlatformNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall walkmatesCall) async {
      if (walkmatesCall.method == "onNotificationTap") {
        final Map<String, dynamic> walkmatesPayload =
        Map<String, dynamic>.from(walkmatesCall.arguments);
        debugPrint("URI from platform tap: ${walkmatesPayload['uri']}");
        final String? walkmatesUriString = walkmatesPayload["uri"]?.toString();
        if (walkmatesUriString != null && !walkmatesUriString.contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext walkmatesContext) =>
                  WalkmatesTableView(walkmatesUriString),
            ),
                (Route<dynamic> walkmatesRoute) => false,
          );
        }
      }
    });
  }

  // --------------------------------------------------------------------------
  // localStorage + SharedPreferences: профиль устройства
  // --------------------------------------------------------------------------

  /// Обновляем app_data в localStorage И синхронно сохраняем JSON в SharedPreferences
  Future<void> _updateLocalStorage() async {
    try {
      final Map<String, dynamic> data =
      walkmatesDeviceProfileInstance.walkmatesAsMap(
        walkmatesFcmToken: walkmatesPushToken,
      );

      final String json = jsonEncode(data);

      // 1) В localStorage WebView
      await walkmatesWebViewController.evaluateJavascript(
        source: "localStorage.setItem('app_data', JSON.stringify($json));",
      );

      // 2) В SharedPreferences (чтобы при следующем запуске можно было восстановить)
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_data', json);

      walkmatesVaultInstance.walkmatesLoggerInstance.walkmatesLogInfo(
          'app_data saved to localStorage & SharedPreferences: $json');
    } catch (e, st) {
      walkmatesVaultInstance.walkmatesLoggerInstance
          .walkmatesLogError('updateLocalStorage error: $e\n$st');
    }
  }

  /// Восстанавливаем app_data из SharedPreferences обратно в localStorage
  Future<void> _restoreAppDataFromPrefsToLocalStorage() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? savedJson = prefs.getString('app_data');
      if (savedJson == null || savedJson.isEmpty) {
        return;
      }

      final String js =
          "localStorage.setItem('app_data', JSON.stringify($savedJson));";

      await walkmatesWebViewController.evaluateJavascript(source: js);

      walkmatesVaultInstance.walkmatesLoggerInstance.walkmatesLogInfo(
          'app_data restored from SharedPreferences to localStorage: $savedJson');
    } catch (e, st) {
      walkmatesVaultInstance.walkmatesLoggerInstance.walkmatesLogError(
          '_restoreAppDataFromPrefsToLocalStorage error: $e\n$st');
    }
  }

  // --------------------------------------------------------------------------
  // UserAgent / SafeArea helpers
  // --------------------------------------------------------------------------

  bool _isGoogleUrl(Uri uri) {
    final String full = uri.toString().toLowerCase();
    return full.contains('google');
  }

  Future<void> _applyUserAgent({String? fullua, String? uatail}) async {
    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      try {
        final ua = await walkmatesWebViewController.evaluateJavascript(
          source: "navigator.userAgent",
        );
        if (ua is String && ua.trim().isNotEmpty) {
          _baseUserAgent = ua.trim();
          _currentUserAgent = _baseUserAgent!;
          walkmatesDeviceProfileInstance.walkmatesBaseUserAgent = _baseUserAgent;
          walkmatesVaultInstance.walkmatesLoggerInstance
              .walkmatesLogInfo('Base User-Agent detected: $_baseUserAgent');
        }
      } catch (e) {
        walkmatesVaultInstance.walkmatesLoggerInstance
            .walkmatesLogWarn('Failed to get base userAgent from JS: $e');
      }
    }

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      walkmatesVaultInstance.walkmatesLoggerInstance
          .walkmatesLogWarn('Base User-Agent is null, skip UA update');
      return;
    }

    String newUa;
    if (fullua != null && fullua.trim().isNotEmpty) {
      newUa = fullua.trim();
    } else if (uatail != null && uatail.trim().isNotEmpty) {
      newUa = "${_baseUserAgent!}/${uatail.trim()}";
    } else {
      newUa = _baseUserAgent!;
    }

    _serverUserAgent = newUa;
    walkmatesVaultInstance.walkmatesLoggerInstance
        .walkmatesLogInfo('Server UA calculated: $_serverUserAgent');
  }

  Future<void> _updateUserAgentFromServerPayload(
      Map<dynamic, dynamic> root) async {
    String? fullua;
    String? uatail;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['fullua'] != null &&
          content['fullua'].toString().trim().isNotEmpty) {
        fullua = content['fullua'].toString().trim();
      }
      if (content['uatail'] != null &&
          content['uatail'].toString().trim().isNotEmpty) {
        uatail = content['uatail'].toString().trim();
      }
    }

    if (fullua == null &&
        root['fullua'] != null &&
        root['fullua'].toString().trim().isNotEmpty) {
      fullua = root['fullua'].toString().trim();
    }
    if (uatail == null &&
        root['uatail'] != null &&
        root['uatail'].toString().trim().isNotEmpty) {
      uatail = root['uatail'].toString().trim();
    }

    if (uatail == null) {
      final dynamic adata = root['adata'];
      if (adata is Map &&
          adata['uatail'] != null &&
          adata['uatail'].toString().trim().isNotEmpty) {
        uatail = adata['uatail'].toString().trim();
      }
    }

    await _applyUserAgent(fullua: fullua, uatail: uatail);
  }

  Future<void> _applyNormalUserAgentIfNeeded() async {
    if (_isInGoogleAuth) {
      walkmatesVaultInstance.walkmatesLoggerInstance.walkmatesLogInfo(
          'Skip normal UA apply because we are in Google auth');
      return;
    }

    final String targetUa = _serverUserAgent ?? _baseUserAgent ?? 'random';

    if (targetUa == _currentUserAgent) return;

    try {
      await walkmatesWebViewController.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      debugPrint('[UA] NORMAL WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      walkmatesVaultInstance.walkmatesLoggerInstance
          .walkmatesLogError('Error while setting UA "$targetUa": $e');
    }
  }

  Future<void> _addRandomToUserAgentForGoogle() async {
    const String targetUa = 'random';
    if (_currentUserAgent == targetUa && _isInGoogleAuth) return;

    try {
      await walkmatesWebViewController.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      _isInGoogleAuth = true;
      debugPrint('[UA] GOOGLE RANDOM USER AGENT: $_currentUserAgent');
    } catch (e) {
      walkmatesVaultInstance.walkmatesLoggerInstance
          .walkmatesLogError('Error setting RANDOM UA for Google: $e');
    }
  }

  Future<void> _restoreUserAgentAfterGoogleIfNeeded() async {
    if (!_isInGoogleAuth) return;
    _isInGoogleAuth = false;
    await _applyNormalUserAgentIfNeeded();
  }

  // Хелпер для парсинга HEX‑цвета (общий для SafeArea и prefs)
  Color _parseHexColor(String hex, {Color fallback = const Color(0xFF1A1A22)}) {
    String value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) value = 'FF$value';
    final intColor = int.tryParse(value, radix: 16);
    if (intColor == null) return fallback;
    return Color(intColor);
  }

  // НОВОЕ: загрузка SafeArea из SharedPreferences при старте
  Future<void> _loadSafeAreaFromPrefs() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final bool enabled = prefs.getBool(walkmatesSafeAreaEnabledKey) ?? false;
      final String colorHex = prefs.getString(walkmatesSafeAreaColorKey) ?? '';

      Color bg = Colors.black;
      if (enabled) {
        if (colorHex.isNotEmpty) {
          bg = _parseHexColor(colorHex, fallback: const Color(0xFF1A1A22));
        } else {
          bg = const Color(0xFF1A1A22);
        }
      }

      if (!mounted) return;

      setState(() {
        _safeAreaEnabled = enabled;
        _safeAreaBackgroundColor = bg;
        walkmatesDeviceProfileInstance.walkmatesSafeAreaEnabled = enabled;
        walkmatesDeviceProfileInstance.walkmatesSafeAreaColor =
        enabled ? (colorHex.isNotEmpty ? colorHex : '#1A1A22') : '';
      });

      walkmatesVaultInstance.walkmatesLoggerInstance.walkmatesLogInfo(
          'SafeArea loaded from prefs: enabled=$enabled, color="$colorHex"');
    } catch (e, st) {
      walkmatesVaultInstance.walkmatesLoggerInstance
          .walkmatesLogError('_loadSafeAreaFromPrefs error: $e\n$st');
    }
  }

  void _updateSafeAreaFromServerPayload(Map<dynamic, dynamic> root) {
    bool? safearea;
    String? bgLightHex;
    String? bgDarkHex;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['safearea'] != null) {
        final dynamic raw = content['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (content['safearea_color'] != null &&
          content['safearea_color'].toString().trim().isNotEmpty) {
        bgLightHex = content['safearea_color'].toString().trim();
        bgDarkHex = bgLightHex;
      }
    }

    final dynamic adata = root['adata'];
    if (adata is Map) {
      if (safearea == null && adata['safearea'] != null) {
        final dynamic raw = adata['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (adata['bgsareaw'] != null &&
          adata['bgsareaw'].toString().trim().isNotEmpty) {
        bgLightHex = adata['bgsareaw'].toString().trim();
      }
      if (adata['bgsareab'] != null &&
          adata['bgsareab'].toString().trim().isNotEmpty) {
        bgDarkHex = adata['bgsareab'].toString().trim();
      }
    }

    if (safearea == null && root['safearea'] != null) {
      final dynamic raw = root['safearea'];
      if (raw is bool) {
        safearea = raw;
      } else if (raw is String) {
        final String v = raw.toLowerCase().trim();
        if (v == 'true' || v == '1' || v == 'yes') safearea = true;
        if (v == 'false' || v == '0' || v == 'no') safearea = false;
      } else if (raw is num) {
        safearea = raw != 0;
      }
    }

    if (safearea == null) return;

    final Brightness platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    String? chosenHex;
    if (platformBrightness == Brightness.light) {
      chosenHex = bgLightHex ?? bgDarkHex;
    } else {
      chosenHex = bgDarkHex ?? bgLightHex;
    }

    Color background = safearea ? const Color(0xFF1A1A22) : Colors.black;

    if (safearea && chosenHex != null && chosenHex.isNotEmpty) {
      background = _parseHexColor(chosenHex, fallback: const Color(0xFF1A1A22));
    }

    setState(() {
      _safeAreaEnabled = safearea!;
      _safeAreaBackgroundColor = background;
      walkmatesDeviceProfileInstance.walkmatesSafeAreaEnabled = safearea;
      walkmatesDeviceProfileInstance.walkmatesSafeAreaColor =
      safearea ? (chosenHex ?? '#1A1A22') : '';
    });

    // НОВОЕ: сохраняем SafeArea в SharedPreferences при каждом обновлении
    () async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setBool(walkmatesSafeAreaEnabledKey, safearea!);
        await prefs.setString(
          walkmatesSafeAreaColorKey,
          walkmatesDeviceProfileInstance.walkmatesSafeAreaColor ?? '',
        );
        walkmatesVaultInstance.walkmatesLoggerInstance.walkmatesLogInfo(
          'SafeArea saved to prefs: enabled=$safearea, color="${walkmatesDeviceProfileInstance.walkmatesSafeAreaColor}"',
        );
      } catch (e, st) {
        walkmatesVaultInstance.walkmatesLoggerInstance
            .walkmatesLogError('Error saving SafeArea to prefs: $e\n$st');
      }
    }();
  }

  // --------------------------------------------------------------------------
  // POPUP helpers
  // --------------------------------------------------------------------------

  InAppWebViewSettings _popupSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      transparentBackground: false,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  void _openPopup(CreateWindowAction req, {String? urlString}) {
    setState(() {
      _popupCreateAction = req;
      _popupUrl =
      (urlString != null && urlString.isNotEmpty) ? urlString : req.request.url?.toString();
      _popupCurrentUrl = _popupUrl;
      _isPopupVisible = true;
      _popupCanGoBack = false;
    });
  }

  void _closePopup() {
    setState(() {
      _isPopupVisible = false;
      _popupUrl = null;
      _popupCurrentUrl = null;
      _popupCreateAction = null;
      _popupCanGoBack = false;
      _popupWebViewController = null;
    });
  }

  Future<void> _refreshPopupCanGoBack() async {
    final InAppWebViewController? c = _popupWebViewController;
    if (c == null) {
      if (_popupCanGoBack && mounted) {
        setState(() {
          _popupCanGoBack = false;
        });
      }
      return;
    }
    try {
      final bool can = await c.canGoBack();
      if (!mounted) return;
      if (can != _popupCanGoBack) {
        setState(() {
          _popupCanGoBack = can;
        });
      }
    } catch (_) {}
  }

  Future<void> _handlePopupBackPressed() async {
    final InAppWebViewController? c = _popupWebViewController;
    if (c == null) {
      _closePopup();
      return;
    }
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        Future<void>.delayed(const Duration(milliseconds: 200), () {
          _refreshPopupCanGoBack();
        });
      } else {
        _closePopup();
      }
    } catch (_) {
      _closePopup();
    }
  }

  Widget _buildPopupOverlay() {
    if (!_isPopupVisible || (_popupUrl == null && _popupCreateAction == null)) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Container(
                color: Colors.black,
                height: 48,
                child: Row(
                  children: [
                    if (_popupCanGoBack)
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: _handlePopupBackPressed,
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: _closePopup,
                      ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            Expanded(
              child: InAppWebView(
                windowId: _popupCreateAction?.windowId,
                initialUrlRequest:
                (_popupCreateAction?.windowId == null && _popupUrl != null)
                    ? URLRequest(url: WebUri(_popupUrl!))
                    : null,
                initialSettings: _popupSettings(),
                onWebViewCreated: (InAppWebViewController controller) async {
                  _popupWebViewController = controller;
                },
                onLoadStart: (controller, uri) async {
                  if (uri != null) {
                    setState(() {
                      _popupCurrentUrl = uri.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStop: (controller, uri) async {
                  if (uri != null) {
                    setState(() {
                      _popupCurrentUrl = uri.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                onUpdateVisitedHistory:
                    (controller, url, isReload) async {
                  if (url != null) {
                    setState(() {
                      _popupCurrentUrl = url.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                shouldOverrideUrlLoading: (
                    InAppWebViewController controller,
                    NavigationAction nav,
                    ) async {
                  final Uri? uri = nav.request.url;
                  if (uri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  final String scheme = uri.scheme.toLowerCase();

                  if (WalkmatesKit.walkmatesLooksLikeBareMail(uri)) {
                    final Uri mailto = WalkmatesKit.walkmatesToMailto(uri);
                    await WalkmatesLinker.walkmatesOpen(
                      WalkmatesKit.walkmatesGmailize(mailto),
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'mailto') {
                    await WalkmatesLinker.walkmatesOpen(
                      WalkmatesKit.walkmatesGmailize(uri),
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'tel') {
                    await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (walkmatesIsBankScheme(uri) ||
                      ((scheme == 'http' || scheme == 'https') &&
                          walkmatesIsBankDomain(uri))) {
                    await walkmatesOpenBank(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme != 'http' && scheme != 'https') {
                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onCloseWindow: (controller) {
                  _closePopup();
                },
                onDownloadStartRequest: (controller, req) async {
                  await WalkmatesLinker.walkmatesOpen(req.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    walkmatesBindPlatformNotificationTap();

    final bool walkmatesIsDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;

    final Color bgColor = _safeAreaEnabled
        ? _safeAreaBackgroundColor
        : (walkmatesIsDark ? Colors.black : Colors.white);

    final Widget webView = InAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        disableDefaultErrorPage: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        allowsPictureInPictureMediaPlayback: true,
        useOnDownloadStart: true,
        javaScriptCanOpenWindowsAutomatically: true,
        useShouldOverrideUrlLoading: true,
        supportMultipleWindows: true,
      ),
      initialUrlRequest: URLRequest(
        url: WebUri(walkmatesCurrentUrl),
      ),
      onWebViewCreated: (InAppWebViewController walkmatesController) async {
        walkmatesWebViewController = walkmatesController;

        // Инициализация UA
        try {
          final ua = await walkmatesController.evaluateJavascript(
            source: "navigator.userAgent",
          );
          if (ua is String && ua.trim().isNotEmpty) {
            _baseUserAgent = ua.trim();
            _currentUserAgent = _baseUserAgent!;
            walkmatesDeviceProfileInstance.walkmatesBaseUserAgent =
                _baseUserAgent;
            debugPrint('[UA] INITIAL: $_baseUserAgent');
          }
        } catch (e) {
          walkmatesVaultInstance.walkmatesLoggerInstance
              .walkmatesLogWarn('Failed to read navigator.userAgent: $e');
        }

        await _applyNormalUserAgentIfNeeded();

        // После создания WebView — актуализируем localStorage
        await _updateLocalStorage();

        // Через 6 секунд после открытия экрана — восстановление app_data из SharedPreferences
        Future<void>.delayed(const Duration(seconds: 6), () async {
          if (!mounted) return;
          await _restoreAppDataFromPrefsToLocalStorage();
        });

        walkmatesWebViewController.addJavaScriptHandler(
          handlerName: 'onServerResponse',
          callback: (List<dynamic> walkmatesArgs) {
            walkmatesVaultInstance.walkmatesLoggerInstance
                .walkmatesLogInfo("JS Args: $walkmatesArgs");

            try {
              dynamic first = walkmatesArgs.isNotEmpty ? walkmatesArgs[0] : null;

              if (first is List && first.isNotEmpty) {
                first = first.first;
              }

              if (first is Map) {
                final Map<dynamic, dynamic> root = first;

                // safearea + userAgent из сервера
                _updateSafeAreaFromServerPayload(root);
                _updateUserAgentFromServerPayload(root);
                _applyNormalUserAgentIfNeeded();

                // При каждом ответе сервера можно обновлять localStorage
                _updateLocalStorage();
              }

              try {
                return walkmatesArgs
                    .reduce((dynamic walkmatesV, dynamic walkmatesE) => walkmatesV + walkmatesE);
              } catch (_) {
                return walkmatesArgs.toString();
              }
            } catch (e) {
              return walkmatesArgs.toString();
            }
          },
        );
      },
      onLoadStart: (
          InAppWebViewController walkmatesController,
          Uri? walkmatesUri,
          ) async {
        walkmatesStartLoadTimestamp = DateTime.now().millisecondsSinceEpoch;

        if (walkmatesUri != null) {
          if (_isGoogleUrl(walkmatesUri)) {
            await _addRandomToUserAgentForGoogle();
          } else {
            await _restoreUserAgentAfterGoogleIfNeeded();
            await _applyNormalUserAgentIfNeeded();
          }

          if (WalkmatesKit.walkmatesLooksLikeBareMail(walkmatesUri)) {
            try {
              await walkmatesController.stopLoading();
            } catch (_) {}
            final Uri walkmatesMailto =
            WalkmatesKit.walkmatesToMailto(walkmatesUri);
            await WalkmatesLinker.walkmatesOpen(
              WalkmatesKit.walkmatesGmailize(walkmatesMailto),
            );
            return;
          }

          // банки
          if (walkmatesIsBankScheme(walkmatesUri) ||
              ((walkmatesUri.scheme == 'http' || walkmatesUri.scheme == 'https') &&
                  walkmatesIsBankDomain(walkmatesUri))) {
            try {
              await walkmatesController.stopLoading();
            } catch (_) {}
            await walkmatesOpenBank(walkmatesUri);
            return;
          }

          final String walkmatesScheme = walkmatesUri.scheme.toLowerCase();
          if (walkmatesScheme != 'http' && walkmatesScheme != 'https') {
            try {
              await walkmatesController.stopLoading();
            } catch (_) {}
          }
        }
      },
      onLoadStop: (
          InAppWebViewController walkmatesController,
          Uri? walkmatesUri,
          ) async {
        await walkmatesController.evaluateJavascript(
          source: "console.log('Hello from Roulette JS!');",
        );

        setState(() {
          walkmatesCurrentUrl = walkmatesUri?.toString() ?? walkmatesCurrentUrl;
        });

        await _restoreUserAgentAfterGoogleIfNeeded();
        await _applyNormalUserAgentIfNeeded();

        // После полной загрузки страницы обновляем localStorage
        await _updateLocalStorage();

        // И сразу тянем app_data из SharedPreferences в localStorage
        await _restoreAppDataFromPrefsToLocalStorage();

        Future<void>.delayed(const Duration(seconds: 20), () {
          walkmatesSendLoadedOnce();
        });
      },
      shouldOverrideUrlLoading: (
          InAppWebViewController walkmatesController,
          NavigationAction walkmatesNav,
          ) async {
        final Uri? walkmatesUri = walkmatesNav.request.url;
        if (walkmatesUri == null) {
          return NavigationActionPolicy.ALLOW;
        }

        if (_isGoogleUrl(walkmatesUri)) {
          await _addRandomToUserAgentForGoogle();
        } else {
          await _restoreUserAgentAfterGoogleIfNeeded();
          await _applyNormalUserAgentIfNeeded();
        }

        if (WalkmatesKit.walkmatesLooksLikeBareMail(walkmatesUri)) {
          final Uri walkmatesMailto =
          WalkmatesKit.walkmatesToMailto(walkmatesUri);
          await WalkmatesLinker.walkmatesOpen(
            WalkmatesKit.walkmatesGmailize(walkmatesMailto),
          );
          return NavigationActionPolicy.CANCEL;
        }

        final String walkmatesScheme = walkmatesUri.scheme.toLowerCase();

        if (walkmatesScheme == 'mailto') {
          await WalkmatesLinker.walkmatesOpen(
            WalkmatesKit.walkmatesGmailize(walkmatesUri),
          );
          return NavigationActionPolicy.CANCEL;
        }

        if (walkmatesIsBankScheme(walkmatesUri) ||
            ((walkmatesScheme == 'http' || walkmatesScheme == 'https') &&
                walkmatesIsBankDomain(walkmatesUri))) {
          await walkmatesOpenBank(walkmatesUri);
          return NavigationActionPolicy.CANCEL;
        }

        if (walkmatesScheme == 'tel') {
          await launchUrl(
            walkmatesUri,
            mode: LaunchMode.externalApplication,
          );
          return NavigationActionPolicy.CANCEL;
        }

        final String walkmatesHost = walkmatesUri.host.toLowerCase();
        final bool walkmatesIsSocial = walkmatesHost.endsWith('facebook.com') ||
            walkmatesHost.endsWith('instagram.com') ||
            walkmatesHost.endsWith('twitter.com') ||
            walkmatesHost.endsWith('x.com');

        if (walkmatesIsSocial) {
          await WalkmatesLinker.walkmatesOpen(walkmatesUri);
          return NavigationActionPolicy.CANCEL;
        }

        if (walkmatesIsExternalDestination(walkmatesUri)) {
          final Uri walkmatesMapped = walkmatesMapExternalToHttp(walkmatesUri);
          await WalkmatesLinker.walkmatesOpen(walkmatesMapped);
          return NavigationActionPolicy.CANCEL;
        }

        if (walkmatesScheme != 'http' && walkmatesScheme != 'https') {
          return NavigationActionPolicy.CANCEL;
        }

        return NavigationActionPolicy.ALLOW;
      },
      onCreateWindow: (
          InAppWebViewController walkmatesController,
          CreateWindowAction walkmatesReq,
          ) async {
        final Uri? walkmatesUrl = walkmatesReq.request.url;
        if (walkmatesUrl == null) return false;

        if (_isGoogleUrl(walkmatesUrl)) {
          await _addRandomToUserAgentForGoogle();
        } else {
          await _restoreUserAgentAfterGoogleIfNeeded();
          await _applyNormalUserAgentIfNeeded();
        }

        if (WalkmatesKit.walkmatesLooksLikeBareMail(walkmatesUrl)) {
          final Uri walkmatesMail = WalkmatesKit.walkmatesToMailto(walkmatesUrl);
          await WalkmatesLinker.walkmatesOpen(
            WalkmatesKit.walkmatesGmailize(walkmatesMail),
          );
          return false;
        }

        final String walkmatesScheme = walkmatesUrl.scheme.toLowerCase();

        if (walkmatesScheme == 'mailto') {
          await WalkmatesLinker.walkmatesOpen(
            WalkmatesKit.walkmatesGmailize(walkmatesUrl),
          );
          return false;
        }

        if (walkmatesIsBankScheme(walkmatesUrl) ||
            ((walkmatesScheme == 'http' || walkmatesScheme == 'https') &&
                walkmatesIsBankDomain(walkmatesUrl))) {
          await walkmatesOpenBank(walkmatesUrl);
          return false;
        }

        if (walkmatesScheme == 'tel') {
          await launchUrl(
            walkmatesUrl,
            mode: LaunchMode.externalApplication,
          );
          return false;
        }

        final String walkmatesHost = walkmatesUrl.host.toLowerCase();
        final bool walkmatesIsSocial = walkmatesHost.endsWith('facebook.com') ||
            walkmatesHost.endsWith('instagram.com') ||
            walkmatesHost.endsWith('twitter.com') ||
            walkmatesHost.endsWith('x.com');

        if (walkmatesIsSocial) {
          await WalkmatesLinker.walkmatesOpen(walkmatesUrl);
          return false;
        }

        if (walkmatesIsExternalDestination(walkmatesUrl)) {
          final Uri walkmatesMapped = walkmatesMapExternalToHttp(walkmatesUrl);
          await WalkmatesLinker.walkmatesOpen(walkmatesMapped);
          return false;
        }

        // popup-логика: всё, что осталось http/https — открываем во всплывающем WebView
        if (walkmatesScheme == 'http' || walkmatesScheme == 'https') {
          _openPopup(walkmatesReq, urlString: walkmatesUrl.toString());
          return true; // говорим WebView, что создаём окно сами
        }

        return false;
      },
    );

    final Widget body = Stack(
      children: <Widget>[
        webView,
        if (walkmatesOverlayBusy)
          const Positioned.fill(
            child: ColoredBox(
              color: Colors.black87,
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
          ),
        _buildPopupOverlay(),
      ],
    );

    final Widget wrapped = _safeAreaEnabled ? SafeArea(child: body) : body;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: bgColor,
        body: wrapped,
      ),
    );
  }

  // ========================================================================
  // Внешние “столы” (протоколы/мессенджеры/соцсети)
  // ========================================================================

  bool walkmatesIsExternalDestination(Uri walkmatesUri) {
    final String walkmatesScheme = walkmatesUri.scheme.toLowerCase();
    if (walkmatesExternalSchemes.contains(walkmatesScheme)) {
      return true;
    }

    if (walkmatesScheme == 'http' || walkmatesScheme == 'https') {
      final String walkmatesHost = walkmatesUri.host.toLowerCase();
      if (walkmatesExternalHosts.contains(walkmatesHost)) {
        return true;
      }
      if (walkmatesHost.endsWith('t.me')) return true;
      if (walkmatesHost.endsWith('wa.me')) return true;
      if (walkmatesHost.endsWith('m.me')) return true;
      if (walkmatesHost.endsWith('signal.me')) return true;
      if (walkmatesHost.endsWith('facebook.com')) return true;
      if (walkmatesHost.endsWith('instagram.com')) return true;
      if (walkmatesHost.endsWith('twitter.com')) return true;
      if (walkmatesHost.endsWith('x.com')) return true;
    }

    return false;
  }

  Uri walkmatesMapExternalToHttp(Uri walkmatesUri) {
    final String walkmatesScheme = walkmatesUri.scheme.toLowerCase();

    if (walkmatesScheme == 'tg' || walkmatesScheme == 'telegram') {
      final Map<String, String> walkmatesQp = walkmatesUri.queryParameters;
      final String? walkmatesDomain = walkmatesQp['domain'];
      if (walkmatesDomain != null && walkmatesDomain.isNotEmpty) {
        return Uri.https('t.me', '/$walkmatesDomain', <String, String>{
          if (walkmatesQp['start'] != null) 'start': walkmatesQp['start']!,
        });
      }
      final String walkmatesPath =
      walkmatesUri.path.isNotEmpty ? walkmatesUri.path : '';
      return Uri.https(
        't.me',
        '/$walkmatesPath',
        walkmatesUri.queryParameters.isEmpty ? null : walkmatesUri.queryParameters,
      );
    }

    if (walkmatesScheme == 'whatsapp') {
      final Map<String, String> walkmatesQp = walkmatesUri.queryParameters;
      final String? walkmatesPhone = walkmatesQp['phone'];
      final String? walkmatesText = walkmatesQp['text'];
      if (walkmatesPhone != null && walkmatesPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${WalkmatesKit.walkmatesDigitsOnly(walkmatesPhone)}',
          <String, String>{
            if (walkmatesText != null && walkmatesText.isNotEmpty)
              'text': walkmatesText,
          },
        );
      }
      return Uri.https(
        'wa.me',
        '/',
        <String, String>{
          if (walkmatesText != null && walkmatesText.isNotEmpty)
            'text': walkmatesText,
        },
      );
    }

    if (walkmatesScheme == 'bnl') {
      final String walkmatesNewPath =
      walkmatesUri.path.isNotEmpty ? walkmatesUri.path : '';
      return Uri.https(
        'bnl.com',
        '/$walkmatesNewPath',
        walkmatesUri.queryParameters.isEmpty ? null : walkmatesUri.queryParameters,
      );
    }

    return walkmatesUri;
  }

  Future<void> walkmatesSendLoadedOnce() async {
    if (walkmatesLoadedOnceSent) {
      debugPrint('Wheel Loaded already sent, skip');
      return;
    }

    final int walkmatesNow = DateTime.now().millisecondsSinceEpoch;

    await walkmatesPostStat(
      walkmatesEvent: 'Loaded',
      walkmatesTimeStart: walkmatesStartLoadTimestamp,
      walkmatesTimeFinish: walkmatesNow,
      walkmatesUrl: walkmatesCurrentUrl,
      walkmatesAppSid: walkmatesSpyInstance.walkmatesAppsFlyerUid,
      walkmatesFirstPageTs: walkmatesFirstPageTimestamp,
    );

    walkmatesLoadedOnceSent = true;
  }
}