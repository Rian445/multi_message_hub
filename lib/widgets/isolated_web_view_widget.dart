import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'app_lottie_view.dart';

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
  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;

  void _onControllerStateChanged() {
    if (!mounted || _controller == null) return;
    final newLoading = _controller!.isLoading.value;
    final newError = _controller!.hasError.value;
    final newErrorMsg = _controller!.errorMessage.value;

    if (newLoading != _isLoading ||
        newError != _hasError ||
        newErrorMsg != _errorMessage) {
      setState(() {
        _isLoading = newLoading;
        _hasError = newError;
        _errorMessage = newErrorMsg;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const String viewType = 'isolated_web_view';
    final Map<String, dynamic> creationParams = <String, dynamic>{
      'uuid': widget.uuid,
      'customName': widget.customName,
      'url': 'https://messages.google.com/web',
      'mobileMode': widget.mobileMode,
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        PlatformViewLink(
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
              controller.isLoading.addListener(_onControllerStateChanged);
              controller.hasError.addListener(_onControllerStateChanged);
              controller.errorMessage.addListener(_onControllerStateChanged);
              widget.onControllerCreated?.call(controller);
            });

            viewController.create();
            return viewController;
          },
        ),

        // Connection failed or device offline overlay
        if (_hasError)
          ProfileConnectionFailedOverlay(
            profileName: widget.customName,
            errorMessage: _errorMessage,
            onRetry: () {
              _controller?.reload();
            },
          )
        // Loading animation overlay (app launch, profile fetch, or refreshing)
        else if (_isLoading)
          ProfileLoadingOverlay(
            profileName: widget.customName,
          ),
      ],
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
    _controller?.isLoading.removeListener(_onControllerStateChanged);
    _controller?.hasError.removeListener(_onControllerStateChanged);
    _controller?.errorMessage.removeListener(_onControllerStateChanged);
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

  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(true);
  final ValueNotifier<bool> hasError = ValueNotifier<bool>(false);
  final ValueNotifier<String?> errorMessage = ValueNotifier<String?>(null);

  Timer? _loadTimeoutTimer;

  IsolatedWebViewController({
    required this.id,
    required this.uuid,
    required this.onNotificationReceived,
    this.onGoogleSignInAttempted,
  }) {
    _channel = MethodChannel('com.multimessenger.hub/webview_$id');
    _channel.setMethodCallHandler(_handleMethodCall);
    _startTimeoutTimer();
  }

  void _startTimeoutTimer() {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = Timer(const Duration(seconds: 25), () {
      if (isLoading.value && !hasError.value) {
        isLoading.value = false;
        hasError.value = true;
        errorMessage.value =
            'Connection timed out. Unable to reach Google Messages. Please check your internet connection.';
      }
    });
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onPageStarted':
        isLoading.value = true;
        hasError.value = false;
        errorMessage.value = null;
        _startTimeoutTimer();
        break;

      case 'onPageFinished':
        _loadTimeoutTimer?.cancel();
        // Give a 600ms grace period so Angular/Web components mount smoothly without flicker
        Future.delayed(const Duration(milliseconds: 600), () {
          if (!hasError.value) {
            isLoading.value = false;
          }
        });
        break;

      case 'onReceivedError':
        _loadTimeoutTimer?.cancel();
        final Map<dynamic, dynamic>? args =
            call.arguments as Map<dynamic, dynamic>?;
        final String desc =
            args?['description'] as String? ?? 'Connection failed';
        isLoading.value = false;
        hasError.value = true;
        errorMessage.value =
            'Cannot connect to Google Messages ($desc). Please check your internet or paired device.';
        break;

      case 'onConnectionStatus':
        final Map<dynamic, dynamic>? args =
            call.arguments as Map<dynamic, dynamic>?;
        final bool isOnline = args?['isOnline'] as bool? ?? true;
        final String reason = args?['reason'] as String? ?? '';
        if (!isOnline) {
          _loadTimeoutTimer?.cancel();
          isLoading.value = false;
          hasError.value = true;
          errorMessage.value = reason.isNotEmpty
              ? reason
              : 'Device is offline. Check your internet connection.';
        } else {
          // If connection is restored while in error state, automatically reload
          if (hasError.value) {
            reload();
          }
        }
        break;

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
    }
  }

  Future<void> reload() async {
    isLoading.value = true;
    hasError.value = false;
    errorMessage.value = null;
    _startTimeoutTimer();
    await _channel.invokeMethod('reload');
  }

  Future<void> loadUrl(String url) async {
    isLoading.value = true;
    hasError.value = false;
    errorMessage.value = null;
    _startTimeoutTimer();
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
    _loadTimeoutTimer?.cancel();
    _channel.setMethodCallHandler(null);
  }
}
