import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

typedef OnNotificationCallback = void Function(
  String uuid,
  String sender,
  String body,
  int timestamp,
);

typedef OnGoogleSignInCallback = void Function(String uuid, String url);

class IsolatedWebViewWidget extends StatefulWidget {
  final String uuid;
  final String customName;
  final bool mobileMode;
  final OnNotificationCallback onNotificationReceived;
  final OnGoogleSignInCallback? onGoogleSignInAttempted;
  final void Function(IsolatedWebViewController controller)? onControllerCreated;

  const IsolatedWebViewWidget({
    super.key,
    required this.uuid,
    required this.customName,
    this.mobileMode = true,
    required this.onNotificationReceived,
    this.onGoogleSignInAttempted,
    this.onControllerCreated,
  });

  @override
  State<IsolatedWebViewWidget> createState() => _IsolatedWebViewWidgetState();
}

class _IsolatedWebViewWidgetState extends State<IsolatedWebViewWidget> {
  IsolatedWebViewController? _controller;

  @override
  Widget build(BuildContext context) {
    const String viewType = 'isolated_web_view';
    final Map<String, dynamic> creationParams = <String, dynamic>{
      'uuid': widget.uuid,
      'customName': widget.customName,
      'url': 'https://messages.google.com/web',
      'mobileMode': widget.mobileMode,
    };

    return PlatformViewLink(
      viewType: viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(
              EagerGestureRecognizer.new,
            ),
          },
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        );
      },
      onCreatePlatformView: (params) {
        final AndroidViewController viewController =
            PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: viewType,
          layoutDirection: Directionality.of(context),
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () {
            params.onFocusChanged(true);
          },
        );

        viewController.addOnPlatformViewCreatedListener((int id) {
          params.onPlatformViewCreated(id);
          final controller = IsolatedWebViewController(
            id: id,
            uuid: widget.uuid,
            onNotificationReceived: widget.onNotificationReceived,
            onGoogleSignInAttempted: widget.onGoogleSignInAttempted,
          );
          _controller = controller;
          widget.onControllerCreated?.call(controller);
        });

        viewController.create();
        return viewController;
      },
    );
  }

  @override
  void didUpdateWidget(covariant IsolatedWebViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mobileMode != widget.mobileMode && _controller != null) {
      _controller!.setMobileMode(widget.mobileMode);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}

class IsolatedWebViewController {
  final int id;
  final String uuid;
  final OnNotificationCallback onNotificationReceived;
  final OnGoogleSignInCallback? onGoogleSignInAttempted;
  late final MethodChannel _channel;

  IsolatedWebViewController({
    required this.id,
    required this.uuid,
    required this.onNotificationReceived,
    this.onGoogleSignInAttempted,
  }) {
    _channel = MethodChannel('com.multimessenger.hub/webview_$id');
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onNotificationReceived':
        final Map<dynamic, dynamic>? args =
            call.arguments as Map<dynamic, dynamic>?;
        if (args != null) {
          final String notifUuid = args['uuid'] as String? ?? uuid;
          final String payload = args['payload'] as String? ?? '{}';
          try {
            final data = json.decode(payload) as Map<String, dynamic>;
            final String sender = data['sender'] as String? ?? 'New Message';
            final String body = data['body'] as String? ?? '';
            final int timestamp = (data['timestamp'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch;
            onNotificationReceived(notifUuid, sender, body, timestamp);
          } catch (e) {
            debugPrint('Failed to parse notification payload: $e');
          }
        }
        break;
      case 'onGoogleSignInAttempted':
        final Map<dynamic, dynamic>? args =
            call.arguments as Map<dynamic, dynamic>?;
        final String targetUrl = args?['url'] as String? ?? '';
        onGoogleSignInAttempted?.call(uuid, targetUrl);
        break;
      case 'onPageFinished':
        debugPrint('WebView [$uuid] loaded: ${call.arguments}');
        break;
    }
  }

  Future<void> reload() async {
    await _channel.invokeMethod('reload');
  }

  Future<void> loadUrl(String url) async {
    await _channel.invokeMethod('loadUrl', {'url': url});
  }

  Future<void> setMobileMode(bool enable) async {
    await _channel.invokeMethod('setMobileMode', {'enable': enable});
  }

  Future<void> zoomIn() async {
    await _channel.invokeMethod('zoomIn');
  }

  Future<void> zoomOut() async {
    await _channel.invokeMethod('zoomOut');
  }

  Future<void> resume() async {
    await _channel.invokeMethod('resume');
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
