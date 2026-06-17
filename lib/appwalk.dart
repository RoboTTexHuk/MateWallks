import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'loaderwalk.dart';

class OceanCalendarHelpLite extends StatefulWidget {
  const OceanCalendarHelpLite({super.key});

  @override
  State<OceanCalendarHelpLite> createState() =>
      _OceanCalendarHelpLiteState();
}

class _OceanCalendarHelpLiteState extends State<OceanCalendarHelpLite> {
  InAppWebViewController? oceanWebViewController;
  bool oceanIsLoading = true;

  Future<bool> _handleWebViewBackNavigation() async {
    if (oceanWebViewController == null) return false;
    try {
      final bool canNavigateBack = await oceanWebViewController!.canGoBack();
      if (canNavigateBack) {
        await oceanWebViewController!.goBack();
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        final bool backHandled = await _handleWebViewBackNavigation();
        return backHandled ? false : false;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
    
        body: Stack(
          children: <Widget>[
            SafeArea(
              child: InAppWebView(
                initialFile: 'assets/Challengemate.html',
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  supportZoom: false,
                  disableHorizontalScroll: false,
                  disableVerticalScroll: false,
                  transparentBackground: true,
                  mediaPlaybackRequiresUserGesture: false,
                  disableDefaultErrorPage: true,
                  allowsInlineMediaPlayback: true,
                  allowsPictureInPictureMediaPlayback: true,
                  useOnDownloadStart: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                ),
                onWebViewCreated:
                    (InAppWebViewController webViewController) {
                  oceanWebViewController = webViewController;
                },
                onLoadStart: (
                    InAppWebViewController controller,
                    Uri? url,
                    ) =>
                    setState(() => oceanIsLoading = true),
                onLoadStop: (
                    InAppWebViewController controller,
                    Uri? url,
                    ) async =>
                    setState(() => oceanIsLoading = false),
                onLoadError: (
                    InAppWebViewController controller,
                    Uri? url,
                    int code,
                    String message,
                    ) =>
                    setState(() => oceanIsLoading = false),
              ),
            ),

            // Лоадер с пальмой по центру экрана
            if (oceanIsLoading)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black87,
                  child: Center(
                    child: LoaderScreen(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

