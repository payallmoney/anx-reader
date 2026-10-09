import 'dart:async';
import 'package:anx_reader/utils/platform_utils.dart';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/tts/base_tts.dart';
import 'package:anx_reader/service/tts/models/tts_voice.dart';
import 'package:anx_reader/service/tts/tts_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

class SystemTts extends BaseTts {
  static final SystemTts _instance = SystemTts._internal();

  factory SystemTts() {
    return _instance;
  }

  SystemTts._internal();

  final FlutterTts flutterTts = FlutterTts();

  String? _currentVoiceText;
  static String? _prevVoiceText;

  bool restarting = false;

  late Function getHereFunction;
  late Function getNextTextFunction;
  late Function getPrevTextFunction;

  @override
  final ValueNotifier<TtsStateEnum> ttsStateNotifier =
      ValueNotifier<TtsStateEnum>(TtsStateEnum.stopped);

  @override
  void updateTtsState(TtsStateEnum newState) {
    ttsStateNotifier.value = newState;
  }

  bool get isIOS => AnxPlatform.isIOS;
  bool get isAndroid => AnxPlatform.isAndroid;
  bool get isWindows => AnxPlatform.isWindows;
  bool get isLinux => AnxPlatform.isLinux;
  bool get isWeb => kIsWeb;

  @override
  double get volume => Prefs().ttsVolume;

  @override
  set volume(double volume) {
    Prefs().ttsVolume = volume;
    restart();
  }

  @override
  double get pitch => Prefs().ttsPitch;

  @override
  set pitch(double pitch) {
    Prefs().ttsPitch = pitch;
    restart();
  }

  @override
  double get rate => Prefs().ttsRate;

  @override
  set rate(double rate) {
    Prefs().ttsRate = rate;
    restart();
  }

  @override
  bool get isPlaying => ttsStateNotifier.value == TtsStateEnum.playing;

  @override
  String? get currentVoiceText => _currentVoiceText;

  @override
  Future<void> init(Function getCurrentText, Function getNextText,
      Function getPrevText) async {
    getHereFunction = getCurrentText;
    getNextTextFunction = getNextText;
    getPrevTextFunction = getPrevText;

    if (isLinux) {
      return;
    }

    AnxLog.info('TTS init: setAwaitOptions');
    await setAwaitOptions();
    AnxLog.info('TTS init: engine info');
    if (isAndroid) {
      await getDefaultEngine();
      await getDefaultVoice();
    }
    AnxLog.info('TTS init: handlers registered');

    flutterTts.setStartHandler(() async {
      AnxLog.info('TTS start handler');
      _petWatchdog();
      updateTtsState(TtsStateEnum.playing);
    });

    flutterTts.setErrorHandler((msg) {
      AnxLog.severe('TTS engine error: $msg');
      _petWatchdog();
    });

    // utterance progress ticks keep the watchdog fed while a long
    // sentence is still being spoken
    flutterTts.setProgressHandler((text, start, end, word) {
      _petWatchdog();
    });

    // The utterance-completion event is the single driver of the Android
    // narration chain: each finished sentence fetches the next one and
    // speaks it. The previous design pre-queued the next sentence from the
    // start handler via ttsPrepare(), which can hang forever after a
    // chapter switch (WebView JS stall) and silently kill the chain.
    flutterTts.setCompletionHandler(() async {
      if (!isAndroid) {
        return;
      }
      AnxLog.info('TTS completion handler');
      _petWatchdog();
      updateTtsState(TtsStateEnum.playing);
      try {
        final next = await getNextText();
        AnxLog.info('TTS next sentence: ${next.length} chars');
        if (next.isEmpty) {
          // end of book
          updateTtsState(TtsStateEnum.stopped);
          _stopWatchdog();
          return;
        }
        _prevVoiceText = next;
        _currentVoiceText = next;
        await speak(content: next);
      } catch (e, s) {
        // any failure in the chain (webview exceptions, engine hiccups)
        // must not silently kill narration — log and let the watchdog
        // recover shortly
        AnxLog.severe('TTS completion handler error: $e\n$s');
      }
    });

    _startWatchdog();
  }

  // ---- stall watchdog ----
  // If playing state sees no utterance events for 30s (engine stopped
  // calling back, chain died in an exception, device suspended us),
  // proactively fetch the next sentence and speak it again. This is the
  // last line of defence covering failure modes we cannot reproduce on
  // emulators.
  Timer? _watchdog;
  DateTime _lastUtteranceEvent = DateTime.now();

  void _petWatchdog() {
    _lastUtteranceEvent = DateTime.now();
  }

  void _startWatchdog() {
    if (!isAndroid) return;
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (ttsStateNotifier.value != TtsStateEnum.playing) return;
      final idle = DateTime.now().difference(_lastUtteranceEvent).inSeconds;
      if (idle < 30) return;
      AnxLog.severe('TTS watchdog: stalled for ${idle}s, recovering');
      _petWatchdog();
      _recoverFromStall();
    });
    AnxLog.info('TTS watchdog started');
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  Future<void> _recoverFromStall() async {
    try {
      final next = await getNextTextFunction();
      if (next.isEmpty) {
        updateTtsState(TtsStateEnum.stopped);
        _stopWatchdog();
        return;
      }
      _prevVoiceText = next;
      _currentVoiceText = next;
      AnxLog.info('TTS watchdog: resuming with ${next.length} chars');
      await speak(content: next);
    } catch (e) {
      AnxLog.severe('TTS watchdog recovery failed: $e');
    }
  }

  Future<void> setAwaitOptions() async {
    if (isLinux) {
      return;
    }
    // completion-driven chain: speak() must return immediately, otherwise
    // its awaited completion races the completion handler and skips
    // sentences
    await flutterTts.awaitSpeakCompletion(false);
    if (isAndroid) {
      await flutterTts.setQueueMode(1);
    }
  }

  Future<void> getDefaultEngine() async {
    var engine = await flutterTts.getDefaultEngine;
    if (engine != null) {}
  }

  Future<void> getDefaultVoice() async {
    var voice = await flutterTts.getDefaultVoice;
    if (voice != null) {}
  }

  /// Apply the voice by shortName
  Future<void> _applyVoice(String? voiceShortName) async {
    if (voiceShortName == null || voiceShortName.isEmpty) {
      return;
    }

    try {
      // Get all voices to find the matching one
      final voices = await flutterTts.getVoices;
      if (voices is List) {
        for (var voice in voices) {
          final map = Map<String, dynamic>.from(voice);
          if (map['name'] == voiceShortName) {
            // flutter_tts setVoice expects a Map with 'name' and 'locale'
            await flutterTts.setVoice({
              'name': map['name'],
              'locale': map['locale'],
            });
            return;
          }
        }
      }
    } catch (e) {
      // Fallback: try to set voice directly (some platforms support this)
      // Ignore errors if voice not found
    }
  }

  /// For testing a specific voice in settings (matching OnlineTts API)
  Future<void> speakWithVoice(String content, String voiceShortName) async {
    if (isLinux) {
      return;
    }
    await stop();
    await flutterTts.setVolume(volume);
    await flutterTts.setSpeechRate(rate);
    await flutterTts.setPitch(pitch);
    await _applyVoice(voiceShortName);
    await flutterTts.speak(content);
  }

  @override
  Future<void> speak({String? content}) async {
    if (isLinux) {
      return;
    }
    await setAwaitOptions();
    if (content != null) {
      _currentVoiceText = content;
    }
    if (_currentVoiceText == null) {
      // getHereFunction() is initTts() — it initialises the JS TTS position
      // but returns void.  Fetch the actual first sentence via getNextTextFunction.
      AnxLog.info('TTS speak: initialising position');
      // the reading view may still be rendering right after the page
      // opens; retry until the first sentence is available
      for (var i = 0; i < 10; i++) {
        await getHereFunction();
        _currentVoiceText = await getNextTextFunction();
        if (_currentVoiceText?.isNotEmpty ?? false) break;
        await Future.delayed(const Duration(milliseconds: 500));
      }
      AnxLog.info(
          'TTS speak: first sentence ${_currentVoiceText?.length ?? 0} chars');
    }

    // Guard: if still null or empty (e.g. WebView not ready), abort.
    if (_currentVoiceText == null || _currentVoiceText!.isEmpty) {
      return;
    }

    await flutterTts.setVolume(volume);
    await flutterTts.setSpeechRate(rate);
    await flutterTts.setPitch(pitch);

    // Apply the saved voice model
    final selectedVoice = SystemTtsProvider().resolveVoice(null);
    await _applyVoice(selectedVoice);

    await flutterTts.speak(_currentVoiceText!);

    if (!isAndroid && ttsStateNotifier.value == TtsStateEnum.playing) {
      _currentVoiceText = await getNextTextFunction();
      speak();
    }
  }

  @override
  Future<dynamic> stop() async {
    updateTtsState(TtsStateEnum.stopped);
    _stopWatchdog();
    if (isLinux) {
      _currentVoiceText = null;
      return null;
    }
    final result = await _ignoreMissingPlugin(() => flutterTts.stop());
    _currentVoiceText = null;
    return result;
  }

  @override
  Future<void> pause() async {
    if (isLinux) {
      updateTtsState(TtsStateEnum.paused);
      return;
    }
    final result = await _ignoreMissingPlugin(() => flutterTts.stop());
    if (result == 1) {
      updateTtsState(TtsStateEnum.paused);
    }
  }

  @override
  Future<void> resume() async {
    if (isLinux) {
      return;
    }
    _startWatchdog();
    if (isAndroid) {
      speak(content: _prevVoiceText);
      return;
    }
    speak(content: _currentVoiceText);
  }

  @override
  Future<void> prev() async {
    if (restarting) {
      return;
    }
    restarting = true;
    await stop();
    _currentVoiceText = await getPrevTextFunction();
    speak();
    restarting = false;
  }

  @override
  Future<void> next() async {
    if (restarting) {
      return;
    }
    restarting = true;
    await stop();
    _currentVoiceText = await getNextTextFunction();
    speak();
    restarting = false;
  }

  @override
  Future<void> restart() async {
    if (restarting) {
      return;
    }
    restarting = true;
    await stop();
    speak();
    restarting = false;
  }

  @override
  Future<List<TtsVoice>> getVoices() async {
    if (isLinux) {
      return [];
    }
    try {
      dynamic voices = await flutterTts.getVoices;
      if (voices is List) {
        return voices.map((e) {
          final map = Map<String, dynamic>.from(e);
          return TtsVoice(
              shortName: map['name'] ?? '',
              name: map['name'] ?? '',
              locale: map['locale']?.replaceAll('_', '-') ?? '',
              gender: map['gender']?.toString().toLowerCase() ?? '',
              rawData: map);
        }).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
  }

  Future<T?> _ignoreMissingPlugin<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on MissingPluginException {
      return null;
    }
  }
}
