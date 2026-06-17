import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Platform, HttpHeaders, HttpClient, HttpClientRequest, HttpClientResponse;

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as appsflyer_core;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
    MethodChannel,
    SystemChrome,
    SystemUiOverlayStyle,
    MethodCall,
    VoidCallback;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:matewallks/pushWalk.dart';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;

import 'appwalk.dart';
import 'loaderwalk.dart';

// ============================================================================
// Константы
// ============================================================================

const String walkmatesLoadedOnceKey = 'loaded_once';
const String walkmatesStatEndpoint = 'https://datasrc.matewalk.club/stat';
const String walkmatesCachedFcmKey = 'cached_fcm';
const String walkmatesCachedDeepKey = 'cached_deep_push_uri';
const String walkmatesCachedPushDataKey = 'cached_push_data';
const String walkmatesLaunchNumberKey = 'launch_number';

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
// Лёгкие сервисы
// ============================================================================

class WalkmatesLoggerService {
  static final WalkmatesLoggerService sharedInstance =
  WalkmatesLoggerService._internalConstructor();

  WalkmatesLoggerService._internalConstructor();

  factory WalkmatesLoggerService() => sharedInstance;

  final Connectivity walkmatesConnectivity = Connectivity();

  void walkmatesLogInfo(Object message) => print('[I] $message');
  void walkmatesLogWarn(Object message) => print('[W] $message');
  void walkmatesLogError(Object message) => print('[E] $message');
}

class WalkmatesNetworkService {
  final WalkmatesLoggerService walkmatesLogger = WalkmatesLoggerService();

  Future<void> walkmatesPostJson(
      String url,
      Map<String, dynamic> data,
      ) async {
    try {
      await http.post(
        Uri.parse(url),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(data),
      );
    } catch (error) {
      walkmatesLogger.walkmatesLogError('postJson error: $error');
    }
  }
}

// ============================================================================
// Утилита: одновременное сохранение JSON в localStorage и SharedPreferences
// ============================================================================

Future<void> walkmatesSaveJsonToLocalStorageAndPrefs({
  required InAppWebViewController? controller,
  required String key,
  required Map<String, dynamic> data,
}) async {
  final String jsonString = jsonEncode(data);

  if (controller != null) {
    try {
      await controller.evaluateJavascript(
        source: "localStorage.setItem('$key', JSON.stringify($jsonString));",
      );
    } catch (e, st) {
      WalkmatesLoggerService()
          .walkmatesLogError('walkmatesSaveJsonToLocalStorageAndPrefs localStorage error: $e\n$st');
    }
  }

  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonString);
  } catch (e, st) {
    WalkmatesLoggerService()
        .walkmatesLogError('walkmatesSaveJsonToLocalStorageAndPrefs prefs error: $e\n$st');
  }
}

// ============================================================================
// Профиль устройства
// ============================================================================

class WalkmatesDeviceProfile {
  String? walkmatesDeviceId;
  String? walkmatesSessionId = '';
  String? walkmatesPlatformName;
  String? walkmatesOsVersion;
  String? walkmatesAppVersion;
  String? walkmatesLanguageCode;
  String? walkmatesTimezoneName;
  bool walkmatesPushEnabled = false;

  int launchNumber = 0;

  bool walkmatesSafeAreaEnabled = false;
  String? walkmatesSafeAreaColor;

  // по умолчанию false, чтобы хуки не ставились,
  // пока сервер явно не пришлёт fpscashier=true
  bool safecasher = false;

  String? walkmatesBaseUserAgent;

  Map<String, dynamic>? walkmatesLastPushData;

  Map<String, dynamic>? walkmatesSavels;

  Future<void> walkmatesInitialize() async {
    final DeviceInfoPlugin walkmatesDeviceInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo walkmatesAndroidInfo =
      await walkmatesDeviceInfoPlugin.androidInfo;
      walkmatesDeviceId = walkmatesAndroidInfo.id;
      walkmatesPlatformName = 'android';
      walkmatesOsVersion = walkmatesAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo walkmatesIosInfo =
      await walkmatesDeviceInfoPlugin.iosInfo;
      walkmatesDeviceId = walkmatesIosInfo.identifierForVendor;
      walkmatesPlatformName = 'ios';
      walkmatesOsVersion = walkmatesIosInfo.systemVersion;
    }

    final PackageInfo walkmatesPackageInfo =
    await PackageInfo.fromPlatform();
    walkmatesAppVersion = walkmatesPackageInfo.version;
    walkmatesLanguageCode = Platform.localeName.split('_').first;
    walkmatesTimezoneName = tz_zone.local.name;
    walkmatesSessionId = 'test-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> walkmatesToMap({String? fcmToken}) =>
      <String, dynamic>{
        'fcm_token': fcmToken ?? 'missing_token',
        'device_id': walkmatesDeviceId ?? 'missing_id',
        'app_name': 'matewalk',
        'instance_id': walkmatesSessionId ?? 'missing_session',
        'platform': walkmatesPlatformName ?? 'missing_system',
        'os_version': walkmatesOsVersion ?? 'missing_build',
        'app_version': '1.4.1' ?? 'missing_app',
        'language': walkmatesLanguageCode ?? 'en',
        'timezone': walkmatesTimezoneName ?? 'UTC',
        'push_enabled': walkmatesPushEnabled,
        'launchnumber': launchNumber,
        'safe_area_native': walkmatesSafeAreaEnabled,
        'useragent': walkmatesBaseUserAgent ?? 'unknown_useragent',
        'savels': walkmatesSavels ?? <String, dynamic>{},
        'fpscashier': safecasher,
      };
}

// ============================================================================
// AppsFlyer Spy
// ============================================================================

class WalkmatesAnalyticsSpyService {
  appsflyer_core.AppsFlyerOptions? walkmatesAppsFlyerOptions;
  appsflyer_core.AppsflyerSdk? walkmatesAppsFlyerSdk;

  String walkmatesAppsFlyerUid = '';
  String walkmatesAppsFlyerData = '';

  Map<String, dynamic>? walkmatesAppsFlyerOneLinkData;

  void walkmatesStartTracking({VoidCallback? onUpdate}) {
    final appsflyer_core.AppsFlyerOptions walkmatesConfig =
    appsflyer_core.AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6779198560',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    walkmatesAppsFlyerOptions = walkmatesConfig;
    walkmatesAppsFlyerSdk = appsflyer_core.AppsflyerSdk(walkmatesConfig);

    walkmatesAppsFlyerSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    walkmatesAppsFlyerSdk?.startSDK(
      onSuccess: () => WalkmatesLoggerService()
          .walkmatesLogInfo('RetroCarAnalyticsSpy started'),
      onError: (int code, String msg) => WalkmatesLoggerService()
          .walkmatesLogError('RetroCarAnalyticsSpy error $code: $msg'),
    );

    walkmatesAppsFlyerSdk?.onInstallConversionData((dynamic value) {
      walkmatesAppsFlyerData = value.toString();
      onUpdate?.call();
    });

    walkmatesAppsFlyerSdk?.getAppsFlyerUID().then((dynamic value) {
      walkmatesAppsFlyerUid = value.toString();
      onUpdate?.call();
    });
  }

  void walkmatesSetOneLinkData(Map<String, dynamic> data) {
    walkmatesAppsFlyerOneLinkData = data;
    WalkmatesLoggerService()
        .walkmatesLogInfo('WalkmatesAnalyticsSpyService: OneLink data updated: $data');
  }
}

// ============================================================================
// FCM фон
// ============================================================================

@pragma('vm:entry-point')
Future<void> walkmatesFcmBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  WalkmatesLoggerService().walkmatesLogInfo('bg-fcm: ${message.messageId}');
  WalkmatesLoggerService().walkmatesLogInfo('bg-data: ${message.data}');

  try {
    final SharedPreferences walkmatesPrefs =
        await SharedPreferences.getInstance();

    // Сохраняем весь payload пуша — восстановится при следующем запуске
    if (message.data.isNotEmpty) {
      await walkmatesPrefs.setString(
        walkmatesCachedPushDataKey,
        jsonEncode(message.data),
      );
    }

    // Сохраняем deep link
    final dynamic walkmatesLink = message.data['uri'];
    if (walkmatesLink != null) {
      await walkmatesPrefs.setString(
        walkmatesCachedDeepKey,
        walkmatesLink.toString(),
      );
    }
  } catch (e) {
    WalkmatesLoggerService().walkmatesLogError('bg-fcm save failed: $e');
  }
}

// ============================================================================
// FCM Bridge — токен
// ============================================================================

class WalkmatesFcmBridge {
  final WalkmatesLoggerService walkmatesLogger = WalkmatesLoggerService();

  static const MethodChannel _tokenChannel =
  MethodChannel('com.example.fcm/token');

  String? walkmatesToken;
  final List<void Function(String)> walkmatesTokenWaiters =
  <void Function(String)>[];

  String? get walkmatesFcmToken => walkmatesToken;

  Timer? _requestTimer;
  int _requestAttempts = 0;
  final int _maxAttempts = 10;

  WalkmatesFcmBridge() {
    _tokenChannel.setMethodCallHandler((MethodCall walkmatesCall) async {
      if (walkmatesCall.method == 'setToken') {
        final String walkmatesTokenString = walkmatesCall.arguments as String;
        walkmatesLogger.walkmatesLogInfo(
            'WalkmatesFcmBridge: got token from native channel = $walkmatesTokenString');
        if (walkmatesTokenString.isNotEmpty) {
          walkmatesSetToken(walkmatesTokenString);
        }
      }
    });

    walkmatesRestoreToken();
    _requestNativeToken();
    _startRequestTimer();
  }

  Future<void> _requestNativeToken() async {
    try {
      walkmatesLogger.walkmatesLogInfo(
          'WalkmatesFcmBridge: request native getToken()');
      final String? token =
      await _tokenChannel.invokeMethod<String>('getToken');
      if (token != null && token.isNotEmpty) {
        walkmatesLogger
            .walkmatesLogInfo('WalkmatesFcmBridge: native getToken() returns $token');
        walkmatesSetToken(token);
      } else {
        walkmatesLogger
            .walkmatesLogWarn('WalkmatesFcmBridge: native getToken() returned empty');
      }
    } catch (e) {
      walkmatesLogger.walkmatesLogWarn(
          'WalkmatesFcmBridge: getToken invoke error: $e');
    }
  }

  void _startRequestTimer() {
    _requestTimer?.cancel();
    _requestAttempts = 0;

    _requestTimer = Timer.periodic(const Duration(seconds: 5), (Timer t) async {
      if ((walkmatesToken ?? '').isNotEmpty) {
        walkmatesLogger.walkmatesLogInfo(
            'WalkmatesFcmBridge: token already set, stop request timer');
        t.cancel();
        return;
      }

      if (_requestAttempts >= _maxAttempts) {
        walkmatesLogger.walkmatesLogWarn(
            'WalkmatesFcmBridge: max getToken attempts reached, stop timer');
        t.cancel();
        return;
      }

      _requestAttempts++;
      walkmatesLogger.walkmatesLogInfo(
          'WalkmatesFcmBridge: retry getToken() attempt #$_requestAttempts');
      await _requestNativeToken();
    });
  }

  Future<void> walkmatesRestoreToken() async {
    try {
      final SharedPreferences walkmatesPrefs =
      await SharedPreferences.getInstance();
      final String? walkmatesCachedToken =
      walkmatesPrefs.getString(walkmatesCachedFcmKey);
      if (walkmatesCachedToken != null && walkmatesCachedToken.isNotEmpty) {
        walkmatesLogger.walkmatesLogInfo(
            'WalkmatesFcmBridge: restored cached token = $walkmatesCachedToken');
        walkmatesSetToken(walkmatesCachedToken, notify: false);
      }
    } catch (e) {
      walkmatesLogger.walkmatesLogError('walkmatesRestoreToken error: $e');
    }
  }

  Future<void> walkmatesPersistToken(String newToken) async {
    try {
      final SharedPreferences walkmatesPrefs =
      await SharedPreferences.getInstance();
      await walkmatesPrefs.setString(walkmatesCachedFcmKey, newToken);
    } catch (e) {
      walkmatesLogger.walkmatesLogError('walkmatesPersistToken error: $e');
    }
  }

  void walkmatesSetToken(
      String newToken, {
        bool notify = true,
      }) {
    walkmatesToken = newToken;
    walkmatesPersistToken(newToken);

    if (notify) {
      for (final void Function(String) walkmatesCallback
      in List<void Function(String)>.from(walkmatesTokenWaiters)) {
        try {
          walkmatesCallback(newToken);
        } catch (error) {
          walkmatesLogger.walkmatesLogWarn('fcm waiter error: $error');
        }
      }
      walkmatesTokenWaiters.clear();
    }
  }

  Future<void> walkmatesWaitForToken(
      Function(String token) walkmatesOnToken,
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

      walkmatesTokenWaiters.add(walkmatesOnToken);
    } catch (error) {
      walkmatesLogger.walkmatesLogError('walkmatesWaitForToken error: $error');
    }
  }

  void dispose() {
    _requestTimer?.cancel();
  }
}

// ============================================================================
// Splash / Hall
// ============================================================================

class WalkmatesHall extends StatefulWidget {
  const WalkmatesHall({Key? key}) : super(key: key);

  @override
  State<WalkmatesHall> createState() => _WalkmatesHallState();
}

class _WalkmatesHallState extends State<WalkmatesHall> {
  final WalkmatesFcmBridge walkmatesFcmBridgeInstance = WalkmatesFcmBridge();
  bool walkmatesNavigatedOnce = false;
  Timer? walkmatesFallbackTimer;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    walkmatesFcmBridgeInstance.walkmatesWaitForToken((String walkmatesToken) {
      walkmatesGoToHarbor(walkmatesToken);
    });

    walkmatesFallbackTimer = Timer(
      const Duration(seconds: 8),
          () => walkmatesGoToHarbor(''),
    );
  }

  void walkmatesGoToHarbor(String walkmatesSignal) {
    if (walkmatesNavigatedOnce) return;
    walkmatesNavigatedOnce = true;
    walkmatesFallbackTimer?.cancel();

    Navigator.pushReplacement(
      context,
      MaterialPageRoute<Widget>(
        builder: (BuildContext context) =>
            WalkmatesHarbor(walkmatesSignal: walkmatesSignal),
      ),
    );
  }

  @override
  void dispose() {
    walkmatesFallbackTimer?.cancel();
    walkmatesFcmBridgeInstance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: LoaderScreen(),
        ),
      ),
    );
  }
}

// ============================================================================
// ViewModel + Courier
// ============================================================================

class WalkmatesBosunViewModel {
  final WalkmatesDeviceProfile walkmatesDeviceProfileInstance;
  final WalkmatesAnalyticsSpyService walkmatesAnalyticsSpyInstance;

  WalkmatesBosunViewModel({
    required this.walkmatesDeviceProfileInstance,
    required this.walkmatesAnalyticsSpyInstance,
  });

  Map<String, dynamic> walkmatesDeviceMap(String? fcmToken) =>
      walkmatesDeviceProfileInstance.walkmatesToMap(fcmToken: fcmToken);

  Map<String, dynamic> walkmatesAppsFlyerPayload(
      String? token, {
        String? deepLink,
      }) {
    final Map<String, dynamic> onelinkData =
        walkmatesAnalyticsSpyInstance.walkmatesAppsFlyerOneLinkData ??
            <String, dynamic>{};

    return <String, dynamic>{
      'content': <String, dynamic>{
        'af_data': walkmatesAnalyticsSpyInstance.walkmatesAppsFlyerData,
        'af_id': walkmatesAnalyticsSpyInstance.walkmatesAppsFlyerUid,
        'fb_app_name': 'matewalk',
        'app_name': 'matewalk',
        'onelink': onelinkData,
        'bundle_identifier': 'com.matewall.walkmate.matewallks',
        'app_version': '1.4.1',
        'apple_id': '6779198560',
        'fcm_token': token ?? 'no_token',
        'device_id':
        walkmatesDeviceProfileInstance.walkmatesDeviceId ?? 'no_device',
        'instance_id':
        walkmatesDeviceProfileInstance.walkmatesSessionId ?? 'no_instance',
        'platform':
        walkmatesDeviceProfileInstance.walkmatesPlatformName ?? 'no_type',
        'os_version':
        walkmatesDeviceProfileInstance.walkmatesOsVersion ?? 'no_os',
        'language':
        walkmatesDeviceProfileInstance.walkmatesLanguageCode ?? 'en',
        'timezone':
        walkmatesDeviceProfileInstance.walkmatesTimezoneName ?? 'UTC',
        'push_enabled':
        walkmatesDeviceProfileInstance.walkmatesPushEnabled,
        'useruid': walkmatesAnalyticsSpyInstance.walkmatesAppsFlyerUid,
        'safearea':
        walkmatesDeviceProfileInstance.walkmatesSafeAreaEnabled,
        'safearea_color':
        walkmatesDeviceProfileInstance.walkmatesSafeAreaColor ?? '',
        'useragent':
        walkmatesDeviceProfileInstance.walkmatesBaseUserAgent ??
            'unknown_useragent',
        'push': walkmatesDeviceProfileInstance.walkmatesLastPushData ??
            <String, dynamic>{},
        'launchnumber': walkmatesDeviceProfileInstance.launchNumber,
        'deep': deepLink,
        'fpscashier': walkmatesDeviceProfileInstance.safecasher,
      },
    };
  }
}

class WalkmatesCourierService {
  final WalkmatesBosunViewModel walkmatesBosun;
  final InAppWebViewController? Function() walkmatesGetWebViewController;

  WalkmatesCourierService({
    required this.walkmatesBosun,
    required this.walkmatesGetWebViewController,
  });

  Future<InAppWebViewController?> _waitForController({
    Duration timeout = const Duration(seconds: 10),
    Duration interval = const Duration(milliseconds: 200),
  }) async {
    final WalkmatesLoggerService logger = WalkmatesLoggerService();
    final DateTime start = DateTime.now();

    while (DateTime.now().difference(start) < timeout) {
      final InAppWebViewController? c = walkmatesGetWebViewController();
      if (c != null) {
        return c;
      }
      await Future<void>.delayed(interval);
    }

    logger.walkmatesLogWarn(
        '_waitForController: timeout, controller is still null');
    return null;
  }

  Future<void> walkmatesPutDeviceToLocalStorage(String? token) async {
    final InAppWebViewController? walkmatesController =
    await _waitForController();
    if (walkmatesController == null) return;

    final Map<String, dynamic> walkmatesMap =
    walkmatesBosun.walkmatesDeviceMap(token);
    WalkmatesLoggerService()
        .walkmatesLogInfo("applocal (${jsonEncode(walkmatesMap)});");

    await walkmatesSaveJsonToLocalStorageAndPrefs(
      controller: walkmatesController,
      key: 'app_data',
      data: walkmatesMap,
    );
  }

  Future<void> walkmatesSendRawToPage(
      String? token, {
        String? deepLink,
      }) async {
    final InAppWebViewController? walkmatesController =
    await _waitForController();
    if (walkmatesController == null) return;

    final Map<String, dynamic> walkmatesPayload =
    walkmatesBosun.walkmatesAppsFlyerPayload(token, deepLink: deepLink);

    final String walkmatesJsonString = jsonEncode(walkmatesPayload);

    WalkmatesLoggerService()
        .walkmatesLogInfo('SendRawData: $walkmatesJsonString');

    final String jsSafeJson = jsonEncode(walkmatesJsonString);
    final String jsCode = 'sendRawData($jsSafeJson);';

    try {
      await walkmatesController.evaluateJavascript(source: jsCode);
    } catch (e, st) {
      WalkmatesLoggerService().walkmatesLogError(
          'walkmatesSendRawToPage evaluateJavascript error: $e\n$st');
    }
  }
}

// ============================================================================
// Статистика
// ============================================================================

Future<String> walkmatesResolveFinalUrl(
    String startUrl, {
      int maxHops = 10,
    }) async {
  final HttpClient walkmatesHttpClient = HttpClient();

  try {
    Uri walkmatesCurrentUri = Uri.parse(startUrl);

    for (int walkmatesIndex = 0; walkmatesIndex < maxHops; walkmatesIndex++) {
      final HttpClientRequest walkmatesRequest =
      await walkmatesHttpClient.getUrl(walkmatesCurrentUri);
      walkmatesRequest.followRedirects = false;
      final HttpClientResponse walkmatesResponse =
      await walkmatesRequest.close();

      if (walkmatesResponse.isRedirect) {
        final String? walkmatesLocationHeader =
        walkmatesResponse.headers.value(HttpHeaders.locationHeader);
        if (walkmatesLocationHeader == null ||
            walkmatesLocationHeader.isEmpty) {
          break;
        }

        final Uri walkmatesNextUri = Uri.parse(walkmatesLocationHeader);
        walkmatesCurrentUri = walkmatesNextUri.hasScheme
            ? walkmatesNextUri
            : walkmatesCurrentUri.resolveUri(walkmatesNextUri);
        continue;
      }

      return walkmatesCurrentUri.toString();
    }

    return walkmatesCurrentUri.toString();
  } catch (error) {
    print('goldenLuxuryResolveFinalUrl error: $error');
    return startUrl;
  } finally {
    walkmatesHttpClient.close(force: true);
  }
}

Future<void> walkmatesPostStat({
  required String event,
  required int timeStart,
  required String url,
  required int timeFinish,
  required String appSid,
  int? firstPageLoadTs,
}) async {
  try {
    final String walkmatesResolvedUrl = await walkmatesResolveFinalUrl(url);

    final Map<String, dynamic> walkmatesPayload = <String, dynamic>{
      'event': event,
      'timestart': timeStart,
      'timefinsh': timeFinish,
      'url': walkmatesResolvedUrl,
      'appleID': '6758657360',
      'open_count': '$appSid/$timeStart',
    };

    print('goldenLuxuryStat $walkmatesPayload');

    final http.Response walkmatesResponse = await http.post(
      Uri.parse('$walkmatesStatEndpoint/$appSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(walkmatesPayload),
    );

    print(
        'goldenLuxuryStat resp=${walkmatesResponse.statusCode} body=${walkmatesResponse.body}');
  } catch (error) {
    print('goldenLuxuryPostStat error: $error');
  }
}

// ============================================================================
// Банковские утилиты
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
    print('walkmatesOpenBank error: $e; url=$uri');
  }
  return false;
}

// ============================================================================
// Главный WebView — Harbor
// ============================================================================

class WalkmatesHarbor extends StatefulWidget {
  final String? walkmatesSignal;

  const WalkmatesHarbor({super.key, required this.walkmatesSignal});

  @override
  State<WalkmatesHarbor> createState() => _WalkmatesHarborState();
}

class _WalkmatesHarborState extends State<WalkmatesHarbor>
    with WidgetsBindingObserver {
  InAppWebViewController? walkmatesWebViewController;

  InAppWebViewController? walkmatesPopupWebViewController;
  bool _isPopupVisible = false;
  String? _popupUrl;
  CreateWindowAction? _popupCreateAction;

  bool _popupCanGoBack = false;
  String? _popupCurrentUrl;

  bool _isOpeningExternalNewTab = false;
  final Set<String> _handledNewTabUrls = <String>{};

  Timer? _parentInstallTimer;
  Timer? _popupInstallTimer;

  final String walkmatesHomeUrl =
      'https://datasrc.matewalk.club/';

  int walkmatesWebViewKeyCounter = 0;
  DateTime? walkmatesSleepAt;
  bool walkmatesVeilVisible = false;
  double walkmatesWarmProgress = 0.0;
  late Timer walkmatesWarmTimer;
  final int walkmatesWarmSeconds = 6;
  bool walkmatesCoverVisible = true;

  bool walkmatesLoadedOnceSent = false;
  int? walkmatesFirstPageTimestamp;

  WalkmatesCourierService? walkmatesCourier;
  WalkmatesBosunViewModel? walkmatesBosunInstance;

  String walkmatesCurrentUrl = '';
  int walkmatesStartLoadTimestamp = 0;

  final WalkmatesDeviceProfile walkmatesDeviceProfileInstance =
  WalkmatesDeviceProfile();
  final WalkmatesAnalyticsSpyService walkmatesAnalyticsSpyInstance =
  WalkmatesAnalyticsSpyService();

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

  final Set<String> walkmatesExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'm.me',
    'signal.me',
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

  String? walkmatesDeepLinkFromPush;

  String? _baseUserAgent;
  String _currentUserAgent = "";
  String? _currentUrl;

  String? _serverUserAgent;

  bool _safeAreaEnabled = false;
  Color _safeAreaBackgroundColor = const Color(0xFF000000);

  bool _startupSendRawDone = false;

  String? _pendingLoadedJs;

  bool _loadedJsExecutedOnce = false;

  bool _isInGoogleAuth = false;

  List<String> _buttonWhitelist = <String>[];
  bool _showBackButton = false;

  bool _backButtonHiddenAfterTap = false;

  bool _isCurrentlyOnGoogle = false;

  static const MethodChannel _appsFlyerDeepLinkChannel =
  MethodChannel('appsflyer_deeplink_channel');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    walkmatesFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;
    _currentUrl = walkmatesHomeUrl;

    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          walkmatesCoverVisible = false;
        });
      }
    });

    Future<void>.delayed(const Duration(seconds: 7), () {
      if (!mounted) return;
      setState(() {
        walkmatesVeilVisible = true;
      });
    });

    _bindPushChannelFromAppDelegate();
    _bindAppsFlyerDeepLinkChannel();
    walkmatesBootHarbor();
  }

  bool _isAboutBlankUrl(String? value) {
    final String u = (value ?? '').trim().toLowerCase();
    return u.isEmpty || u == 'about:blank' || u.startsWith('about:blank');
  }

  bool _isAboutBlankUri(Uri? uri) => _isAboutBlankUrl(uri?.toString());

  void _bindAppsFlyerDeepLinkChannel() {
    _appsFlyerDeepLinkChannel.setMethodCallHandler(
          (MethodCall call) async {
        if (call.method == 'onDeepLink') {
          try {
            final dynamic args = call.arguments;

            Map<String, dynamic> payload;

            print(" Data Deepl link ${args.toString()}");
            if (args is Map) {
              payload = Map<String, dynamic>.from(args as Map);
            } else if (args is String) {
              payload = jsonDecode(args) as Map<String, dynamic>;
            } else {
              payload = <String, dynamic>{'raw': args.toString()};
            }

            WalkmatesLoggerService().walkmatesLogInfo(
              'AppsFlyer onDeepLink from iOS: $payload',
            );

            final dynamic raw = payload['raw'];
            if (raw is Map) {
              final Map<String, dynamic> normalized =
              Map<String, dynamic>.from(raw as Map);

              print("One Link Data $normalized");
              walkmatesAnalyticsSpyInstance.walkmatesSetOneLinkData(
                  normalized);
            } else {
              walkmatesAnalyticsSpyInstance.walkmatesSetOneLinkData(payload);
            }
          } catch (e, st) {
            WalkmatesLoggerService()
                .walkmatesLogError('Error in onDeepLink handler: $e\n$st');
          }
        }
      },
    );
  }

  void _bindPushChannelFromAppDelegate() {
    const MethodChannel pushChannel = MethodChannel('com.example.fcm/push');

    pushChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'setPushData') {
        try {
          Map<String, dynamic> pushData;
          if (call.arguments is Map) {
            pushData = Map<String, dynamic>.from(call.arguments);
            print("Get Push Data $pushData");
          } else if (call.arguments is String) {
            pushData =
            jsonDecode(call.arguments as String) as Map<String, dynamic>;
          } else {
            pushData = <String, dynamic>{'raw': call.arguments.toString()};
          }

          WalkmatesLoggerService()
              .walkmatesLogInfo('Got push data from AppDelegate: $pushData');

          // Сохраняем весь payload пуша в память и в SharedPreferences
          setState(() {
            walkmatesDeviceProfileInstance.walkmatesLastPushData = pushData;
          });

          await _cachePushData(pushData);

          // Сначала извлекаем deep link из того же pushData
          final dynamic uriRaw = pushData['uri'] ?? pushData['deep_link'];
          if (uriRaw != null && uriRaw.toString().isNotEmpty) {
            final String u = uriRaw.toString();
            walkmatesDeepLinkFromPush = u;
            await walkmatesSaveCachedDeep(u);
          }

          // Теперь отправляем в SendRawData (уже с deep link) и на сервер
          walkmatesPushAppsFlyerData();
          _sendPushDataToServer(pushData);
        } catch (e, st) {
          WalkmatesLoggerService()
              .walkmatesLogError('setPushData handler error: $e\n$st');
        }
      }
    });
  }

  bool _isGoogleUrl(Uri uri) {
    final String full = uri.toString().toLowerCase();
    return full.contains('google.com') ||
        full.contains('accounts.google.') ||
        full.contains('googleusercontent.com') ||
        full.contains('gstatic.com');
  }

  Future<void> _applyGoogleUserAgent() async {
    if (walkmatesWebViewController == null) return;

    const String googleUa = 'random';

    if (_currentUserAgent == googleUa) {
      WalkmatesLoggerService()
          .walkmatesLogInfo('[UA] Already set to "random" for Google, skip');
      return;
    }

    WalkmatesLoggerService()
        .walkmatesLogInfo('[UA] Applying GOOGLE User-Agent: $googleUa');

    try {
      await walkmatesWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      _currentUserAgent = googleUa;
      _isCurrentlyOnGoogle = true;
      print('[UA] GOOGLE WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      WalkmatesLoggerService()
          .walkmatesLogError('Error setting Google User-Agent: $e');
    }
  }

  Future<void> _applyGoogleUserAgentForPopup() async {
    if (walkmatesPopupWebViewController == null) return;

    const String googleUa = 'random';

    WalkmatesLoggerService()
        .walkmatesLogInfo('[UA] Applying GOOGLE User-Agent to POPUP: $googleUa');

    try {
      await walkmatesPopupWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      print('[UA] GOOGLE POPUP USER AGENT: $googleUa');
    } catch (e) {
      WalkmatesLoggerService()
          .walkmatesLogError('Error setting Google User-Agent for popup: $e');
    }
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

  Future<void> _applyUserAgent({String? fullua, String? uatail}) async {
    if (walkmatesWebViewController == null) return;

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      try {
        final ua = await walkmatesWebViewController!.evaluateJavascript(
          source: "navigator.userAgent",
        );
        if (ua is String && ua.trim().isNotEmpty) {
          _baseUserAgent = ua.trim();
          _currentUserAgent = _baseUserAgent!;
          walkmatesDeviceProfileInstance.walkmatesBaseUserAgent =
              _baseUserAgent;
          WalkmatesLoggerService()
              .walkmatesLogInfo('Base User-Agent detected: $_baseUserAgent');
        }
      } catch (e) {
        WalkmatesLoggerService()
            .walkmatesLogWarn('Failed to get base userAgent from JS: $e');
      }
    }

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      WalkmatesLoggerService().walkmatesLogWarn(
          'Base User-Agent is still null/empty, skip UA update');
      return;
    }

    WalkmatesLoggerService().walkmatesLogInfo(
        'Server UA payload: fullua="$fullua", uatail="$uatail", base="$_baseUserAgent"');

    String newUa;
    if (fullua != null && fullua.trim().isNotEmpty) {
      newUa = fullua.trim();
    } else if (uatail != null && uatail.trim().isNotEmpty) {
      newUa = "${_baseUserAgent!}/${uatail.trim()}";
    } else {
      newUa = "${_baseUserAgent!}";
    }

    _serverUserAgent = newUa;
    WalkmatesLoggerService()
        .walkmatesLogInfo('Server UA calculated and stored: $_serverUserAgent');
  }

  Future<void> _applyNormalUserAgentIfNeeded() async {
    if (walkmatesWebViewController == null) return;

    if (_isCurrentlyOnGoogle) {
      WalkmatesLoggerService().walkmatesLogInfo(
          '[UA] Currently on Google page, keeping "random" UA');
      return;
    }

    final String targetUa = _serverUserAgent ?? _baseUserAgent ?? 'random';

    if (targetUa == _currentUserAgent) {
      WalkmatesLoggerService().walkmatesLogInfo(
          'Normal UA unchanged, keeping: $_currentUserAgent');
      return;
    }

    WalkmatesLoggerService()
        .walkmatesLogInfo('Applying NORMAL WebView User-Agent: $targetUa');

    try {
      await walkmatesWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      print('[UA] NORMAL WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      WalkmatesLoggerService().walkmatesLogError(
          'Error while setting normal User-Agent "$targetUa": $e');
    }
  }

  Future<void> _switchUserAgentForUrl(Uri? uri) async {
    if (uri == null) return;

    if (_isGoogleUrl(uri)) {
      _isCurrentlyOnGoogle = true;
      await _applyGoogleUserAgent();
    } else {
      if (_isCurrentlyOnGoogle) {
        _isCurrentlyOnGoogle = false;
      }
      await _applyNormalUserAgentIfNeeded();
    }
  }

  Future<void> printJsUserAgent() async {
    if (walkmatesWebViewController == null) return;

    try {
      final ua = await walkmatesWebViewController!.evaluateJavascript(
        source: "navigator.userAgent",
      );

      if (ua is String) {
        print('[JS UA] navigator.userAgent = $ua');
      } else {
        print('[JS UA] navigator.userAgent (non-string) = $ua');
      }
    } catch (e, st) {
      print('Error reading navigator.userAgent: $e\n$st');
    }
  }

  Future<void> debugPrintCurrentUserAgent() async {
    WalkmatesLoggerService().walkmatesLogInfo(
        '[STATE UA] _currentUserAgent = $_currentUserAgent');
    await printJsUserAgent();
  }

  Future<void> walkmatesLoadLoadedFlag() async {
    final SharedPreferences walkmatesPrefs =
    await SharedPreferences.getInstance();
    walkmatesLoadedOnceSent =
        walkmatesPrefs.getBool(walkmatesLoadedOnceKey) ?? false;
  }

  Future<void> walkmatesSaveLoadedFlag() async {
    final SharedPreferences walkmatesPrefs =
    await SharedPreferences.getInstance();
    await walkmatesPrefs.setBool(walkmatesLoadedOnceKey, true);
    walkmatesLoadedOnceSent = true;
  }

  Future<void> walkmatesLoadCachedDeep() async {
    try {
      final SharedPreferences walkmatesPrefs =
      await SharedPreferences.getInstance();
      final String? walkmatesCached =
      walkmatesPrefs.getString(walkmatesCachedDeepKey);
      if ((walkmatesCached ?? '').isNotEmpty) {
        walkmatesDeepLinkFromPush = walkmatesCached;
      }
    } catch (_) {}
  }

  Future<void> walkmatesSaveCachedDeep(String uri) async {
    try {
      final SharedPreferences walkmatesPrefs =
      await SharedPreferences.getInstance();
      await walkmatesPrefs.setString(walkmatesCachedDeepKey, uri);
    } catch (_) {}
  }

  Future<void> _cachePushData(Map<String, dynamic> pushData) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(walkmatesCachedPushDataKey, jsonEncode(pushData));
    } catch (e) {
      WalkmatesLoggerService().walkmatesLogError('_cachePushData error: $e');
    }
  }

  Future<void> _loadCachedPushData() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? cached = prefs.getString(walkmatesCachedPushDataKey);
      if (cached != null && cached.isNotEmpty) {
        final dynamic decoded = jsonDecode(cached);
        if (decoded is Map) {
          walkmatesDeviceProfileInstance.walkmatesLastPushData =
              Map<String, dynamic>.from(decoded);
          WalkmatesLoggerService().walkmatesLogInfo(
              'Push data restored from cache: ${walkmatesDeviceProfileInstance.walkmatesLastPushData}');
        }
      }
    } catch (e) {
      WalkmatesLoggerService().walkmatesLogError('_loadCachedPushData error: $e');
    }
  }

  Future<void> walkmatesSendLoadedOnce({
    required String url,
    required int timestart,
  }) async {
    if (walkmatesLoadedOnceSent) return;

    final int walkmatesNow = DateTime.now().millisecondsSinceEpoch;

    await walkmatesPostStat(
      event: 'Loaded',
      timeStart: timestart,
      timeFinish: walkmatesNow,
      url: url,
      appSid: walkmatesAnalyticsSpyInstance.walkmatesAppsFlyerUid,
      firstPageLoadTs: walkmatesFirstPageTimestamp,
    );

    await walkmatesSaveLoadedFlag();
  }

  void walkmatesBootHarbor() {
    walkmatesStartWarmProgress();
    walkmatesWireFcmHandlers();
    walkmatesAnalyticsSpyInstance.walkmatesStartTracking(
      onUpdate: () => setState(() {}),
    );
    walkmatesBindNotificationTap();
    walkmatesPrepareDeviceProfile();
  }

  void walkmatesWireFcmHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage walkmatesMessage) async {
      if (walkmatesMessage.data.isNotEmpty) {
        walkmatesDeviceProfileInstance.walkmatesLastPushData =
            Map<String, dynamic>.from(walkmatesMessage.data);
        await _cachePushData(walkmatesMessage.data);
      }
      final dynamic walkmatesLink = walkmatesMessage.data['uri'];
      if (walkmatesLink != null) {
        final String walkmatesUri = walkmatesLink.toString();
        walkmatesDeepLinkFromPush = walkmatesUri;
        await walkmatesSaveCachedDeep(walkmatesUri);
      } else {
        walkmatesResetHomeAfterDelay();
      }
      await walkmatesPushAppsFlyerData();
    });

    FirebaseMessaging.onMessageOpenedApp
        .listen((RemoteMessage walkmatesMessage) async {
      if (walkmatesMessage.data.isNotEmpty) {
        walkmatesDeviceProfileInstance.walkmatesLastPushData =
            Map<String, dynamic>.from(walkmatesMessage.data);
        await _cachePushData(walkmatesMessage.data);
      }
      final dynamic walkmatesLink = walkmatesMessage.data['uri'];
      if (walkmatesLink != null) {
        final String walkmatesUri = walkmatesLink.toString();
        walkmatesDeepLinkFromPush = walkmatesUri;
        await walkmatesSaveCachedDeep(walkmatesUri);

        walkmatesNavigateToUri(walkmatesUri);

        await walkmatesPushDeviceInfo();
        await walkmatesPushAppsFlyerData();
      } else {
        walkmatesResetHomeAfterDelay();
      }
    });
  }

  void walkmatesBindNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onNotificationTap') {
        final Map<String, dynamic> walkmatesPayload =
        Map<String, dynamic>.from(call.arguments);
        final String? walkmatesUriRaw = walkmatesPayload['uri']?.toString();

        if (walkmatesUriRaw != null &&
            walkmatesUriRaw.isNotEmpty &&
            !walkmatesUriRaw.contains('Нет URI')) {
          final String walkmatesUri = walkmatesUriRaw;
          walkmatesDeepLinkFromPush = walkmatesUri;
          await walkmatesSaveCachedDeep(walkmatesUri);

          if (!context.mounted) return;

          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext context) =>
                  WalkmatesTableView(walkmatesUri),
            ),
                (Route<dynamic> route) => false,
          );

          await walkmatesPushDeviceInfo();
          await walkmatesPushAppsFlyerData();
        }
      }
    });
  }

  Future<void> walkmatesPrepareDeviceProfile() async {
    try {
      await walkmatesDeviceProfileInstance.walkmatesInitialize();

      final FirebaseMessaging walkmatesMessaging = FirebaseMessaging.instance;
      final NotificationSettings walkmatesSettings =
      await walkmatesMessaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      walkmatesDeviceProfileInstance.walkmatesPushEnabled =
          walkmatesSettings.authorizationStatus ==
              AuthorizationStatus.authorized ||
              walkmatesSettings.authorizationStatus ==
                  AuthorizationStatus.provisional;

      await walkmatesLoadLoadedFlag();
      await walkmatesLoadCachedDeep();
      await _loadCachedPushData();

      final SharedPreferences _launchPrefs = await SharedPreferences.getInstance();
      final int _currentLaunch = (_launchPrefs.getInt(walkmatesLaunchNumberKey) ?? 0) + 1;
      await _launchPrefs.setInt(walkmatesLaunchNumberKey, _currentLaunch);
      walkmatesDeviceProfileInstance.launchNumber = _currentLaunch;
      WalkmatesLoggerService().walkmatesLogInfo(
          'launchnumber incremented on launch: $_currentLaunch');

      walkmatesBosunInstance = WalkmatesBosunViewModel(
        walkmatesDeviceProfileInstance: walkmatesDeviceProfileInstance,
        walkmatesAnalyticsSpyInstance: walkmatesAnalyticsSpyInstance,
      );

      walkmatesCourier = WalkmatesCourierService(
        walkmatesBosun: walkmatesBosunInstance!,
        walkmatesGetWebViewController: () => walkmatesWebViewController,
      );
    } catch (error) {
      WalkmatesLoggerService()
          .walkmatesLogError('prepareDeviceProfile fail: $error');
    }
  }

  void walkmatesNavigateToUri(String link) async {
    try {
      await walkmatesWebViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(link)),
      );
    } catch (error) {
      WalkmatesLoggerService().walkmatesLogError('navigate error: $error');
    }
  }

  void walkmatesResetHomeAfterDelay() {
    Future<void>.delayed(const Duration(seconds: 3), () {
      try {
        walkmatesWebViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(walkmatesHomeUrl)),
        );
      } catch (_) {}
    });
  }

  String? _resolveTokenForShip() {
    if (widget.walkmatesSignal != null &&
        widget.walkmatesSignal!.isNotEmpty) {
      return widget.walkmatesSignal;
    }
    return null;
  }

  Future<void> _sendAllDataToPageTwice() async {
    await walkmatesPushDeviceInfo();

    Future<void>.delayed(const Duration(seconds: 8), () async {
      await walkmatesPushAppsFlyerData();
    });
  }

  Future<void> walkmatesPushDeviceInfo() async {
    final String? walkmatesToken = _resolveTokenForShip();

    try {
      await walkmatesCourier?.walkmatesPutDeviceToLocalStorage(walkmatesToken);

      // Отдельно сохраняем launchnumber в localStorage
      final int ln = walkmatesDeviceProfileInstance.launchNumber;
      if (walkmatesWebViewController != null) {
        try {
          await walkmatesWebViewController!.evaluateJavascript(
            source: "localStorage.setItem('launchnumber', '$ln');",
          );
        } catch (_) {}
      }
    } catch (error) {
      WalkmatesLoggerService()
          .walkmatesLogError('pushDeviceInfo error: $error');
    }
  }

  Future<void> walkmatesPushAppsFlyerData() async {
    final String? walkmatesToken = _resolveTokenForShip();

    try {
      await walkmatesCourier?.walkmatesSendRawToPage(
        walkmatesToken,
        deepLink: walkmatesDeepLinkFromPush,
      );
    } catch (error) {
      WalkmatesLoggerService()
          .walkmatesLogError('pushAppsFlyerData error: $error');
    }
  }

  Future<void> _sendPushDataToServer(Map<String, dynamic> pushData) async {
    try {
      final String? token = _resolveTokenForShip();
      final Map<String, dynamic> payload = walkmatesBosunInstance
              ?.walkmatesAppsFlyerPayload(token,
                  deepLink: walkmatesDeepLinkFromPush) ??
          <String, dynamic>{};

      WalkmatesLoggerService()
          .walkmatesLogInfo('Sending push data to server: ${jsonEncode(payload)}');

      await WalkmatesNetworkService().walkmatesPostJson(
        walkmatesStatEndpoint,
        payload,
      );
    } catch (e) {
      WalkmatesLoggerService()
          .walkmatesLogError('_sendPushDataToServer error: $e');
    }
  }

  void walkmatesStartWarmProgress() {
    int walkmatesTick = 0;
    walkmatesWarmProgress = 0.0;

    walkmatesWarmTimer =
        Timer.periodic(const Duration(milliseconds: 100), (Timer timer) {
          if (!mounted) return;

          setState(() {
            walkmatesTick++;
            walkmatesWarmProgress = walkmatesTick / (walkmatesWarmSeconds * 10);

            if (walkmatesWarmProgress >= 1.0) {
              walkmatesWarmProgress = 1.0;
              walkmatesWarmTimer.cancel();
            }
          });
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      walkmatesSleepAt = DateTime.now();
    }

    if (state == AppLifecycleState.resumed) {
      if (Platform.isIOS && walkmatesSleepAt != null) {
        final DateTime walkmatesNow = DateTime.now();
        final Duration walkmatesDrift =
        walkmatesNow.difference(walkmatesSleepAt!);

        if (walkmatesDrift > const Duration(minutes: 25)) {
          walkmatesReboardHarbor();
        }
      }
      walkmatesSleepAt = null;
    }
  }

  void walkmatesReboardHarbor() {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext context) =>
              WalkmatesHarbor(walkmatesSignal: widget.walkmatesSignal),
        ),
            (Route<dynamic> route) => false,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    walkmatesWarmTimer.cancel();

    _parentInstallTimer?.cancel();
    _popupInstallTimer?.cancel();

    walkmatesWebViewController = null;
    walkmatesPopupWebViewController = null;

    super.dispose();
  }

  bool walkmatesIsBareEmail(Uri uri) {
    final String walkmatesScheme = uri.scheme;
    if (walkmatesScheme.isNotEmpty) return false;
    final String walkmatesRaw = uri.toString();
    return walkmatesRaw.contains('@') && !walkmatesRaw.contains(' ');
  }

  Uri walkmatesToMailto(Uri uri) {
    final String walkmatesFull = uri.toString();
    final List<String> walkmatesParts = walkmatesFull.split('?');
    final String walkmatesEmail = walkmatesParts.first;
    final Map<String, String> walkmatesQueryParams = walkmatesParts.length > 1
        ? Uri.splitQueryString(walkmatesParts[1])
        : <String, String>{};

    return Uri(
      scheme: 'mailto',
      path: walkmatesEmail,
      queryParameters:
      walkmatesQueryParams.isEmpty ? null : walkmatesQueryParams,
    );
  }

  Future<bool> walkmatesOpenMailExternal(Uri mailto) async {
    try {
      final String scheme = mailto.scheme.toLowerCase();
      final String path = mailto.path.toLowerCase();

      WalkmatesLoggerService().walkmatesLogInfo(
          'walkmatesOpenMailExternal: scheme=$scheme path=$path uri=$mailto');

      if (scheme != 'mailto') {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        WalkmatesLoggerService().walkmatesLogInfo(
            'walkmatesOpenMailExternal: non-mailto result=$ok');
        return ok;
      }

      final bool can = await canLaunchUrl(mailto);
      WalkmatesLoggerService().walkmatesLogInfo(
          'walkmatesOpenMailExternal: canLaunchUrl(mailto) = $can');

      if (can) {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        WalkmatesLoggerService().walkmatesLogInfo(
            'walkmatesOpenMailExternal: externalApplication result=$ok');
        if (ok) return true;
      }

      WalkmatesLoggerService().walkmatesLogWarn(
          'walkmatesOpenMailExternal: no native handler for mailto, fallback to Gmail Web');
      final Uri gmailUri = walkmatesGmailizeMailto(mailto);
      final bool webOk = await walkmatesOpenWeb(gmailUri);
      WalkmatesLoggerService().walkmatesLogInfo(
          'walkmatesOpenMailExternal: Gmail Web fallback result=$webOk');
      return webOk;
    } catch (e, st) {
      WalkmatesLoggerService().walkmatesLogError(
          'walkmatesOpenMailExternal error: $e\n$st; url=$mailto');
      return false;
    }
  }

  Future<bool> walkmatesOpenMailWeb(Uri mailto) async {
    final Uri walkmatesGmailUri = walkmatesGmailizeMailto(mailto);
    return walkmatesOpenWeb(walkmatesGmailUri);
  }

  Uri walkmatesGmailizeMailto(Uri mailUri) {
    final Map<String, String> walkmatesQueryParams = mailUri.queryParameters;

    final Map<String, String> walkmatesParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (mailUri.path.isNotEmpty) 'to': mailUri.path,
      if ((walkmatesQueryParams['subject'] ?? '').isNotEmpty)
        'su': walkmatesQueryParams['subject']!,
      if ((walkmatesQueryParams['body'] ?? '').isNotEmpty)
        'body': walkmatesQueryParams['body']!,
      if ((walkmatesQueryParams['cc'] ?? '').isNotEmpty)
        'cc': walkmatesQueryParams['cc']!,
      if ((walkmatesQueryParams['bcc'] ?? '').isNotEmpty)
        'bcc': walkmatesQueryParams['bcc']!,
    };

    return Uri.https('mail.google.com', '/mail/', walkmatesParams);
  }

  bool walkmatesIsPlatformLink(Uri uri) {
    final String walkmatesScheme = uri.scheme.toLowerCase();
    if (walkmatesSpecialSchemes.contains(walkmatesScheme)) {
      return true;
    }

    if (walkmatesScheme == 'http' || walkmatesScheme == 'https') {
      final String walkmatesHost = uri.host.toLowerCase();

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

  String walkmatesDigitsOnly(String source) =>
      source.replaceAll(RegExp(r'[^0-9+]'), '');

  Uri walkmatesHttpizePlatformUri(Uri uri) {
    final String walkmatesScheme = uri.scheme.toLowerCase();

    if (walkmatesScheme == 'tg' || walkmatesScheme == 'telegram') {
      final Map<String, String> walkmatesQp = uri.queryParameters;
      final String? walkmatesDomain = walkmatesQp['domain'];

      if (walkmatesDomain != null && walkmatesDomain.isNotEmpty) {
        return Uri.https(
          't.me',
          '/$walkmatesDomain',
          <String, String>{
            if (walkmatesQp['start'] != null) 'start': walkmatesQp['start']!,
          },
        );
      }

      final String walkmatesPath = uri.path.isNotEmpty ? uri.path : '';

      return Uri.https(
        't.me',
        '/$walkmatesPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if ((walkmatesScheme == 'http' || walkmatesScheme == 'https') &&
        uri.host.toLowerCase().endsWith('t.me')) {
      return uri;
    }

    if (walkmatesScheme == 'viber') {
      return uri;
    }

    if (walkmatesScheme == 'whatsapp') {
      final Map<String, String> walkmatesQp = uri.queryParameters;
      final String? walkmatesPhone = walkmatesQp['phone'];
      final String? walkmatesText = walkmatesQp['text'];

      if (walkmatesPhone != null && walkmatesPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${walkmatesDigitsOnly(walkmatesPhone)}',
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

    if ((walkmatesScheme == 'http' || walkmatesScheme == 'https') &&
        (uri.host.toLowerCase().endsWith('wa.me') ||
            uri.host.toLowerCase().endsWith('whatsapp.com'))) {
      return uri;
    }

    if (walkmatesScheme == 'skype') {
      return uri;
    }

    if (walkmatesScheme == 'fb-messenger') {
      final String walkmatesPath =
      uri.pathSegments.isNotEmpty ? uri.pathSegments.join('/') : '';
      final Map<String, String> walkmatesQp = uri.queryParameters;

      final String walkmatesId =
          walkmatesQp['id'] ?? walkmatesQp['user'] ?? walkmatesPath;

      if (walkmatesId.isNotEmpty) {
        return Uri.https(
          'm.me',
          '/$walkmatesId',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return Uri.https(
        'm.me',
        '/',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if (walkmatesScheme == 'sgnl') {
      final Map<String, String> walkmatesQp = uri.queryParameters;
      final String? walkmatesPhone = walkmatesQp['phone'];
      final String? walkmatesUsername = walkmatesQp['username'];

      if (walkmatesPhone != null && walkmatesPhone.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#p/${walkmatesDigitsOnly(walkmatesPhone)}',
        );
      }

      if (walkmatesUsername != null && walkmatesUsername.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#u/$walkmatesUsername',
        );
      }

      final String walkmatesPath = uri.pathSegments.join('/');
      if (walkmatesPath.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/$walkmatesPath',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return uri;
    }

    if (walkmatesScheme == 'tel') {
      return Uri.parse('tel:${walkmatesDigitsOnly(uri.path)}');
    }

    if (walkmatesScheme == 'mailto') {
      return uri;
    }

    if (walkmatesScheme == 'bnl') {
      final String walkmatesNewPath = uri.path.isNotEmpty ? uri.path : '';
      return Uri.https(
        'bnl.com',
        '/$walkmatesNewPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    return uri;
  }

  Future<bool> walkmatesOpenWeb(Uri uri) async {
    try {
      if (await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }

      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      try {
        return await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }

  Future<bool> walkmatesOpenExternal(Uri uri) async {
    try {
      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      return false;
    }
  }

  void walkmatesHandleServerSavedata(String savedata) {
    print('onServerResponse savedata: $savedata');
    if(savedata=='false'){
      Navigator.pushReplacement(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext context) =>
          OceanCalendarHelpLite(),
        ),
      );
    }
  }

  Color _parseHexColor(String hex) {
    String value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) {
      value = 'FF$value';
    }
    final intColor = int.tryParse(value, radix: 16) ?? 0xFF000000;
    return Color(intColor);
  }

  Future<void> _updateAppDataInLocalStorageFromProfile() async {
    final InAppWebViewController? controller = walkmatesWebViewController;
    if (controller == null) return;

    final String? token = _resolveTokenForShip();
    final Map<String, dynamic> map =
    walkmatesDeviceProfileInstance.walkmatesToMap(fcmToken: token);

    WalkmatesLoggerService()
        .walkmatesLogInfo('updateAppDataFromProfile: ${jsonEncode(map)}');

    await walkmatesSaveJsonToLocalStorageAndPrefs(
      controller: controller,
      key: 'app_data',
      data: map,
    );
  }

  void _updateExtraDataFromServerPayload(Map<dynamic, dynamic> root) {
    try {
      final dynamic adataRaw = root['adata'];
      if (adataRaw is Map) {
        final Map adata = adataRaw;

        final dynamic buttonswlRaw = adata['buttonswl'];
        if (buttonswlRaw is List) {
          final List<String> list = buttonswlRaw
              .where((e) => e != null)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          setState(() {
            _buttonWhitelist = list;
          });
          WalkmatesLoggerService()
              .walkmatesLogInfo('buttonswl updated: $_buttonWhitelist');
          _updateBackButtonVisibility();
        }

        // fpscashier из adata → профиль → localStorage
        if (adata.containsKey('fpscashier')) {
          final dynamic fpsRaw = adata['fpscashier'];
          bool? fpsValue;

          if (fpsRaw is bool) {
            fpsValue = fpsRaw;
          } else if (fpsRaw is num) {
            fpsValue = fpsRaw != 0;
          } else if (fpsRaw is String) {
            final String v = fpsRaw.toLowerCase().trim();
            if (v == 'true' || v == '1' || v == 'yes') fpsValue = true;
            if (v == 'false' || v == '0' || v == 'no') fpsValue = false;
          }

          if (fpsValue != null) {
            final bool old = walkmatesDeviceProfileInstance.safecasher;
            walkmatesDeviceProfileInstance.safecasher = fpsValue;
            WalkmatesLoggerService().walkmatesLogInfo(
                'fpscashier updated from server payload: $fpsValue');

            _updateAppDataInLocalStorageFromProfile();

            // при переходе из false -> true можно (опционально)
            // сразу доустановить хуки на уже открытой странице
            if (!old && fpsValue && walkmatesWebViewController != null) {
              WalkmatesLoggerService().walkmatesLogInfo(
                  'fpscashier switched to true, installing JS hooks now');
              _scheduleSafeInstall(
                walkmatesWebViewController!,
                label: 'parent',
              );
            }
          }
        }

        final dynamic savelsRaw = adata['savels'];
        if (savelsRaw is Map) {
          walkmatesDeviceProfileInstance.walkmatesSavels =
          Map<String, dynamic>.from(savelsRaw);
          WalkmatesLoggerService().walkmatesLogInfo(
              'savels stored in profile: ${walkmatesDeviceProfileInstance.walkmatesSavels}');
          _updateAppDataInLocalStorageFromProfile();
        }
      }
    } catch (e, st) {
      WalkmatesLoggerService().walkmatesLogError(
          'Error in _updateExtraDataFromServerPayload: $e\n$st');
    }
  }

  void _updateSafeAreaFromServerPayload(Map<dynamic, dynamic> root) {
    WalkmatesLoggerService().walkmatesLogInfo(
        'SAFEAREA RAW PAYLOAD: ${jsonEncode(root)}');

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

    WalkmatesLoggerService().walkmatesLogInfo(
        'SAFEAREA PARSED: enabled=$safearea, light=$bgLightHex, dark=$bgDarkHex');

    if (safearea == null) {
      return;
    }

    final Brightness platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    String? chosenHex;
    if (platformBrightness == Brightness.light) {
      chosenHex = bgLightHex ?? bgDarkHex;
    } else {
      chosenHex = bgDarkHex ?? bgLightHex;
    }

    final bool enabled = safearea;
    Color background =
    enabled ? const Color(0xFF1A1A22) : const Color(0xFF000000);

    if (enabled && chosenHex != null && chosenHex.isNotEmpty) {
      background = _parseHexColor(chosenHex);
    }

    setState(() {
      _safeAreaEnabled = enabled;
      _safeAreaBackgroundColor = background;
      walkmatesDeviceProfileInstance.walkmatesSafeAreaEnabled = enabled;
      walkmatesDeviceProfileInstance.walkmatesSafeAreaColor =
      enabled ? (chosenHex ?? '#1A1A22') : '';
    });

    () async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setBool('safearea_enabled', enabled);
        await prefs.setString(
          'safearea_color',
          walkmatesDeviceProfileInstance.walkmatesSafeAreaColor ?? '',
        );
        WalkmatesLoggerService().walkmatesLogInfo(
          'SafeArea saved to prefs: enabled=$enabled, color="${walkmatesDeviceProfileInstance.walkmatesSafeAreaColor}"',
        );
      } catch (e, st) {
        WalkmatesLoggerService()
            .walkmatesLogError('Error saving SafeArea to prefs: $e\n$st');
      }
    }();

    WalkmatesLoggerService().walkmatesLogInfo(
        'SAFEAREA STATE UPDATED: enabled=$_safeAreaEnabled, color=$_safeAreaBackgroundColor (brightness=$platformBrightness)');
  }

  bool _matchesButtonWhitelist(String url) {
    if (url.isEmpty) return false;
    if (_buttonWhitelist.isEmpty) return false;
    Uri? uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return false;
    }

    final String host = uri.host.toLowerCase();
    final String full = uri.toString();

    for (final String item in _buttonWhitelist) {
      final String trimmed = item.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        if (full.startsWith(trimmed)) return true;
      } else {
        final String domain = trimmed.toLowerCase();
        if (host == domain || host.endsWith('.$domain')) return true;
      }
    }

    return false;
  }

  Future<void> _updateBackButtonVisibility() async {
    final String current = _currentUrl ?? walkmatesCurrentUrl;
    final bool shouldShow = _matchesButtonWhitelist(current);

    if (_backButtonHiddenAfterTap) {
      _backButtonHiddenAfterTap = false;
    }

    if (shouldShow != _showBackButton) {
      if (mounted) {
        setState(() {
          _showBackButton = shouldShow;
        });
      } else {
        _showBackButton = shouldShow;
      }
    }
  }

  Future<void> _handleBackButtonPressed() async {
    if (mounted) {
      setState(() {
        _backButtonHiddenAfterTap = true;
        _showBackButton = false;
      });
    } else {
      _backButtonHiddenAfterTap = true;
      _showBackButton = false;
    }

    if (_isPopupVisible) {
      await _handlePopupBackPressed();
      return;
    }

    if (walkmatesWebViewController == null) return;
    try {
      if (await walkmatesWebViewController!.canGoBack()) {
        await walkmatesWebViewController!.goBack();
      } else {
        await walkmatesWebViewController!.loadUrl(
          urlRequest: URLRequest(url: WebUri(walkmatesHomeUrl)),
        );
      }
    } catch (e, st) {
      WalkmatesLoggerService()
          .walkmatesLogError('Error on back button pressed: $e\n$st');
    }
  }

  InAppWebViewSettings _mainWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      transparentBackground: true,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  InAppWebViewSettings _popupWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
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

  Future<void> _safeEvaluateJavascript(
      InAppWebViewController? controller, {
        required String source,
        String debugName = 'js',
      }) async {
    if (controller == null) return;
    if (!mounted) return;

    try {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      await controller.evaluateJavascript(source: source);
    } catch (e) {
      print('WERLOG: safeEvaluateJavascript error [$debugName]: $e');
    }
  }

  Future<void> _installJsErrorLogger(InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installJsErrorLogger',
      source: r'''
        (function() {
          if (window.__ncupJsLoggerInstalled) return;
          window.__ncupJsLoggerInstalled = true;

          function serializeError(err) {
            try {
              if (!err) return null;
              var plain = {};
              Object.getOwnPropertyNames(err).forEach(function(key) {
                plain[key] = err[key];
              });
              return plain;
            } catch (_) {
              return { message: String(err) };
            }
          }

          window.onerror = function(message, source, lineno, colno, error) {
            try {
              var payload = {
                type: 'onerror',
                message: String(message || ''),
                source: String(source || ''),
                lineno: lineno || 0,
                colno: colno || 0,
                error: serializeError(error)
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger onerror inner fail', e);
            }
          };

          window.addEventListener('unhandledrejection', function(event) {
            try {
              var reason = event.reason;
              var payload = {
                type: 'unhandledrejection',
                reason: serializeError(reason) || { message: String(reason || '') }
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger unhandledrejection inner fail', e);
            }
          });
        })();
      ''',
    );
  }

  Future<void> _installPostMessageBridge(
      InAppWebViewController controller, {
        required String label,
      }) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installPostMessageBridge-$label',
      source: '''
        (function() {
          if (window.__ncupPostMessageBridgeInstalled_$label) return;
          window.__ncupPostMessageBridgeInstalled_$label = true;

          window.addEventListener('message', function(event) {
            try {
              var dataRaw = event.data;
              var dataString;
              try {
                dataString = JSON.stringify(dataRaw);
              } catch (e) {
                dataString = String(dataRaw);
              }

              var payload = {
                label: '$label',
                origin: String(event.origin || ''),
                data: dataString,
                href: String(window.location.href || '')
              };

              console.log('[NCUP postMessage $label]', payload);

              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupPostMessage', payload);
              }

              try {
                var parsed = dataRaw;
                if (typeof parsed === 'string') {
                  parsed = JSON.parse(parsed);
                }
                if (parsed && parsed.type === 'newTab' && parsed.url) {
                  if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                    window.flutter_inappwebview.callHandler('NcupCheckoutAction', parsed);
                  }
                }
              } catch (_) {}
            } catch (e) {
              console.log('NcupPostMessage bridge error', e);
            }
          });
        })();
      ''',
    );
  }

  Future<void> _installCheckoutInterceptor(
      InAppWebViewController controller,
      ) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installCheckoutInterceptor',
      source: r'''
        (function() {
          if (window.__ncupCheckoutInterceptorInstalled) return;
          window.__ncupCheckoutInterceptorInstalled = true;

          function sendToFlutter(data) {
            try {
              if (!data || typeof data !== 'object') return;
              if (data.type === 'newTab' && data.url) {
                console.log('[NCUP checkout interceptor] newTab:', data.url);
                if (
                  window.flutter_inappwebview &&
                  window.flutter_inappwebview.callHandler
                ) {
                  window.flutter_inappwebview.callHandler(
                    'NcupCheckoutAction',
                    data
                  );
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] send error', e);
            }
          }

          function tryParseMaybeJson(value) {
            try {
              if (!value) return null;
              if (typeof value === 'object') {
                return value;
              }
              if (typeof value === 'string') {
                return JSON.parse(value);
              }
              return null;
            } catch (e) {
              return null;
            }
          }

          function tryHandlePayload(payload) {
            try {
              var data = tryParseMaybeJson(payload);
              if (!data) return;

              if (Array.isArray(data)) {
                data.forEach(function(item) {
                  if (item && item.type === 'newTab' && item.url) {
                    sendToFlutter(item);
                  }
                });
                return;
              }

              if (data.type === 'newTab' && data.url) {
                sendToFlutter(data);
                return;
              }

              if (data.savedata) {
                var saved = tryParseMaybeJson(data.savedata);
                if (saved && saved.type === 'newTab' && saved.url) {
                  sendToFlutter(saved);
                  return;
                }
              }

              if (data.data) {
                var nested = tryParseMaybeJson(data.data);
                if (nested && nested.type === 'newTab' && nested.url) {
                  sendToFlutter(nested);
                  return;
                }
              }

              if (data.content) {
                var content = tryParseMaybeJson(data.content);
                if (content && content.type === 'newTab' && content.url) {
                  sendToFlutter(content);
                  return;
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] handle error', e);
            }
          }

          var originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = function() {
              return originalFetch.apply(this, arguments).then(function(response) {
                try {
                  var cloned = response.clone();
                  cloned.text().then(function(text) {
                    tryHandlePayload(text);
                  }).catch(function() {});
                } catch (e) {}
                return response;
              });
            };
          }

          var OriginalXHR = window.XMLHttpRequest;
          if (OriginalXHR) {
            window.XMLHttpRequest = function() {
              var xhr = new OriginalXHR();
              var originalOpen = xhr.open;
              var originalSend = xhr.send;

              xhr.open = function() {
                return originalOpen.apply(xhr, arguments);
              };

              xhr.send = function() {
                xhr.addEventListener('load', function() {
                  try {
                    tryHandlePayload(xhr.responseText);
                  } catch (e) {}
                });
                return originalSend.apply(xhr, arguments);
              };

              return xhr;
            };
          }

          var originalOpen = window.open;
          window.open = function(url, target, features) {
            try {
              console.log('[NCUP window.open intercepted]', url, target, features);
            } catch (e) {}

            if (originalOpen) {
              return originalOpen.apply(window, arguments);
            }
            return null;
          };
        })();
      ''',
    );
  }

  Future<void> _installLocalStorageHook(
      InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installLocalStorageHook',
      source: r'''
        (function() {
          if (window.__ncupLocalStorageHookInstalled) return;
          window.__ncupLocalStorageHookInstalled = true;

          try {
            var originalSetItem = window.localStorage.setItem;
            window.localStorage.setItem = function(key, value) {
              try {
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                  window.flutter_inappwebview.callHandler('NcupLocalStorageSetItem', {
                    key: String(key),
                    value: String(value)
                  });
                }
              } catch (e) {
                console.log('Ncup localStorage hook error', e);
              }
              return originalSetItem.apply(this, arguments);
            };
          } catch (e) {
            console.log('Ncup localStorage hook init error', e);
          }
        })();
      ''',
    );
  }

  Future<void> _safeInstallAll(
      InAppWebViewController? controller, {
        required String label,
      }) async {
    if (controller == null) return;
    if (!mounted) return;

    // хуки ставим только если с сервера пришёл fpscashier=true
    if (!walkmatesDeviceProfileInstance.safecasher) {
      print('WERLOG: safeInstallAll skipped ($label) because fpscashier=false');
      return;
    }

    try {
      await Future<void>.delayed(
        label == 'popup'
            ? const Duration(milliseconds: 550)
            : const Duration(milliseconds: 250),
      );
      if (!mounted) return;
      await _installJsErrorLogger(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installPostMessageBridge(controller, label: label);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installCheckoutInterceptor(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installLocalStorageHook(controller);
    } catch (e) {
      print('WERLOG: safeInstallAll error label=$label error=$e');
    }
  }

  void _scheduleSafeInstall(
      InAppWebViewController controller, {
        required String label,
      }) {
    if (label == 'popup') {
      _popupInstallTimer?.cancel();
      _popupInstallTimer =
          Timer(const Duration(milliseconds: 450), () async {
            if (!mounted) return;
            await _safeInstallAll(controller, label: label);
          });
    } else {
      _parentInstallTimer?.cancel();
      _parentInstallTimer =
          Timer(const Duration(milliseconds: 250), () async {
            if (!mounted) return;
            await _safeInstallAll(controller, label: label);
          });
    }
  }

  Map<String, dynamic>? _tryDecodeMap(dynamic value) {
    try {
      if (value == null) return null;
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
      if (value is String) {
        final String trimmed = value.trim();
        if (trimmed.isEmpty) return null;
        final dynamic decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _openExternalForJsonNewTab(Uri uri) async {
    if (_isAboutBlankUri(uri)) return false;

    final String url = uri.toString();

    if (_handledNewTabUrls.contains(url)) {
      print('WERLOG: duplicate JSON newTab ignored url=$url');
      return true;
    }

    _handledNewTabUrls.add(url);

    if (_isOpeningExternalNewTab) {
      print('WERLOG: external newTab already opening, ignored url=$url');
      return false;
    }

    _isOpeningExternalNewTab = true;

    try {
      final bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      print('WERLOG: JSON newTab external launched=$launched url=$url');
      return launched;
    } catch (e) {
      print('WERLOG: JSON newTab external error=$e url=$url');
      return false;
    } finally {
      Future<void>.delayed(const Duration(seconds: 2), () {
        _isOpeningExternalNewTab = false;
      });
    }
  }

  Future<bool> _handleCheckoutAction(dynamic rawPayload) async {
    try {
      Map<String, dynamic>? data = _tryDecodeMap(rawPayload);
      if (data == null) return false;

      if (data.containsKey('savedata')) {
        final Map<String, dynamic>? savedataMap =
        _tryDecodeMap(data['savedata']);
        if (savedataMap != null) {
          data = savedataMap;
        }
      }

      if (data.containsKey('data')) {
        final Map<String, dynamic>? dataMap = _tryDecodeMap(data['data']);
        if (dataMap != null &&
            dataMap['type']?.toString() == 'newTab' &&
            (dataMap['url']?.toString() ?? '').isNotEmpty) {
          data = dataMap;
        }
      }

      if (data.containsKey('content')) {
        final Map<String, dynamic>? contentMap =
        _tryDecodeMap(data['content']);
        if (contentMap != null &&
            contentMap['type']?.toString() == 'newTab' &&
            (contentMap['url']?.toString() ?? '').isNotEmpty) {
          data = contentMap;
        }
      }

      final String type = data['type']?.toString() ?? '';
      final String url = data['url']?.toString() ?? '';

      if (type == 'newTab' && url.isNotEmpty) {
        final Uri? uri = Uri.tryParse(url);
        if (uri == null || _isAboutBlankUri(uri)) {
          print('WERLOG: invalid JSON newTab uri=$url');
          return false;
        }

        print('WERLOG: handle JSON newTab url=$url');
        await _openExternalForJsonNewTab(uri);
        return true;
      }

      return false;
    } catch (e) {
      print('WERLOG: handleCheckoutAction error: $e');
      return false;
    }
  }

  Future<bool> _onCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction request,
      ) async {
    final Uri? walkmatesUri = request.request.url;
    final String urlString = walkmatesUri?.toString() ?? '';

    print(
      'WERLOG: MAIN onCreateWindow '
          'windowId=${request.windowId} '
          'url=$urlString '
          'isDialog=${request.isDialog} '
          'hasGesture=${request.hasGesture}',
    );

    if (walkmatesUri != null) {
      _currentUrl = walkmatesUri.toString();
      await _updateBackButtonVisibility();

      if (_isGoogleUrl(walkmatesUri)) {}

      if (walkmatesIsBankScheme(walkmatesUri) ||
          ((walkmatesUri.scheme == 'http' || walkmatesUri.scheme == 'https') &&
              walkmatesIsBankDomain(walkmatesUri))) {
        await walkmatesOpenBank(walkmatesUri);
        return false;
      }

      if (walkmatesIsBareEmail(walkmatesUri)) {
        final Uri walkmatesMailto = walkmatesToMailto(walkmatesUri);
        await walkmatesOpenMailExternal(walkmatesMailto);
        return false;
      }

      final String walkmatesScheme = walkmatesUri.scheme.toLowerCase();

      if (walkmatesScheme == 'mailto') {
        await walkmatesOpenMailExternal(walkmatesUri);
        return false;
      }

      if (walkmatesScheme == 'tel') {
        await launchUrl(walkmatesUri, mode: LaunchMode.externalApplication);
        return false;
      }

      final String host = walkmatesUri.host.toLowerCase();
      final bool walkmatesIsSocial = host.endsWith('facebook.com') ||
          host.endsWith('instagram.com') ||
          host.endsWith('twitter.com') ||
          host.endsWith('x.com');

      if (walkmatesIsSocial) {
        await walkmatesOpenExternal(walkmatesUri);
        return false;
      }

      if (walkmatesIsPlatformLink(walkmatesUri)) {
        final Uri walkmatesWebUri = walkmatesHttpizePlatformUri(walkmatesUri);
        await walkmatesOpenExternal(walkmatesWebUri);
        return false;
      }
    }

    if (!mounted) return false;

    setState(() {
      _popupCreateAction = request;
      _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
          ? urlString
          : null;
      _popupCurrentUrl = _popupUrl;
      _isPopupVisible = true;
      _popupCanGoBack = false;
    });

    return true;
  }

  Future<bool> _onPopupCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction createWindowAction,
      ) async {
    final Uri? uri = createWindowAction.request.url;
    final String urlString = uri?.toString() ?? '';

    print(
      'WERLOG: POPUP onCreateWindow '
          'windowId=${createWindowAction.windowId} '
          'url=$urlString',
    );

    if (!mounted) return false;

    if (createWindowAction.windowId != null) {
      setState(() {
        _popupCreateAction = createWindowAction;
        _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
            ? urlString
            : _popupUrl;
        _popupCurrentUrl = _popupUrl;
        _isPopupVisible = true;
      });
      return true;
    }

    if (urlString.isNotEmpty && !_isAboutBlankUrl(urlString)) {
      try {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(urlString)),
        );
      } catch (e) {
        print('WERLOG: popup inner window.open load error: $e url=$urlString');
      }
    }

    return false;
  }

  void _closePopup() {
    setState(() {
      _isPopupVisible = false;
      _popupUrl = null;
      _popupCurrentUrl = null;
      _popupCreateAction = null;
      _popupCanGoBack = false;
      walkmatesPopupWebViewController = null;
    });
  }

  Future<void> _closePopupAndNotifyParent({
    String reason = 'closed_by_user',
  }) async {
    try {
      await walkmatesWebViewController?.evaluateJavascript(
        source: '''
          try {
            window.dispatchEvent(new MessageEvent('message', {
              data: ${jsonEncode({
          'type': 'ncup_popup_closed',
          'reason': reason,
        })},
              origin: window.location.origin
            }));
          } catch(e) {
            console.log('ncup popup close notify failed', e);
          }
        ''',
      );
    } catch (e) {
      print('WERLOG: closePopup notify parent error: $e');
    }
    _closePopup();
  }

  Future<void> _refreshPopupCanGoBack() async {
    final InAppWebViewController? c = walkmatesPopupWebViewController;
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
    } catch (e) {
      print('WERLOG: _refreshPopupCanGoBack error: $e');
    }
  }

  Future<void> _handlePopupBackPressed() async {
    final InAppWebViewController? c = walkmatesPopupWebViewController;
    if (c == null) {
      _closePopup();
      return;
    }
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          _refreshPopupCanGoBack();
        });
      } else {
        await _closePopupAndNotifyParent(reason: 'popup_back_no_history');
      }
    } catch (e) {
      print('WERLOG: _handlePopupBackPressed error: $e');
      _closePopup();
    }
  }

  bool _isCurrentPopupInWhitelist() {
    if (!_isPopupVisible) return false;
    final String popupUrlForCheck = _popupCurrentUrl ?? _popupUrl ?? '';
    return _matchesButtonWhitelist(popupUrlForCheck);
  }

  Widget _buildPopupWebView() {
    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool showBackArrow = !popupInWhitelist && _popupCanGoBack;
    final bool showCloseButton = !popupInWhitelist && !_popupCanGoBack;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: Column(
          children: [
            if (!popupInWhitelist) ...[
              SafeArea(
                bottom: false,
                child: Container(
                  color: Colors.black,
                  child: Row(
                    children: [
                      if (showBackArrow)
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Colors.white),
                          onPressed: _handlePopupBackPressed,
                        )
                      else if (showCloseButton)
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () {
                            _closePopupAndNotifyParent(reason: 'close_button');
                          },
                        ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
            ],
            Expanded(
              child: InAppWebView(
                windowId: _popupCreateAction?.windowId,
                initialUrlRequest:
                (_popupCreateAction?.windowId == null) && _popupUrl != null
                    ? URLRequest(url: WebUri(_popupUrl!))
                    : null,
                initialSettings: _popupWebViewSettings(),
                onWebViewCreated:
                    (InAppWebViewController popupController) async {
                  walkmatesPopupWebViewController = popupController;

                  print(
                    'WERLOG: popup created '
                        'windowId=${_popupCreateAction?.windowId} '
                        'initialUrl=${_popupUrl ?? _popupCreateAction?.request.url}',
                  );

                  final String popupInitUrl = _popupUrl ??
                      _popupCreateAction?.request.url?.toString() ??
                      '';
                  if (popupInitUrl.isNotEmpty) {
                    final Uri? popupUri = Uri.tryParse(popupInitUrl);
                    if (popupUri != null && _isGoogleUrl(popupUri)) {
                      await _applyGoogleUserAgentForPopup();
                    }
                  }

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupLocalStorageSetItem',
                    callback: (List<dynamic> args) async {
                      try {
                        if (args.isEmpty) return null;
                        final dynamic raw = args.first;
                        if (raw is Map) {
                          final String key = raw['key']?.toString() ?? '';
                          final String value =
                              raw['value']?.toString() ?? '';
                          if (key.isNotEmpty) {
                            final SharedPreferences prefs =
                            await SharedPreferences.getInstance();
                            await prefs.setString(key, value);
                            WalkmatesLoggerService().walkmatesLogInfo(
                                'NcupLocalStorageSetItem (popup): saved key="$key" len=${value.length}');
                          }
                        }
                      } catch (e, st) {
                        WalkmatesLoggerService().walkmatesLogError(
                            'NcupLocalStorageSetItem popup handler error: $e\n$st');
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupCheckoutAction',
                    callback: (List<dynamic> args) async {
                      print('WERLOG: POPUP NcupCheckoutAction args=$args');
                      if (args.isNotEmpty) {
                        await _handleCheckoutAction(args.first);
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupPostMessage',
                    callback: (List<dynamic> args) async {
                      print('WERLOG: POPUP NcupPostMessage args=$args');
                      if (args.isNotEmpty) {
                        final dynamic first = args.first;
                        if (first is Map && first['data'] != null) {
                          await _handleCheckoutAction(first['data']);
                        } else {
                          await _handleCheckoutAction(first);
                        }
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupJSLogger',
                    callback: (List<dynamic> args) {
                      print('WERLOG: POPUP JS error payload: $args');
                      return null;
                    },
                  );
                },
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStart: (controller, uri) async {
                  print('WERLOG: popup onLoadStart url=$uri');
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (_isGoogleUrl(uri)) {
                      await _applyGoogleUserAgentForPopup();
                    }

                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onLoadStop: (controller, uri) async {
                  print('WERLOG: popup onLoadStop url=$uri');
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                      });
                    }
                  }
                  if (!_isAboutBlankUri(uri)) {
                    _scheduleSafeInstall(controller, label: 'popup');
                  }
                  _refreshPopupCanGoBack();
                },
                onUpdateVisitedHistory: (controller, url, isReload) async {
                  if (url != null && !_isAboutBlankUri(url)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = url.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onCreateWindow: _onPopupCreateWindowHandler,
                shouldOverrideUrlLoading: (
                    InAppWebViewController controller,
                    NavigationAction navigationAction,
                    ) async {
                  final Uri? uri = navigationAction.request.url;
                  if (uri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (_isAboutBlankUri(uri)) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (_isGoogleUrl(uri)) {
                    await _applyGoogleUserAgentForPopup();
                    return NavigationActionPolicy.ALLOW;
                  }

                  final String scheme = uri.scheme.toLowerCase();

                  if (walkmatesIsBareEmail(uri)) {
                    final Uri mailto = walkmatesToMailto(uri);
                    await walkmatesOpenMailExternal(mailto);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'mailto') {
                    await walkmatesOpenMailExternal(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'tel') {
                    await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (walkmatesIsBankScheme(uri) ||
                      ((scheme == 'http' || scheme == 'https') &&
                          walkmatesIsBankDomain(uri))) {
                    await walkmatesOpenBank(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme != 'http' && scheme != 'https') {
                    print(
                      'WERLOG: popup blocked non-http/https scheme=$scheme url=$uri',
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onCloseWindow: (controller) {
                  print('WERLOG: popup onCloseWindow');
                  _closePopup();
                },
                onLoadError: (controller, uri, code, message) async {
                  print(
                    'WERLOG: popup onLoadError url=$uri code=$code msg=$message',
                  );
                },
                onReceivedError: (controller, request, error) async {
                  print(
                    'WERLOG: popup onReceivedError '
                        'url=${request.url} '
                        'type=${error.type} '
                        'desc=${error.description}',
                  );
                },
                onReceivedHttpError:
                    (controller, request, errorResponse) async {
                  print(
                    'WERLOG: popup onReceivedHttpError '
                        'url=${request.url} '
                        'status=${errorResponse.statusCode} '
                        'reason=${errorResponse.reasonPhrase}',
                  );
                },
                onConsoleMessage: (controller, consoleMessage) {
                  print(
                    'WERLOG: popup console: '
                        '${consoleMessage.messageLevel} ${consoleMessage.message}',
                  );
                },
                onDownloadStartRequest: (controller, req) async {
                  print(
                      'WERLOG: popup download for url=${req.url}, opening external');
                  await walkmatesOpenExternal(req.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    walkmatesBindNotificationTap();

    final Color bgColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget webView = Stack(
      children: <Widget>[
        if (walkmatesCoverVisible)
          const Center(child: LoaderScreen())
        else
          Container(
            color: bgColor,
            child: Stack(
              children: <Widget>[
                InAppWebView(
                  key: ValueKey<int>(walkmatesWebViewKeyCounter),
                  initialSettings: _mainWebViewSettings(),
                  initialUrlRequest: URLRequest(
                    url: WebUri(walkmatesHomeUrl),
                  ),
                  onWebViewCreated:
                      (InAppWebViewController controller) async {
                    walkmatesWebViewController = controller;
                    _currentUrl = walkmatesHomeUrl;

                    walkmatesBosunInstance ??= WalkmatesBosunViewModel(
                      walkmatesDeviceProfileInstance:
                      walkmatesDeviceProfileInstance,
                      walkmatesAnalyticsSpyInstance:
                      walkmatesAnalyticsSpyInstance,
                    );

                    walkmatesCourier ??= WalkmatesCourierService(
                      walkmatesBosun: walkmatesBosunInstance!,
                      walkmatesGetWebViewController: () =>
                      walkmatesWebViewController,
                    );

                    try {
                      final ua = await controller.evaluateJavascript(
                        source: "navigator.userAgent",
                      );
                      if (ua is String && ua.trim().isNotEmpty) {
                        _baseUserAgent = ua.trim();
                        _currentUserAgent = _baseUserAgent!;
                        walkmatesDeviceProfileInstance.walkmatesBaseUserAgent =
                            _baseUserAgent;
                        WalkmatesLoggerService().walkmatesLogInfo(
                            'Initial WebView User-Agent: $_baseUserAgent');
                        print(
                            '[UA] INITIAL WEBVIEW USER AGENT: $_baseUserAgent');
                      }
                    } catch (e) {
                      WalkmatesLoggerService().walkmatesLogWarn(
                          'Failed to read navigator.userAgent on create: $e');
                    }

                    await _applyNormalUserAgentIfNeeded();

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupLocalStorageSetItem',
                      callback: (List<dynamic> args) async {
                        try {
                          if (args.isEmpty) return null;
                          final dynamic raw = args.first;
                          if (raw is Map) {
                            final String key =
                                raw['key']?.toString() ?? '';
                            final String value =
                                raw['value']?.toString() ?? '';
                            if (key.isNotEmpty) {
                              final SharedPreferences prefs =
                              await SharedPreferences.getInstance();
                              await prefs.setString(key, value);
                              WalkmatesLoggerService().walkmatesLogInfo(
                                  'NcupLocalStorageSetItem (main): saved key="$key" len=${value.length}');
                            }
                          }
                        } catch (e, st) {
                          WalkmatesLoggerService().walkmatesLogError(
                              'NcupLocalStorageSetItem main handler error: $e\n$st');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'onServerResponse',
                      callback: (List<dynamic> args) async {
                        if (args.isEmpty) return null;

                        print("Get Data server $args");

                        try {
                          dynamic first = args[0];

                          if (first is List && first.isNotEmpty) {
                            first = first.first;
                          }

                          final bool handled =
                          await _handleCheckoutAction(first);
                          if (handled) {}

                          if (first is Map) {
                            final Map<dynamic, dynamic> root = first;

                            if (root['savedata'] != null) {
                              walkmatesHandleServerSavedata(
                                  root['savedata'].toString());
                              await _handleCheckoutAction(root['savedata']);
                            }

                            _updateExtraDataFromServerPayload(root);
                            _updateSafeAreaFromServerPayload(root);
                            await _updateUserAgentFromServerPayload(root);

                            await _applyNormalUserAgentIfNeeded();

                            try {
                              if (!_loadedJsExecutedOnce) {
                                final dynamic adataRaw = root['adata'];
                                if (adataRaw is Map) {
                                  final Map adata = adataRaw;
                                  final dynamic loadedJsRaw =
                                  adata['loadedjs'];
                                  if (loadedJsRaw != null) {
                                    final String loadedJs =
                                    loadedJsRaw.toString().trim();
                                    if (loadedJs.isNotEmpty) {
                                      _pendingLoadedJs = loadedJs;
                                      WalkmatesLoggerService().walkmatesLogInfo(
                                        'loadedjs received, will execute ONCE after 6 seconds',
                                      );

                                      Future<void>.delayed(
                                        const Duration(seconds: 6),
                                            () async {
                                          if (!mounted) return;
                                          if (_loadedJsExecutedOnce) {
                                            WalkmatesLoggerService()
                                                .walkmatesLogInfo(
                                                'Skipping loadedjs: already executed once');
                                            return;
                                          }
                                          if (walkmatesWebViewController ==
                                              null) {
                                            WalkmatesLoggerService()
                                                .walkmatesLogWarn(
                                                'Skipping loadedjs execution: controller is null');
                                            return;
                                          }
                                          final String? jsToRun =
                                              _pendingLoadedJs;
                                          if (jsToRun == null ||
                                              jsToRun.isEmpty) {
                                            return;
                                          }
                                          WalkmatesLoggerService()
                                              .walkmatesLogInfo(
                                              'Executing loadedjs from server payload (ONCE, delayed 6s)');
                                          try {
                                            await walkmatesWebViewController
                                                ?.evaluateJavascript(
                                              source: jsToRun,
                                            );
                                            _loadedJsExecutedOnce = true;
                                          } catch (e, st) {
                                            WalkmatesLoggerService()
                                                .walkmatesLogError(
                                                'Error executing delayed loadedjs: $e\n$st');
                                          }
                                        },
                                      );
                                    }
                                  }
                                }
                              } else {
                                WalkmatesLoggerService().walkmatesLogInfo(
                                    'loadedjs ignored: already executed once earlier');
                              }
                            } catch (e, st) {
                              WalkmatesLoggerService().walkmatesLogError(
                                  'Error scheduling loadedjs: $e\n$st');
                            }
                          }
                        } catch (e, st) {
                          print('onServerResponse error: $e\n$st');
                        }

                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupCheckoutAction',
                      callback: (List<dynamic> args) async {
                        try {
                          print(
                              'WERLOG: MAIN NcupCheckoutAction args=$args');
                          if (args.isNotEmpty) {
                            await _handleCheckoutAction(args.first);
                          }
                        } catch (e) {
                          print(
                              'WERLOG: MAIN NcupCheckoutAction error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupJSLogger',
                      callback: (List<dynamic> args) {
                        try {
                          final dynamic payload =
                          args.isNotEmpty ? args.first : null;
                          print('WERLOG: MAIN JS error payload: $payload');
                        } catch (e) {
                          print('WERLOG: NcupJSLogger handler error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupPostMessage',
                      callback: (List<dynamic> args) async {
                        try {
                          print('WERLOG: MAIN NcupPostMessage args=$args');
                          if (args.isNotEmpty) {
                            final dynamic first = args.first;
                            if (first is Map && first['data'] != null) {
                              await _handleCheckoutAction(first['data']);
                            } else {
                              await _handleCheckoutAction(first);
                            }
                          }
                        } catch (e) {
                          print(
                              'WERLOG: NcupPostMessage handler error: $e');
                        }
                        return null;
                      },
                    );
                  },
                  onPermissionRequest: (controller, request) async {
                    return PermissionResponse(
                      resources: request.resources,
                      action: PermissionResponseAction.GRANT,
                    );
                  },
                  onLoadStart:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      walkmatesStartLoadTimestamp =
                          DateTime.now().millisecondsSinceEpoch;
                    });

                    final Uri? walkmatesViewUri = uri;
                    if (walkmatesViewUri != null) {
                      _currentUrl = walkmatesViewUri.toString();

                      await _switchUserAgentForUrl(walkmatesViewUri);

                      await _updateBackButtonVisibility();

                      if (walkmatesIsBareEmail(walkmatesViewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        final Uri walkmatesMailto =
                        walkmatesToMailto(walkmatesViewUri);
                        await walkmatesOpenMailExternal(walkmatesMailto);
                        return;
                      }

                      final String walkmatesScheme =
                      walkmatesViewUri.scheme.toLowerCase();

                      if (walkmatesScheme == 'mailto') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await walkmatesOpenMailExternal(walkmatesViewUri);
                        return;
                      }

                      if (walkmatesIsBankScheme(walkmatesViewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await walkmatesOpenBank(walkmatesViewUri);
                        return;
                      }

                      if (walkmatesScheme != 'http' &&
                          walkmatesScheme != 'https') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                      }
                    }
                  },
                  onLoadError: (
                      InAppWebViewController controller,
                      Uri? uri,
                      int code,
                      String message,
                      ) async {
                    final int walkmatesNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String walkmatesEvent =
                        'InAppWebViewError(code=$code, message=$message)';

                    await walkmatesPostStat(
                      event: walkmatesEvent,
                      timeStart: walkmatesNow,
                      timeFinish: walkmatesNow,
                      url: uri?.toString() ?? '',
                      appSid:
                      walkmatesAnalyticsSpyInstance.walkmatesAppsFlyerUid,
                      firstPageLoadTs: walkmatesFirstPageTimestamp,
                    );
                  },
                  onReceivedError: (
                      InAppWebViewController controller,
                      WebResourceRequest request,
                      WebResourceError error,
                      ) async {
                    final int walkmatesNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String walkmatesDescription =
                    (error.description ?? '').toString();
                    final String walkmatesEvent =
                        'WebResourceError(code=$error, message=$walkmatesDescription)';

                    await walkmatesPostStat(
                      event: walkmatesEvent,
                      timeStart: walkmatesNow,
                      timeFinish: walkmatesNow,
                      url: request.url?.toString() ?? '',
                      appSid:
                      walkmatesAnalyticsSpyInstance.walkmatesAppsFlyerUid,
                      firstPageLoadTs: walkmatesFirstPageTimestamp,
                    );
                  },
                  onLoadStop:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      walkmatesCurrentUrl = uri.toString();
                      _currentUrl = walkmatesCurrentUrl;
                    });

                    if (uri != null) {
                      await _switchUserAgentForUrl(uri);
                    }

                    if (!_isAboutBlankUri(uri)) {
                      _scheduleSafeInstall(controller, label: 'parent');
                    }

                    await debugPrintCurrentUserAgent();

                    await _sendAllDataToPageTwice();
                    await _updateBackButtonVisibility();

                    Future<void>.delayed(
                      const Duration(seconds: 20),
                          () {
                        walkmatesSendLoadedOnce(
                          url: walkmatesCurrentUrl.toString(),
                          timestart: walkmatesStartLoadTimestamp,
                        );
                      },
                    );
                  },
                  onUpdateVisitedHistory:
                      (controller, url, isReload) async {
                    if (url != null && !_isAboutBlankUri(url)) {
                      _currentUrl = url.toString();
                      await _updateBackButtonVisibility();
                      await _switchUserAgentForUrl(url);
                    }
                  },
                  shouldOverrideUrlLoading:
                      (InAppWebViewController controller,
                      NavigationAction action) async {
                    final Uri? walkmatesUri = action.request.url;
                    if (walkmatesUri == null) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    _currentUrl = walkmatesUri.toString();
                    await _updateBackButtonVisibility();

                    if (_isAboutBlankUri(walkmatesUri)) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    if (_isGoogleUrl(walkmatesUri)) {
                      _isCurrentlyOnGoogle = true;
                      await _applyGoogleUserAgent();
                      return NavigationActionPolicy.ALLOW;
                    } else {
                      if (_isCurrentlyOnGoogle) {
                        _isCurrentlyOnGoogle = false;
                      }
                      await _applyNormalUserAgentIfNeeded();
                    }

                    if (walkmatesIsBareEmail(walkmatesUri)) {
                      final Uri walkmatesMailto =
                      walkmatesToMailto(walkmatesUri);
                      await walkmatesOpenMailExternal(walkmatesMailto);
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String walkmatesScheme =
                    walkmatesUri.scheme.toLowerCase();

                    if (walkmatesScheme == 'mailto') {
                      await walkmatesOpenMailExternal(walkmatesUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (walkmatesIsBankScheme(walkmatesUri)) {
                      await walkmatesOpenBank(walkmatesUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if ((walkmatesScheme == 'http' ||
                        walkmatesScheme == 'https') &&
                        walkmatesIsBankDomain(walkmatesUri)) {
                      await walkmatesOpenBank(walkmatesUri);

                      if (_isAdobeRedirect(walkmatesUri)) {
                        if (context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  AdobeRedirectScreen(uri: walkmatesUri),
                            ),
                          );
                        }
                        return NavigationActionPolicy.CANCEL;
                      }
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (walkmatesScheme == 'tel') {
                      await launchUrl(
                        walkmatesUri,
                        mode: LaunchMode.externalApplication,
                      );
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String host = walkmatesUri.host.toLowerCase();
                    final bool walkmatesIsSocial =
                        host.endsWith('facebook.com') ||
                            host.endsWith('instagram.com') ||
                            host.endsWith('twitter.com') ||
                            host.endsWith('x.com');

                    if (walkmatesIsSocial) {
                      await walkmatesOpenExternal(walkmatesUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (walkmatesIsPlatformLink(walkmatesUri)) {
                      final Uri walkmatesWebUri =
                      walkmatesHttpizePlatformUri(walkmatesUri);
                      await walkmatesOpenExternal(walkmatesWebUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (walkmatesScheme != 'http' &&
                        walkmatesScheme != 'https') {
                      return NavigationActionPolicy.CANCEL;
                    }

                    return NavigationActionPolicy.ALLOW;
                  },
                  onCreateWindow: _onCreateWindowHandler,
                  onCloseWindow: (controller) {
                    print('WERLOG: MAIN onCloseWindow');
                  },
                  onDownloadStartRequest: (
                      InAppWebViewController controller,
                      DownloadStartRequest req,
                      ) async {
                    await walkmatesOpenExternal(req.url);
                  },
                  onConsoleMessage: (controller, consoleMessage) {
                    print(
                      'WERLOG: MAIN console: '
                          '${consoleMessage.messageLevel} ${consoleMessage.message}',
                    );
                  },
                ),
                Visibility(
                  visible: !walkmatesVeilVisible,
                  child: const Center(child: LoaderScreen()),
                ),
                if (_isPopupVisible &&
                    (_popupUrl != null || _popupCreateAction != null))
                  _buildPopupWebView(),
              ],
            ),
          ),
      ],
    );

    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool whitelistMatch =
        (!_isPopupVisible && _showBackButton) || popupInWhitelist;

    final bool shouldShowTopBackBar =
        whitelistMatch && !_backButtonHiddenAfterTap;

    final Color topBarColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget topBackBar = shouldShowTopBackBar
        ? Container(
      color: topBarColor,
      padding: const EdgeInsets.only(left: 4, right: 4),
      height: 48,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _handleBackButtonPressed,
          ),
        ],
      ),
    )
        : const SizedBox.shrink();

    final Widget fullScreen = Column(
      children: [
        topBackBar,
        Expanded(child: webView),
      ],
    );

    final Widget body = _safeAreaEnabled
        ? SafeArea(
      child: fullScreen,
    )
        : fullScreen;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: bgColor,
        body: SizedBox.expand(
          child: ColoredBox(
            color: bgColor,
            child: body,
          ),
        ),
      ),
    );
  }

  bool _isAdobeRedirect(Uri uri) {
    final String host = uri.host.toLowerCase();
    return host == 'c00.adobe.com';
  }
}

// ---------------------- Экран для c00.adobe.com ----------------------

class AdobeRedirectScreen extends StatelessWidget {
  final Uri uri;

  const AdobeRedirectScreen({super.key, required this.uri});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF111111),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Go to the App Store and download the app.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                ),
              ),
              SizedBox(height: 24),
              SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// main()
// ============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(walkmatesFcmBackgroundHandler);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  tz_data.initializeTimeZones();

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WalkmatesHall(),
    ),
  );
}