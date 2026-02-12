import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

class VocaPlayerController {
  Future<void> Function()? _playDelegate;

  Future<void> play() async {
    final delegate = _playDelegate;
    if (delegate == null) {
      throw StateError('VocaPlayerController is not attached to a VocaPlayer.');
    }
    await delegate();
  }

  void _attach({
    required Future<void> Function() playDelegate,
  }) {
    _playDelegate = playDelegate;
  }

  void _detach() {
    _playDelegate = null;
  }
}

class VocaPlayer extends StatefulWidget {
  const VocaPlayer({
    super.key,
    this.controller,
    this.appId,
    required this.videoId,
    required this.startSeconds,
    required this.endSeconds,
    this.hideLogo = false,
    this.hideAdvice = false,
    this.showControls = true,
    this.timerCount = 0,
    this.visualStartOffsetSeconds = 0.8,
    this.visualRevealExtraSeconds = 0.6,
    this.endHoldBackSeconds = 0.75,
    this.onReadyToPlay,
    this.onPlaybackStarted,
    this.onReplayAvailable,
    this.onTimerCompleted,
  })  : assert(startSeconds >= 0),
        assert(endSeconds > startSeconds),
        assert(visualStartOffsetSeconds >= 0),
        assert(visualRevealExtraSeconds >= 0),
        assert(endHoldBackSeconds >= 0);

  final VocaPlayerController? controller;

  /// Optional absolute origin URL used for iframe `origin` and `widget_referrer`.
  ///
  /// Examples:
  /// - `https://example.com`
  /// - `http://localhost:8080`
  ///
  /// If null/empty or not a valid absolute `http(s)` origin URL,
  /// `https://localhost` is used.
  final String? appId;

  /// YouTube video id (for example: `E0BY209ZNEY`).
  final String videoId;

  /// Clip start position in seconds.
  final double startSeconds;

  /// Clip end position in seconds.
  final double endSeconds;

  /// Enables internal crop/mask rules that reduce YouTube logo/title visibility.
  final bool hideLogo;

  /// Prevents end-screen suggestions by stopping playback near clip end.
  final bool hideAdvice;

  /// Enables custom control overlay (play, volume, menu, replay UI).
  final bool showControls;

  /// End countdown start value (seconds).
  ///
  /// If `> 0`, countdown starts when video reaches end-state.
  /// If `<= 0`, countdown is disabled.
  final int timerCount;

  /// Offset added to clip start when deciding first visual readiness threshold.
  final double visualStartOffsetSeconds;

  /// Extra seconds added to visual readiness threshold logic.
  final double visualRevealExtraSeconds;

  /// How far before clip end playback is paused for end-hold behavior.
  final double endHoldBackSeconds;

  /// Called once when player becomes ready to start playback.
  final VoidCallback? onReadyToPlay;

  /// Called when the first visual frame is considered started.
  final VoidCallback? onPlaybackStarted;

  /// Called when replay becomes available at clip end-hold pause state.
  final VoidCallback? onReplayAvailable;

  /// Called when end countdown reaches zero.
  final VoidCallback? onTimerCompleted;

  @override
  State<VocaPlayer> createState() => VocaPlayerState();
}

class VocaPlayerState extends State<VocaPlayer> {
  static const String _debugKey = 'VOCA_DEBUG';
  static const String _watchOnYoutubeTitle = 'Watch on Youtube';
  static const _UiPreset _uiDefault = _UiPreset(
    maskTopPx: 0,
    maskBottomPx: 0,
    maskBottomRightWidthPx: 0,
    maskBottomRightHeightPx: 0,
    overflowScale: 1.0,
    overflowShiftYpx: 0,
  );
  static const _UiPreset _uiHideLogo = _UiPreset(
    maskTopPx: 0,
    maskBottomPx: 12,
    maskBottomRightWidthPx: 0,
    maskBottomRightHeightPx: 0,
    overflowScale: 1.44,
    overflowShiftYpx: 12,
  );

  late final WebViewController _controller;
  Completer<void> _readyCompleter = Completer<void>();
  bool _readyNotified = false;
  bool _playbackStartedNotified = false;
  bool _replayAvailableNotified = false;
  bool _isPlayerVisible = false;
  int _reloadToken = 0;

  String get _appOrigin {
    final raw = widget.appId?.trim() ?? '';
    if (raw.isEmpty) return 'https://localhost';

    final uri = Uri.tryParse(raw);
    final parsed = uri;
    final isHttpScheme =
        parsed != null && (parsed.scheme == 'https' || parsed.scheme == 'http');
    if (isHttpScheme && parsed.host.isNotEmpty) {
      final hasNonDefaultPort = parsed.hasPort &&
          !((parsed.scheme == 'https' && parsed.port == 443) ||
              (parsed.scheme == 'http' && parsed.port == 80));
      final portPart = hasNonDefaultPort ? ':${parsed.port}' : '';
      return '${parsed.scheme}://${parsed.host}$portPart';
    }

    return 'https://localhost';
  }

  _UiPreset get _ui => widget.hideLogo ? _uiHideLogo : _uiDefault;

  @override
  void initState() {
    super.initState();
    _attachController();
    _debug(
      'init appId=${widget.appId ?? '(auto)'} origin=$_appOrigin '
      'videoId=${widget.videoId} '
      'start=${widget.startSeconds} end=${widget.endSeconds} '
      'visualStartOffset=${widget.visualStartOffsetSeconds} '
      'visualRevealExtra=${widget.visualRevealExtraSeconds} '
      'endHoldBack=${widget.endHoldBackSeconds} '
      'hideLogo=${widget.hideLogo} hideAdvice=${widget.hideAdvice} '
      'showControls=${widget.showControls} timerCount=${widget.timerCount}',
    );

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => _debug('page_started url=$url'),
          onPageFinished: (url) => _debug('page_finished url=$url'),
          onWebResourceError: (error) {
            _debug(
              'web_error '
              'type=${error.errorType} '
              'code=${error.errorCode} '
              'desc=${error.description} '
              'url=${error.url}',
            );
          },
        ),
      )
      ..addJavaScriptChannel('VocaLog', onMessageReceived: _onJsMessage)
      ..addJavaScriptChannel('VocaAction', onMessageReceived: _onJsAction)
      ..loadHtmlString(_buildHtml(), baseUrl: _appOrigin);

    final platformController = _controller.platform;
    if (platformController is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(kDebugMode);
      platformController.setMediaPlaybackRequiresUserGesture(false);
      _debug('android_webview_configured gesture=false');
    }

    _logUiInitialState();
  }

  @override
  void didUpdateWidget(covariant VocaPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach();
      _attachController();
    }

    final hardReloadNeeded =
        oldWidget.appId != widget.appId || oldWidget.videoId != widget.videoId;
    if (hardReloadNeeded) {
      _readyNotified = false;
      _playbackStartedNotified = false;
      _replayAvailableNotified = false;
      _isPlayerVisible = false;
      _readyCompleter = Completer<void>();
      _debug(
        'hard_reload '
        'appId:${oldWidget.appId}->${widget.appId} '
        'videoId:${oldWidget.videoId}->${widget.videoId}',
      );
      _logUiInitialState();
      unawaited(_reloadHtmlWithDispose());
      return;
    }

    final configChanged = oldWidget.hideLogo != widget.hideLogo ||
        oldWidget.hideAdvice != widget.hideAdvice ||
        oldWidget.showControls != widget.showControls ||
        oldWidget.timerCount != widget.timerCount;
    final clipChanged = oldWidget.startSeconds != widget.startSeconds ||
        oldWidget.endSeconds != widget.endSeconds ||
        oldWidget.visualStartOffsetSeconds != widget.visualStartOffsetSeconds ||
        oldWidget.visualRevealExtraSeconds != widget.visualRevealExtraSeconds ||
        oldWidget.endHoldBackSeconds != widget.endHoldBackSeconds;
    if (!configChanged && !clipChanged) return;

    _debug(
      'soft_update '
      'hideLogo:${oldWidget.hideLogo}->${widget.hideLogo} '
      'hideAdvice:${oldWidget.hideAdvice}->${widget.hideAdvice} '
      'showControls:${oldWidget.showControls}->${widget.showControls} '
      'timerCount:${oldWidget.timerCount}->${widget.timerCount} '
      'start:${oldWidget.startSeconds}->${widget.startSeconds} '
      'end:${oldWidget.endSeconds}->${widget.endSeconds} '
      'visualStartOffset:${oldWidget.visualStartOffsetSeconds}->${widget.visualStartOffsetSeconds} '
      'visualRevealExtra:${oldWidget.visualRevealExtraSeconds}->${widget.visualRevealExtraSeconds} '
      'endHoldBack:${oldWidget.endHoldBackSeconds}->${widget.endHoldBackSeconds}',
    );
    if (clipChanged) {
      // Keep the player visible for snappy UX, but allow next visual-ready callback.
      _playbackStartedNotified = false;
      _resetReplayAvailableNotification('clip_changed');
      _debug('soft_update clip_changed -> playback_started_notify_reset');
    }
    unawaited(
      _applySoftUpdate(configChanged: configChanged, clipChanged: clipChanged),
    );
  }

  Future<void> _reloadHtmlWithDispose() async {
    final token = ++_reloadToken;
    await _disposeWebContext();
    if (!mounted || token != _reloadToken) return;
    await _controller.loadHtmlString(_buildHtml(), baseUrl: _appOrigin);
  }

  Future<void> _disposeWebContext() async {
    try {
      await _controller.runJavaScript(
        'window.__vocaDispose && window.__vocaDispose();',
      );
      _debug('web_dispose_called');
    } catch (e) {
      // Best-effort cleanup: continue reload even if current context is gone.
      _debug('web_dispose_error $e');
    }
  }

  Future<void> _applySoftUpdate({
    required bool configChanged,
    required bool clipChanged,
  }) async {
    if (configChanged) {
      await _sendConfigUpdate();
    }
    if (clipChanged) {
      await _sendClipUpdate();
    }
  }

  Future<void> _sendConfigUpdate() async {
    final ui = _ui;
    final payload = <String, Object>{
      'showControls': widget.showControls,
      'hideAdvice': widget.hideAdvice,
      'hideLogo': widget.hideLogo,
      'timerCount': widget.timerCount < 0 ? 0 : widget.timerCount,
      'watchOnYoutubeTitle': _watchOnYoutubeTitle,
      'maskTopPx': ui.maskTopPx,
      'maskBottomPx': ui.maskBottomPx,
      'maskBottomRightWidthPx': ui.maskBottomRightWidthPx,
      'maskBottomRightHeightPx': ui.maskBottomRightHeightPx,
      'overflowScale': ui.overflowScale,
      'overflowShiftYpx': ui.overflowShiftYpx,
    };
    await _runJsBestEffort(
      'window.vocaUpdateConfig && window.vocaUpdateConfig(${jsonEncode(payload)});',
      label: 'config_update_js',
    );
  }

  Future<void> _sendClipUpdate() async {
    final rawStart = widget.startSeconds;
    final rawEnd = widget.endSeconds;
    var safeStart = rawStart;
    if (!safeStart.isFinite || safeStart < 0) {
      safeStart = 0;
    }
    var safeEnd = rawEnd;
    if (!safeEnd.isFinite || safeEnd <= safeStart) {
      safeEnd = safeStart + 1;
    }
    final payload = <String, Object>{
      'startSec': safeStart,
      'playerStartSec': safeStart.floor(),
      'visualStartSec': safeStart + widget.visualStartOffsetSeconds,
      'endSec': safeEnd,
      'visualRevealExtraSec': widget.visualRevealExtraSeconds,
      'endHoldBackSec': widget.endHoldBackSeconds,
    };
    await _runJsBestEffort(
      'window.vocaUpdateClip && window.vocaUpdateClip(${jsonEncode(payload)});',
      label: 'clip_update_js',
    );
  }

  Future<void> _runJsBestEffort(String script, {required String label}) async {
    try {
      await _controller.runJavaScript(script);
      _debug('$label=ok');
    } catch (e) {
      _debug('$label=error $e');
    }
  }

  Future<void> play() async {
    _debug('play_requested');
    _resetReplayAvailableNotification('play_requested');
    try {
      await _readyCompleter.future.timeout(const Duration(seconds: 4));
      await _controller.runJavaScript('window.vocaPlay && window.vocaPlay();');
      _debug('play_command_sent');
    } catch (e) {
      _debug('play_error $e');
      try {
        await _controller
            .runJavaScript('window.vocaPlay && window.vocaPlay();');
      } catch (_) {}
      rethrow;
    }
  }

  void _onJsMessage(JavaScriptMessage message) {
    final msg = message.message;
    _debug('js $msg');

    try {
      final decoded = jsonDecode(msg);
      if (decoded is Map<String, dynamic>) {
        final type = decoded['type']?.toString() ?? '';
        final reason = decoded['reason']?.toString() ?? '';
        if (type == 'ready') {
          _notifyReady(reason.isEmpty ? msg : reason);
          return;
        }
        if (type == 'visual_ready') {
          _notifyPlaybackStarted(reason.isEmpty ? msg : reason);
          return;
        }
        if (type == 'replay_available') {
          _notifyReplayAvailable(reason.isEmpty ? msg : reason);
          return;
        }
        if (type == 'replay_cycle_started') {
          _resetReplayAvailableNotification(reason.isEmpty ? msg : reason);
          return;
        }
        if (type == 'end_timer_done') {
          _debug('timer_completed reason=${reason.isEmpty ? msg : reason}');
          widget.onTimerCompleted?.call();
          return;
        }
      }
    } catch (_) {
      // Backward-compatible fallback for plain string log/event messages.
    }

    if (msg.startsWith('READY_TO_PLAY|')) {
      _notifyReady(msg);
      return;
    }

    if (msg.startsWith('VISUAL_READY|')) {
      _notifyPlaybackStarted(msg);
      return;
    }

    if (msg.startsWith('END_TIMER_DONE|')) {
      _debug('timer_completed reason=$msg');
      widget.onTimerCompleted?.call();
    }
  }

  Future<void> _onJsAction(JavaScriptMessage message) async {
    final msg = message.message;
    _debug('js_action $msg');

    const prefix = 'OPEN_EXTERNAL|';
    if (!msg.startsWith(prefix)) return;

    final rawUrl = msg.substring(prefix.length).trim();
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      _debug('open_external_invalid_url $rawUrl');
      return;
    }

    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      _debug('open_external_result url=$rawUrl ok=$ok');
    } catch (e) {
      _debug('open_external_error url=$rawUrl err=$e');
    }
  }

  void _notifyReady(String reason) {
    if (_readyNotified) return;
    _readyNotified = true;
    _debug('ready_to_play reason=$reason');
    _debug('player_state=READY');
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
    widget.onReadyToPlay?.call();
  }

  void _notifyPlaybackStarted(String reason) {
    if (_playbackStartedNotified) return;
    _playbackStartedNotified = true;
    _debug('first_frame_started reason=$reason');
    if (!_isPlayerVisible) {
      setState(() {
        _isPlayerVisible = true;
      });
      _debug('player_visibility=VISIBLE');
    }
    _debug('first_frame_reveal_callback_fired');
    widget.onPlaybackStarted?.call();
  }

  void _notifyReplayAvailable(String reason) {
    if (_replayAvailableNotified) return;
    _replayAvailableNotified = true;
    _debug('replay_available reason=$reason');
    widget.onReplayAvailable?.call();
  }

  void _resetReplayAvailableNotification(String reason) {
    if (!_replayAvailableNotified) return;
    _replayAvailableNotified = false;
    _debug('replay_available_reset reason=$reason');
  }

  void _debug(String message) {
    debugPrint('$_debugKey: PLAYER | $message');
  }

  void _logUiInitialState() {
    _debug('player_visibility=HIDDEN');
    _debug('player_state=PREPARING');
  }

  void _attachController() {
    widget.controller?._attach(playDelegate: play);
  }

  @override
  void dispose() {
    widget.controller?._detach();
    unawaited(_disposeWebContext());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          WebViewWidget(controller: _controller),
          if (!_isPlayerVisible) const ColoredBox(color: Colors.black),
        ],
      ),
    );
  }

  String _buildHtml() {
    final ui = _ui;
    final preventYoutubeEndScreen = widget.hideAdvice;
    final appOrigin = _appOrigin.replaceAll("'", r"\'");
    final videoId = widget.videoId.replaceAll("'", r"\'");
    final watchOnYoutubeTitle = _watchOnYoutubeTitle.replaceAll("'", r"\'");
    final rawStart = widget.startSeconds;
    final rawEnd = widget.endSeconds;
    var safeStart = rawStart;
    if (!safeStart.isFinite || safeStart < 0) {
      safeStart = 0;
    }
    var safeEnd = rawEnd;
    if (!safeEnd.isFinite || safeEnd <= safeStart) {
      safeEnd = safeStart + 1;
    }
    if (safeStart != rawStart || safeEnd != rawEnd) {
      _debug(
        'clip_guard_applied '
        'rawStart=$rawStart rawEnd=$rawEnd '
        'safeStart=$safeStart safeEnd=$safeEnd',
      );
    }
    final start = safeStart;
    final playerStart = safeStart.floor();
    final visualStart = safeStart + widget.visualStartOffsetSeconds;
    final end = safeEnd;
    final timerCount = widget.timerCount < 0 ? 0 : widget.timerCount;

    return '''
<!doctype html>
<html>
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="referrer" content="strict-origin-when-cross-origin">
    <link rel="icon" href="data:,">
    <style>
      html, body {
        margin: 0;
        padding: 0;
        width: 100%;
        height: 100%;
        background: #000;
      }
      #viewport {
        position: relative;
        width: 100%;
        height: 100%;
        overflow: hidden;
        background: #000;
      }
      #player {
        position: absolute;
        left: 50%;
        top: calc(50% - ${ui.overflowShiftYpx}px);
        width: 100%;
        height: 100%;
        transform: translate(-50%, -50%) scale(${ui.overflowScale});
        transform-origin: center center;
      }
      #player iframe {
        position: absolute;
        left: 0;
        top: 0;
        width: 100%;
        height: 100%;
        border: 0;
      }
      #maskTop, #maskBottom, #maskBottomRight {
        position: absolute;
        background: #000;
        z-index: 9999;
        pointer-events: none;
      }
      #maskTop {
        left: 0;
        top: 0;
        width: 100%;
        height: ${ui.maskTopPx}px;
      }
      #maskBottom {
        left: 0;
        bottom: 0;
        width: 100%;
        height: ${ui.maskBottomPx}px;
      }
      #maskBottomRight {
        right: 0;
        bottom: 0;
        width: ${ui.maskBottomRightWidthPx}px;
        height: ${ui.maskBottomRightHeightPx}px;
      }
      #tapBlocker {
        position: absolute;
        left: 0;
        top: 0;
        width: 100%;
        height: 100%;
        z-index: 8000;
        background: transparent;
        cursor: pointer;
      }
      #customControls {
        opacity: 0;
        position: absolute;
        left: 0;
        right: 0;
        bottom: 0;
        height: 54px;
        z-index: 8200;
        display: block;
        padding: 8px 12px;
        border-radius: 0;
        background: rgba(0, 0, 0, 0.55);
        box-sizing: border-box;
        pointer-events: none;
        transform: translateY(6px);
        transition: opacity 160ms ease, transform 160ms ease;
      }
      #customControls.visible {
        opacity: 1;
        pointer-events: auto;
        transform: translateY(0);
      }
      #ctrlRow {
        margin-top: 0;
        height: 100%;
        display: flex;
        align-items: center;
        gap: 12px;
      }
      .ctrlIcon {
        width: 30px;
        height: 30px;
        border: 0;
        border-radius: 6px;
        background: transparent;
        color: #fff;
        font-size: 18px;
        font-weight: 700;
        line-height: 30px;
        text-align: center;
        cursor: pointer;
        padding: 0;
      }
      .ctrlIcon:active {
        background: rgba(255, 255, 255, 0.14);
      }
      .ctrlSpacer {
        flex: 1;
      }
      #volWrap {
        display: flex;
        align-items: center;
        gap: 0;
        min-width: 30px;
      }
      #volSliderContainer {
        width: 0;
        opacity: 0;
        overflow: hidden;
        pointer-events: none;
        transition: width 180ms ease, opacity 150ms ease;
      }
      #volWrap.expanded #volSliderContainer {
        width: 96px;
        opacity: 1;
        pointer-events: auto;
        margin-right: 8px;
      }
      #volSlider {
        -webkit-appearance: none;
        appearance: none;
        width: 96px;
        height: 4px;
        border-radius: 999px;
        background: rgba(255, 255, 255, 0.42);
        outline: none;
        margin: 0;
      }
      #volSlider::-webkit-slider-thumb {
        -webkit-appearance: none;
        appearance: none;
        width: 14px;
        height: 14px;
        border-radius: 50%;
        background: #fff;
        border: 0;
        cursor: pointer;
      }
      #volSlider::-moz-range-thumb {
        width: 14px;
        height: 14px;
        border-radius: 50%;
        background: #fff;
        border: 0;
        cursor: pointer;
      }
      #btnVolume {
        display: inline-flex;
        align-items: center;
        justify-content: center;
      }
      #btnVolume svg {
        width: 18px;
        height: 18px;
      }
      #btnVolume path {
        fill: none;
        stroke: #fff;
        stroke-width: 2;
        stroke-linecap: round;
        stroke-linejoin: round;
      }
      #customControls.ended #btnPlayPause {
        display: none;
      }
      #menuWrap {
        position: relative;
      }
      #btnMore {
        font-size: 20px;
        line-height: 24px;
        font-weight: 400;
      }
      #ytMenu {
        display: none;
        position: absolute;
        right: 0;
        bottom: 34px;
        min-width: 146px;
        border: 1px solid rgba(255, 255, 255, 0.24);
        border-radius: 10px;
        background: rgba(0, 0, 0, 0.92);
        padding: 6px;
        box-sizing: border-box;
      }
      #ytMenu.visible {
        display: block;
      }
      #btnWatchOnYoutube {
        width: 100%;
        height: 32px;
        border: 0;
        border-radius: 8px;
        background: rgba(255, 255, 255, 0.08);
        color: #fff;
        font-size: 12px;
        font-weight: 700;
        line-height: 32px;
        text-align: center;
        cursor: pointer;
      }
      #replayOverlay {
        position: absolute;
        inset: 0;
        z-index: 8150;
        display: flex;
        align-items: center;
        justify-content: center;
        opacity: 0;
        pointer-events: none;
        transition: opacity 150ms ease;
      }
      #replayOverlay.visible {
        opacity: 1;
        pointer-events: auto;
      }
      #btnReplay {
        width: 64px;
        height: 64px;
        border: 0;
        border-radius: 50%;
        background: rgba(0, 0, 0, 0.56);
        color: #fff;
        font-size: 30px;
        line-height: 64px;
        text-align: center;
        cursor: pointer;
      }
      #endTimerBadge {
        position: absolute;
        top: 10px;
        right: 10px;
        min-width: 34px;
        height: 30px;
        padding: 0 10px;
        border-radius: 15px;
        background: rgba(0, 0, 0, 0.72);
        color: #fff;
        font-size: 14px;
        font-weight: 700;
        line-height: 30px;
        text-align: center;
        z-index: 8250;
        opacity: 0;
        pointer-events: none;
        transition: opacity 120ms ease;
      }
      #endTimerBadge.visible {
        opacity: 1;
      }
    </style>
  </head>
  <body>
    <div id="viewport">
      <div id="player"></div>
      <div id="tapBlocker"></div>
      <div id="customControls">
        <div id="ctrlRow">
          <button id="btnPlayPause" class="ctrlIcon" type="button" aria-label="Play Pause">&#9654;</button>
          <div id="volWrap">
            <div id="volSliderContainer">
              <input id="volSlider" type="range" min="0" max="100" step="1" value="100" />
            </div>
            <button id="btnVolume" class="ctrlIcon" type="button" aria-label="Volume">
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M3 10H7L12 6V18L7 14H3Z"></path>
                <path id="volWave1" d="M16 9C17.5 10.2 17.5 13.8 16 15"></path>
                <path id="volWave2" d="M18.8 6.8C21.2 9.3 21.2 14.7 18.8 17.2"></path>
                <path id="volMuteSlash" d="M16 8L20 16"></path>
              </svg>
            </button>
          </div>
          <div class="ctrlSpacer"></div>
          <div id="menuWrap">
            <button id="btnMore" class="ctrlIcon" type="button" aria-label="More">&#8942;</button>
            <div id="ytMenu">
              <button id="btnWatchOnYoutube" type="button"></button>
            </div>
          </div>
        </div>
      </div>
      <div id="replayOverlay">
        <button id="btnReplay" type="button" aria-label="Replay">&#8635;</button>
      </div>
      <div id="endTimerBadge">0</div>
      <div id="maskTop"></div>
      <div id="maskBottom"></div>
      <div id="maskBottomRight"></div>
    </div>
    <script>
      const appOrigin = '$appOrigin';
      const videoId = '$videoId';
      let startSec = $start;
      let playerStartSec = $playerStart;
      let visualStartSec = $visualStart;
      let endSec = $end;
      let visualRevealExtraSec = ${widget.visualRevealExtraSeconds};
      let preventYoutubeEndScreen = $preventYoutubeEndScreen;
      let endHoldBackSeconds = ${widget.endHoldBackSeconds};
      let showControls = ${widget.showControls};
      let watchOnYoutubeTitle = '$watchOnYoutubeTitle';
      let endTimerStartSec = $timerCount;
      let hideLogo = ${widget.hideLogo};
      let hideAdvice = ${widget.hideAdvice};
      let maskTopPx = ${ui.maskTopPx};
      let maskBottomPx = ${ui.maskBottomPx};
      let maskBottomRightWidthPx = ${ui.maskBottomRightWidthPx};
      let maskBottomRightHeightPx = ${ui.maskBottomRightHeightPx};
      let overflowScale = ${ui.overflowScale};
      let overflowShiftYpx = ${ui.overflowShiftYpx};

      function log(msg) {
        try {
          console.log('VOCA_WEB|' + msg);
        } catch (_) {}
        if (window.VocaLog) {
          VocaLog.postMessage(msg);
        }
      }

      function emitEvent(type, payload) {
        if (!window.VocaLog) return;
        try {
          const event = Object.assign({ type: type }, payload || {});
          VocaLog.postMessage(JSON.stringify(event));
        } catch (e) {
          log('EVENT_EMIT_ERROR|' + e);
        }
      }

      window.addEventListener('error', function(event) {
        const msg = event && event.message ? event.message : 'unknown';
        const line = event && event.lineno ? event.lineno : 0;
        const col = event && event.colno ? event.colno : 0;
        log('JS_ERROR|msg=' + msg + '|line=' + line + '|col=' + col);
      });

      window.addEventListener('unhandledrejection', function(event) {
        const reason = event && event.reason ? String(event.reason) : 'unknown';
        log('JS_PROMISE_ERROR|reason=' + reason);
      });

      const ytHost = 'https://www.youtube.com';
      const ytNoCookieHost = 'https://www.youtube-nocookie.com';

      let player = null;
      let retriedNoCookie = false;
      let readySent = false;
      let probeTimer = null;
      let visualReadySent = false;
      let visualReadyConfirmedLogged = false;
      let visualReadyConfirmWatchdog = null;
      let visualRevealTimer = null;
      let lastVisualState = null;
      let endHoldSent = false;
      let endHoldAt = Number.MAX_SAFE_INTEGER;
      let controlsVisible = false;
      let controlsHideTimer = null;
      let menuVisible = false;
      let uiPlayState = false;
      let replayVisible = false;
      let volumeValue = 100;
      let lastNonZeroVolume = 100;
      let volumePanelExpanded = false;
      let endTimerInterval = null;
      let endTimerActive = false;
      let endTimerRemaining = endTimerStartSec;
      let endTimerStarted = false;
      let endTimerDoneSent = false;
      let replayLocked = false;

      const tapBlocker = document.getElementById('tapBlocker');
      const playerHost = document.getElementById('player');
      const customControls = document.getElementById('customControls');
      const replayOverlay = document.getElementById('replayOverlay');
      const endTimerBadge = document.getElementById('endTimerBadge');
      const maskTop = document.getElementById('maskTop');
      const maskBottom = document.getElementById('maskBottom');
      const maskBottomRight = document.getElementById('maskBottomRight');
      const btnPlayPause = document.getElementById('btnPlayPause');
      const btnReplay = document.getElementById('btnReplay');
      const volWrap = document.getElementById('volWrap');
      const volSlider = document.getElementById('volSlider');
      const btnVolume = document.getElementById('btnVolume');
      const volWave1 = document.getElementById('volWave1');
      const volWave2 = document.getElementById('volWave2');
      const volMuteSlash = document.getElementById('volMuteSlash');
      const btnMore = document.getElementById('btnMore');
      const ytMenu = document.getElementById('ytMenu');
      const btnWatchOnYoutube = document.getElementById('btnWatchOnYoutube');

      function getYoutubeWatchUrl() {
        const t = Math.max(0, Math.floor(startSec));
        return 'https://www.youtube.com/watch?v=' + encodeURIComponent(videoId) + '&t=' + t + 's';
      }

      function clearControlsHideTimer() {
        if (!controlsHideTimer) return;
        clearTimeout(controlsHideTimer);
        controlsHideTimer = null;
      }

      function clearVisualReadyConfirmWatchdog() {
        if (!visualReadyConfirmWatchdog) return;
        clearTimeout(visualReadyConfirmWatchdog);
        visualReadyConfirmWatchdog = null;
      }

      window.__vocaDispose = function() {
        try {
          clearControlsHideTimer();
          if (probeTimer) {
            clearInterval(probeTimer);
            probeTimer = null;
          }
          if (visualRevealTimer) {
            clearInterval(visualRevealTimer);
            visualRevealTimer = null;
          }
          clearVisualReadyConfirmWatchdog();
          if (endTimerInterval) {
            clearInterval(endTimerInterval);
            endTimerInterval = null;
          }
          if (window.__vocaPlayer && typeof window.__vocaPlayer.destroy === 'function') {
            window.__vocaPlayer.destroy();
          }
          window.__vocaPlayer = null;
          player = null;
          log('DISPOSE|ok');
        } catch (e) {
          log('DISPOSE|error=' + e);
        }
      };

      function applyUiPresetToDom() {
        if (playerHost) {
          playerHost.style.top = 'calc(50% - ' + overflowShiftYpx + 'px)';
          playerHost.style.transform = 'translate(-50%, -50%) scale(' + overflowScale + ')';
        }
        if (maskTop) {
          maskTop.style.height = maskTopPx + 'px';
        }
        if (maskBottom) {
          maskBottom.style.height = maskBottomPx + 'px';
        }
        if (maskBottomRight) {
          maskBottomRight.style.width = maskBottomRightWidthPx + 'px';
          maskBottomRight.style.height = maskBottomRightHeightPx + 'px';
        }
      }

      function applyControlsMode(reason) {
        if (btnMore) {
          btnMore.style.display = showControls ? 'inline-block' : 'none';
        }
        if (customControls) {
          customControls.style.display = showControls ? 'block' : 'none';
        }
        if (replayOverlay) {
          replayOverlay.style.display = showControls ? 'flex' : 'none';
        }
        if (!showControls) {
          setMenuVisible(false, reason + '_hide_controls');
          setReplayVisible(false, reason + '_hide_controls');
          setControlsVisible(false, reason + '_hide_controls');
        }
      }

      function recalculateVisualThreshold() {
        const clipDuration = Math.max(0, endSec - startSec);
        let dynamicExtra = visualRevealExtraSec;
        if (clipDuration > 0 && clipDuration <= 4.0) {
          dynamicExtra = 0.35;
        } else if (clipDuration > 4.0 && clipDuration <= 8.0) {
          dynamicExtra = 0.5;
        }

        let threshold = visualStartSec + dynamicExtra;
        if (endSec > 0) {
          const nearEnd = endSec - 0.8;
          if (nearEnd > visualStartSec) {
            threshold = Math.min(threshold, nearEnd);
          } else {
            threshold = visualStartSec;
          }
        }
        log(
          'VISUAL_MONITOR|threshold=' + threshold +
          '|clip=' + clipDuration +
          '|extra=' + dynamicExtra
        );
        return threshold;
      }

      function recalculateEndHold(reason) {
        endHoldAt = Math.max(
          startSec + 0.2,
          endSec > 0 ? endSec - endHoldBackSeconds : Number.MAX_SAFE_INTEGER
        );
        log(
          'END_HOLD|enabled=' + preventYoutubeEndScreen +
          '|holdAt=' + endHoldAt +
          '|reason=' + reason
        );
      }

      window.vocaUpdateConfig = function(next) {
        if (!next) return;
        if (typeof next.showControls === 'boolean') showControls = next.showControls;
        if (typeof next.hideAdvice === 'boolean') {
          hideAdvice = next.hideAdvice;
          preventYoutubeEndScreen = next.hideAdvice;
        }
        if (typeof next.hideLogo === 'boolean') hideLogo = next.hideLogo;
        if (typeof next.timerCount === 'number') {
          endTimerStartSec = Math.max(0, Math.floor(next.timerCount));
          if (!endTimerActive) {
            endTimerRemaining = endTimerStartSec;
            endTimerStarted = false;
            endTimerDoneSent = false;
            replayLocked = false;
          } else {
            endTimerRemaining = Math.min(endTimerRemaining, endTimerStartSec);
          }
        }
        if (typeof next.watchOnYoutubeTitle === 'string') {
          watchOnYoutubeTitle = next.watchOnYoutubeTitle;
        }
        if (typeof next.maskTopPx === 'number') maskTopPx = next.maskTopPx;
        if (typeof next.maskBottomPx === 'number') maskBottomPx = next.maskBottomPx;
        if (typeof next.maskBottomRightWidthPx === 'number') {
          maskBottomRightWidthPx = next.maskBottomRightWidthPx;
        }
        if (typeof next.maskBottomRightHeightPx === 'number') {
          maskBottomRightHeightPx = next.maskBottomRightHeightPx;
        }
        if (typeof next.overflowScale === 'number') overflowScale = next.overflowScale;
        if (typeof next.overflowShiftYpx === 'number') {
          overflowShiftYpx = next.overflowShiftYpx;
        }

        if (btnWatchOnYoutube) {
          btnWatchOnYoutube.textContent = watchOnYoutubeTitle;
        }
        applyUiPresetToDom();
        applyControlsMode('config_update');
        renderEndTimer('config_update');
        recalculateEndHold('config_update');
        log(
          'CONFIG_UPDATE|controls=' + showControls +
          '|hideAdvice=' + hideAdvice +
          '|hideLogo=' + hideLogo +
          '|timer=' + endTimerStartSec
        );
      };

      window.vocaUpdateClip = function(next) {
        if (!next) return;
        if (typeof next.startSec === 'number' && Number.isFinite(next.startSec)) {
          startSec = Math.max(0, next.startSec);
        }
        if (typeof next.playerStartSec === 'number' && Number.isFinite(next.playerStartSec)) {
          playerStartSec = Math.max(0, Math.floor(next.playerStartSec));
        }
        if (typeof next.visualStartSec === 'number' && Number.isFinite(next.visualStartSec)) {
          visualStartSec = Math.max(startSec, next.visualStartSec);
        } else {
          visualStartSec = startSec;
        }
        if (typeof next.endSec === 'number' && Number.isFinite(next.endSec)) {
          endSec = Math.max(startSec + 1, next.endSec);
        } else {
          endSec = Math.max(startSec + 1, endSec);
        }
        if (typeof next.visualRevealExtraSec === 'number' && Number.isFinite(next.visualRevealExtraSec)) {
          visualRevealExtraSec = Math.max(0, next.visualRevealExtraSec);
        }
        if (typeof next.endHoldBackSec === 'number' && Number.isFinite(next.endHoldBackSec)) {
          endHoldBackSeconds = Math.max(0, next.endHoldBackSec);
        }

        emitEvent('replay_cycle_started', { reason: 'clip_update' });
        endHoldSent = false;
        visualReadySent = false;
        visualReadyConfirmedLogged = false;
        clearVisualReadyConfirmWatchdog();
        recalculateEndHold('clip_update');
        if (visualRevealTimer) {
          clearInterval(visualRevealTimer);
          visualRevealTimer = null;
        }
        try {
          const st = player && player.getPlayerState ? player.getPlayerState() : -1;
          if (st === 1 && player && typeof player.seekTo === 'function') {
            player.seekTo(startSec, true);
            log('CLIP_UPDATE|seek_while_playing=' + startSec);
          }
        } catch (_) {}
        log(
          'CLIP_UPDATE|start=' + startSec +
          '|visualStart=' + visualStartSec +
          '|end=' + endSec
        );
      };

      function setMenuVisible(visible, reason) {
        if (!ytMenu) return;
        if (!showControls) {
          menuVisible = false;
          ytMenu.classList.remove('visible');
          return;
        }
        menuVisible = !!visible;
        ytMenu.classList.toggle('visible', menuVisible);
        log('CONTROLS|menu=' + menuVisible + '|reason=' + reason);
      }

      function renderEndTimer(reason) {
        if (!endTimerBadge) return;
        if (!showControls) {
          endTimerBadge.classList.remove('visible');
          return;
        }
        if (endTimerStartSec <= 0) {
          endTimerBadge.classList.remove('visible');
          return;
        }
        const safeRemaining = Math.max(0, endTimerRemaining);
        const shouldShow = endTimerStarted && safeRemaining > 0;
        endTimerBadge.textContent = String(safeRemaining);
        endTimerBadge.classList.toggle('visible', shouldShow);
        if (reason) {
          log(
              'END_TIMER|render=' +
                  safeRemaining +
                  '|active=' +
                  endTimerActive +
                  '|started=' +
                  endTimerStarted +
                  '|reason=' +
                  reason);
        }
      }

      function stopEndTimer(reason, resetToStart) {
        if (endTimerInterval) {
          clearInterval(endTimerInterval);
          endTimerInterval = null;
        }
        endTimerActive = false;
        if (resetToStart) {
          endTimerRemaining = endTimerStartSec;
          endTimerStarted = false;
          endTimerDoneSent = false;
          replayLocked = false;
        }
        renderEndTimer(reason || 'stop');
      }

      function startEndTimer(reason) {
        if (endTimerStartSec <= 0) {
          log('END_TIMER|skip_start|reason=' + reason + '|start=' + endTimerStartSec);
          return;
        }
        if (endTimerRemaining <= 0) {
          replayLocked = true;
          log('END_TIMER|already_done|reason=' + reason + '|remaining=' + endTimerRemaining);
          setReplayVisible(false, 'timer_already_done_lock');
          renderEndTimer('already_done_' + reason);
          return;
        }
        stopEndTimer('restart_' + reason, false);
        endTimerStarted = true;
        endTimerActive = true;
        renderEndTimer('start_' + reason);
        log(
          'END_TIMER|started|remaining=' +
              endTimerRemaining +
              '|from=' +
              endTimerStartSec +
              '|reason=' +
              reason,
        );
        endTimerInterval = setInterval(function() {
          endTimerRemaining = Math.max(0, endTimerRemaining - 1);
          renderEndTimer('tick');
          if (endTimerRemaining <= 0) {
            stopEndTimer('done', false);
            replayLocked = true;
            setReplayVisible(false, 'timer_done_lock');
            if (!endTimerDoneSent) {
              endTimerDoneSent = true;
              log('END_TIMER|done|reason=' + reason);
              emitEvent('end_timer_done', { reason: reason });
            }
          }
        }, 1000);
      }

      function setReplayVisible(visible, reason) {
        if (!replayOverlay || !customControls) return;
        const wasReplayVisible = replayVisible;
        if (!showControls) {
          replayVisible = false;
          replayOverlay.classList.remove('visible');
          customControls.classList.remove('ended');
          return;
        }
        if (replayLocked && visible) {
          replayVisible = false;
          replayOverlay.classList.remove('visible');
          customControls.classList.add('ended');
          log('CONTROLS|replay_blocked|reason=' + reason);
          return;
        }
        replayVisible = !!visible;
        replayOverlay.classList.toggle('visible', replayVisible);
        customControls.classList.toggle('ended', replayVisible || replayLocked);
        log('CONTROLS|replay=' + replayVisible + '|reason=' + reason);
        if (replayVisible && !wasReplayVisible) {
          emitEvent('replay_available', { reason: reason });
        }
        if (replayVisible) {
          clearControlsHideTimer();
          setControlsVisible(true, 'replay_visible');
        }
      }

      function updatePlayIcon() {
        if (!btnPlayPause) return;
        btnPlayPause.innerHTML = uiPlayState ? '&#10074;&#10074;' : '&#9654;';
      }

      function updateVolumeIcon() {
        if (!btnVolume || !volWave1 || !volWave2 || !volMuteSlash) return;
        volMuteSlash.style.display = 'none';
        volWave1.style.display = 'none';
        volWave2.style.display = 'none';
        if (volumeValue <= 0) {
          volMuteSlash.style.display = 'inline';
        } else if (volumeValue <= 45) {
          volWave1.style.display = 'inline';
        } else {
          volWave1.style.display = 'inline';
          volWave2.style.display = 'inline';
        }
      }

      function setVolumePanelExpanded(expanded, reason) {
        if (!volWrap) return;
        const next = !!expanded;
        if (volumePanelExpanded === next) return;
        volumePanelExpanded = next;
        volWrap.classList.toggle('expanded', volumePanelExpanded);
        log('CONTROLS|volume_panel=' + volumePanelExpanded + '|reason=' + reason);
      }

      function applyVolume(nextValue, reason, quiet) {
        const clamped = Math.max(0, Math.min(100, Math.floor(nextValue || 0)));
        volumeValue = clamped;
        if (volumeValue > 0) {
          lastNonZeroVolume = volumeValue;
        }
        if (volSlider) {
          volSlider.value = String(volumeValue);
        }
        updateVolumeIcon();

        try {
          if (player && typeof player.setVolume === 'function') {
            player.setVolume(volumeValue);
          }
          if (player && volumeValue <= 0 && typeof player.mute === 'function') {
            player.mute();
          } else if (player && volumeValue > 0 && typeof player.unMute === 'function') {
            player.unMute();
          }
        } catch (e) {
          log('CONTROLS|volume_apply_error=' + e);
        }

        if (!quiet) {
          log('CONTROLS|volume=' + volumeValue + '|reason=' + reason);
        }
      }

      function setControlsVisible(visible, reason) {
        if (!showControls) {
          controlsVisible = false;
          customControls.classList.remove('visible');
          return;
        }
        const next = !!visible;
        if (controlsVisible !== next) {
          controlsVisible = next;
          customControls.classList.toggle('visible', controlsVisible);
          log('CONTROLS|visible=' + controlsVisible + '|reason=' + reason);
        }
        if (!controlsVisible && menuVisible) {
          setMenuVisible(false, 'controls_hidden');
        }
        if (!controlsVisible && volumePanelExpanded) {
          setVolumePanelExpanded(false, 'controls_hidden');
        }
      }

      function scheduleControlsHide(ms, reason) {
        if (!showControls) return;
        if (replayVisible) {
          log('CONTROLS|auto_hide_skipped_replay|reason=' + reason);
          return;
        }
        clearControlsHideTimer();
        controlsHideTimer = setTimeout(function() {
          setControlsVisible(false, 'auto_hide_' + reason);
          clearControlsHideTimer();
        }, ms);
      }

      function revealControls(reason) {
        if (!showControls) return;
        clearControlsHideTimer();
        setControlsVisible(true, reason);
      }

      function pulseControls(reason) {
        revealControls(reason);
        scheduleControlsHide(2500, reason);
      }

      function togglePlayPause(reason) {
        if (replayLocked) {
          log('CONTROLS|play_pause_blocked_replay_locked|reason=' + reason);
          return;
        }
        if (!player || typeof player.getPlayerState !== 'function') {
          log('CONTROLS|play_pause_no_player|reason=' + reason);
          return;
        }
        try {
          const st = player.getPlayerState();
          if (st === 1 && typeof player.pauseVideo === 'function') {
            player.pauseVideo();
            log('CONTROLS|pause|reason=' + reason);
          } else if (typeof player.playVideo === 'function') {
            setReplayVisible(false, 'play_from_controls');
            player.playVideo();
            log('CONTROLS|play|reason=' + reason);
          }
        } catch (e) {
          log('CONTROLS|play_pause_error=' + e);
        }
      }

      try {
        if (tapBlocker) {
          tapBlocker.addEventListener('click', function(event) {
            event.preventDefault();
            event.stopPropagation();
            log('INTERACT|video_tap_blocked');
            setMenuVisible(false, 'tap_blocker');
            pulseControls('tap');
          });

          tapBlocker.addEventListener('mouseenter', function() {
            revealControls('hover_enter');
          });

          tapBlocker.addEventListener('mouseleave', function() {
            scheduleControlsHide(2500, 'hover_leave');
          });
        }

        if (customControls) {
          customControls.addEventListener('click', function(event) {
            event.stopPropagation();
          });

          customControls.addEventListener('mouseenter', function() {
            clearControlsHideTimer();
          });

          customControls.addEventListener('mouseleave', function() {
            scheduleControlsHide(2500, 'controls_leave');
          });
        }

        if (volWrap) {
          volWrap.addEventListener('mouseenter', function() {
            revealControls('volume_hover_enter');
            setVolumePanelExpanded(true, 'volume_hover_enter');
          });

          volWrap.addEventListener('mouseleave', function() {
            setVolumePanelExpanded(false, 'volume_hover_leave');
          });
        }

        if (btnPlayPause) {
          btnPlayPause.addEventListener('click', function(event) {
            event.preventDefault();
            event.stopPropagation();
            togglePlayPause('play_pause_click');
            pulseControls('play_pause_click');
          });
        }

        if (volSlider) {
          volSlider.addEventListener('input', function(event) {
            event.preventDefault();
            event.stopPropagation();
            if (!volumePanelExpanded) {
              setVolumePanelExpanded(true, 'slider_input_expand');
            }
            const next = parseInt(volSlider.value || '0', 10);
            applyVolume(next, 'slider_drag', false);
            pulseControls('slider_drag');
          });
        }

        if (btnVolume) {
          btnVolume.addEventListener('click', function(event) {
            event.preventDefault();
            event.stopPropagation();
            if (!volumePanelExpanded) {
              setVolumePanelExpanded(true, 'volume_icon_expand');
              pulseControls('volume_icon_expand');
              return;
            }
            if (volumeValue > 0) {
              applyVolume(0, 'volume_toggle_mute', false);
            } else {
              applyVolume(lastNonZeroVolume > 0 ? lastNonZeroVolume : 100, 'volume_toggle_unmute', false);
            }
            pulseControls('volume_icon_click');
          });
        }

        if (btnMore) {
          btnMore.addEventListener('click', function(event) {
            event.preventDefault();
            event.stopPropagation();
            revealControls('menu_toggle');
            setMenuVisible(!menuVisible, 'menu_button');
            if (!menuVisible) {
              scheduleControlsHide(2500, 'menu_close');
            }
          });
        }

        if (btnReplay) {
          btnReplay.addEventListener('click', function(event) {
            event.preventDefault();
            event.stopPropagation();
            if (replayLocked) {
              log('CONTROLS|replay_click_blocked_replay_locked');
              return;
            }
            setReplayVisible(false, 'replay_click');
            if (window.vocaPlay) {
              window.vocaPlay();
            }
          });
        }

        if (btnWatchOnYoutube) {
          btnWatchOnYoutube.textContent = watchOnYoutubeTitle;
          btnWatchOnYoutube.addEventListener('click', function(event) {
            event.preventDefault();
            event.stopPropagation();
            setMenuVisible(false, 'watch_click');
            const url = getYoutubeWatchUrl();
            log('CONTROLS|watch_on_youtube_clicked|url=' + url);
            if (window.VocaAction) {
              VocaAction.postMessage('OPEN_EXTERNAL|' + url);
            }
            scheduleControlsHide(1200, 'watch_click');
          });
        }

        applyUiPresetToDom();
        applyControlsMode('init');

        setMenuVisible(false, 'init');
        setReplayVisible(false, 'init');
        setVolumePanelExpanded(false, 'init');
        setControlsVisible(false, 'init');
        applyVolume(volumeValue, 'init', true);
      stopEndTimer('init', true);
      } catch (e) {
        log('INIT_ERROR|' + e);
      }

      function markReady(reason) {
        if (readySent) return;
        readySent = true;
        log('READY_TO_PLAY|' + reason);
        emitEvent('ready', { reason: reason });
        if (probeTimer) {
          clearInterval(probeTimer);
          probeTimer = null;
        }
      }

      function startProbe() {
        if (probeTimer) return;
        let fastUntil = Date.now() + 2000;

        probeTimer = setInterval(function() {
          if (!player || typeof player.getPlayerState !== 'function') return;
          const state = player.getPlayerState();
          let loaded = 0;
          try {
            loaded = player.getVideoLoadedFraction
              ? (player.getVideoLoadedFraction() || 0)
              : 0;
          } catch (_) {}
          log('PROBE|state=' + state + '|loaded=' + loaded);
          if (state === 5 || state === 2 || state === 1 || loaded > 0) {
            markReady('probe_state=' + state + '_loaded=' + loaded);
            return;
          }

          if (Date.now() > fastUntil) {
            clearInterval(probeTimer);
            probeTimer = setInterval(function() {
              if (!player || !player.getPlayerState) return;
              const st2 = player.getPlayerState();
              let ld2 = 0;
              try {
                ld2 = player.getVideoLoadedFraction
                  ? (player.getVideoLoadedFraction() || 0)
                  : 0;
              } catch (_) {}
              log('PROBE|state=' + st2 + '|loaded=' + ld2);
              if (st2 === 5 || st2 === 2 || st2 === 1 || ld2 > 0) {
                markReady('probe_state=' + st2 + '_loaded=' + ld2);
              }
            }, 1000);
          }
        }, 200);
      }

      function markVisualReady(reason) {
        if (visualReadySent) return;
        visualReadySent = true;
        clearVisualReadyConfirmWatchdog();
        if (reason === 'optimistic_state_playing') {
          visualReadyConfirmWatchdog = setTimeout(function() {
            if (!visualReadyConfirmedLogged) {
              log('VISUAL_READY_TIMEOUT|reason=optimistic_no_confirm_800ms');
            }
            clearVisualReadyConfirmWatchdog();
          }, 800);
        }
        log('VISUAL_READY|' + reason);
        emitEvent('visual_ready', { reason: reason });
      }

      function startVisualRevealMonitor() {
        if (visualRevealTimer) return;

        const threshold = recalculateVisualThreshold();
        recalculateEndHold('visual_monitor_start');

        visualRevealTimer = setInterval(function() {
          if (!player || typeof player.getPlayerState !== 'function') return;
          if (typeof player.getCurrentTime !== 'function') return;
          const state = player.getPlayerState();
          const t = player.getCurrentTime() || 0;
          if (state !== lastVisualState) {
            lastVisualState = state;
            log('VISUAL_MONITOR|state=' + state + '|time=' + t.toFixed(2));
          }
          if (state === 1 && t >= threshold) {
            if (!visualReadyConfirmedLogged) {
              visualReadyConfirmedLogged = true;
              clearVisualReadyConfirmWatchdog();
              log('VISUAL_READY_CONFIRMED|time=' + t.toFixed(2) + '|threshold=' + threshold);
            }
            markVisualReady('state=1|time=' + t.toFixed(2) + '|threshold=' + threshold);
          }
          if (preventYoutubeEndScreen && state === 1 && !endHoldSent && t >= endHoldAt) {
            endHoldSent = true;
            try {
              if (typeof player.pauseVideo === 'function') {
                player.pauseVideo();
              }
              log('END_HOLD|paused_at=' + t.toFixed(2) + '|target=' + endHoldAt.toFixed(2) + '|no_seek=1');
              uiPlayState = false;
              updatePlayIcon();
              setReplayVisible(true, 'end_hold_pause');
              startEndTimer('end_hold_pause');
              if (visualRevealTimer) {
                clearInterval(visualRevealTimer);
                visualRevealTimer = null;
              }
            } catch (e) {
              log('END_HOLD|error=' + e);
            }
          }
        }, 80);
      }

      function buildPlayer(host) {
        const playerVars = {
          autoplay: 0,
          controls: 0,
          start: playerStartSec,
          playsinline: 1,
          rel: 0,
          modestbranding: 1,
          iv_load_policy: 3,
          disablekb: 1,
          fs: 0,
          enablejsapi: 1,
          origin: appOrigin,
          widget_referrer: appOrigin
        };
        if (!preventYoutubeEndScreen && endSec > 0) {
          playerVars.end = Math.floor(endSec);
        } else {
          log('END_HOLD|manual_end_guard=ON');
        }

        player = new YT.Player('player', {
          host: host,
          width: '100%',
          height: '100%',
          videoId: videoId,
          playerVars: playerVars,
          events: {
            onReady: function() {
              log('EVENT|onReady|host=' + host);
              log('UI_MODE|hideLogo=' + hideLogo);
              log('UI_MODE|hideAdvice=' + hideAdvice);
              log('UI_MODE|showControls=' + showControls);
              log('UI_MODE|watchOnYoutubeTitle=' + watchOnYoutubeTitle);
              log('UI_MASK|top=' + maskTopPx + '|bottom=' + maskBottomPx);
              log('UI_MASK_BR|w=' + maskBottomRightWidthPx + '|h=' + maskBottomRightHeightPx);
              log('UI_OVERFLOW|scale=' + overflowScale + '|shiftY=' + overflowShiftYpx);
              setControlsVisible(false, 'on_ready');
              updatePlayIcon();
              updateVolumeIcon();
              applyVolume(volumeValue, 'on_ready', true);
              startProbe();
            },
            onStateChange: function(event) {
              log('EVENT|onState=' + event.data + '|host=' + host);
              let handledEnd = false;
              if (event.data === 5 || event.data === 2 || event.data === 1) {
                markReady('state=' + event.data + '|host=' + host);
              }
              if (event.data === 1) {
                uiPlayState = true;
                updatePlayIcon();
                setReplayVisible(false, 'state_playing');
                markVisualReady('optimistic_state_playing');
              }
              if (event.data === 0 && preventYoutubeEndScreen) {
                log('EVENT|ended_detected');
                if (!endHoldSent) {
                  endHoldSent = true;
                  try {
                    if (typeof player.pauseVideo === 'function') {
                      player.pauseVideo();
                    }
                    log('END_HOLD|recovered_from_ended|no_seek=1');
                    uiPlayState = false;
                    updatePlayIcon();
                    setReplayVisible(true, 'state_ended_recovered');
                    startEndTimer('state_ended_recovered');
                    handledEnd = true;
                  } catch (e) {
                    log('END_HOLD|recover_error=' + e);
                  }
                }
              }
              if (event.data === 2) {
                uiPlayState = false;
                updatePlayIcon();
              }
              if (event.data === 0 && !handledEnd) {
                uiPlayState = false;
                updatePlayIcon();
                setReplayVisible(true, 'state_ended');
                startEndTimer('state_ended');
              }
              if (event.data === 1) {
                startVisualRevealMonitor();
              }
            },
            onError: function(event) {
              log('EVENT|onError=' + event.data + '|host=' + host);
              if (!retriedNoCookie) {
                retriedNoCookie = true;
                document.getElementById('player').innerHTML = '';
                log('EVENT|retry_with_nocookie');
                buildPlayer(ytNoCookieHost);
              }
            }
          }
        });

        window.__vocaPlayer = player;
      }

      function shouldSeekToStart(currentTime) {
        const eps = 0.20;
        if (currentTime < startSec - eps) return true;
        if (currentTime > startSec + 0.60) return true;
        const restartThreshold = Math.max(
          startSec + 0.2,
          endSec > 0 ? endSec - Math.max(endHoldBackSeconds, 0.4) : Number.MAX_SAFE_INTEGER
        );
        if (currentTime >= restartThreshold) return true;
        return false;
      }

      window.vocaPlay = function() {
        if (replayLocked) {
          log('ACTION|play_blocked_replay_locked');
          setReplayVisible(false, 'play_blocked_replay_locked');
          return;
        }
        if (window.__vocaPlayer && window.__vocaPlayer.playVideo) {
          emitEvent('replay_cycle_started', { reason: 'play_requested' });
          endHoldSent = false;
          setReplayVisible(false, 'play_requested');
          setMenuVisible(false, 'play_requested');
          setControlsVisible(false, 'play_requested');
          let currentTime = 0;
          try {
            if (window.__vocaPlayer.getCurrentTime) {
              currentTime = window.__vocaPlayer.getCurrentTime() || 0;
            }
            if (window.__vocaPlayer.seekTo && shouldSeekToStart(currentTime)) {
              window.__vocaPlayer.seekTo(startSec, true);
              log(
                'ACTION|seekTo=' + startSec +
                '|from=' + currentTime.toFixed(2)
              );
            } else {
              log('ACTION|seek_skipped|t=' + currentTime.toFixed(2));
            }
          } catch (e) {
            log('ACTION|play_context_error=' + e);
          }
          try {
            if (window.__vocaPlayer.unMute) {
              window.__vocaPlayer.unMute();
            }
            if (window.__vocaPlayer.setVolume) {
              window.__vocaPlayer.setVolume(volumeValue);
            }
            if (window.__vocaPlayer.isMuted) {
              log('ACTION|before_play_isMuted=' + window.__vocaPlayer.isMuted());
            }
          } catch (e) {
            log('ACTION|unmute_error=' + e);
          }

          window.__vocaPlayer.playVideo();
          log('ACTION|playVideo_unmuted');
        } else {
          log('ACTION|playVideo_skipped_player_not_ready');
        }
      };

      function ensureIframeApiLoaded() {
        if (window.YT && window.YT.Player) {
          log('EVENT|iframe_api_already_loaded');
          buildPlayer(ytHost);
          return;
        }
        if (document.getElementById('yt-iframe-api')) return;
        const tag = document.createElement('script');
        tag.id = 'yt-iframe-api';
        tag.src = 'https://www.youtube.com/iframe_api';
        document.head.appendChild(tag);
      }

      window.onYouTubeIframeAPIReady = function() {
        log('EVENT|iframe_api_ready|origin=' + appOrigin);
        buildPlayer(ytHost);
      };
      ensureIframeApiLoaded();
    </script>
  </body>
</html>
''';
  }
}

class _UiPreset {
  const _UiPreset({
    required this.maskTopPx,
    required this.maskBottomPx,
    required this.maskBottomRightWidthPx,
    required this.maskBottomRightHeightPx,
    required this.overflowScale,
    required this.overflowShiftYpx,
  });

  final int maskTopPx;
  final int maskBottomPx;
  final int maskBottomRightWidthPx;
  final int maskBottomRightHeightPx;
  final double overflowScale;
  final int overflowShiftYpx;
}
