import 'dart:async';

import 'package:flutter/foundation.dart';

/// Global state of a running folder import, exposed as a stream so a small
/// floating progress bar (and the shelf) can follow along without any
/// blocking dialog. Supports pause / resume / cancel: the import loop checks
/// the gate between items, so stopping is always clean — books already
/// imported stay, the rest can be picked up by re-importing the folder.
enum ImportPhase { idle, copying, importing, paused, done, failed }

class ImportProgress {
  const ImportProgress({
    this.phase = ImportPhase.idle,
    this.folderName = '',
    this.copied = 0,
    this.total = 0,
    this.imported = 0,
    this.failed = 0,
    this.message = '',
  });

  final ImportPhase phase;
  final String folderName;
  final int copied;
  final int total;
  final int imported;
  final int failed;
  final String message;

  ImportProgress copyWith({
    ImportPhase? phase,
    String? folderName,
    int? copied,
    int? total,
    int? imported,
    int? failed,
    String? message,
  }) {
    return ImportProgress(
      phase: phase ?? this.phase,
      folderName: folderName ?? this.folderName,
      copied: copied ?? this.copied,
      total: total ?? this.total,
      imported: imported ?? this.imported,
      failed: failed ?? this.failed,
      message: message ?? this.message,
    );
  }
}

class ImportProgressService {
  ImportProgressService._();

  static final ImportProgressService instance = ImportProgressService._();

  final ValueNotifier<ImportProgress> state =
      ValueNotifier(const ImportProgress(phase: ImportPhase.idle));

  /// Set between items of the import loop; paused keeps the loop waiting.
  Completer<void>? _pauseGate;
  bool _cancelRequested = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isActive {
    final p = state.value.phase;
    return p == ImportPhase.copying ||
        p == ImportPhase.importing ||
        p == ImportPhase.paused;
  }

  void start(String folderName, int total) {
    _cancelRequested = false;
    _pauseGate = null;
    _lastNotify = DateTime.now();
    state.value = ImportProgress(
      phase: ImportPhase.copying,
      folderName: folderName,
      total: total,
    );
  }

  void update({
    ImportPhase? phase,
    int? copied,
    int? imported,
    int? failed,
    String? message,
  }) {
    // throttle notifications: per-book updates at import speed flooded the
    // UI thread on real devices (pill rebuild + listeners each tick)
    final now = DateTime.now();
    final isTerminal = phase == ImportPhase.done ||
        phase == ImportPhase.failed ||
        phase == ImportPhase.paused;
    if (!isTerminal &&
        now.difference(_lastNotify).inMilliseconds < 300 &&
        phase == null) {
      return;
    }
    _lastNotify = now;
    state.value = state.value.copyWith(
      phase: phase,
      copied: copied,
      imported: imported,
      failed: failed,
      message: message,
    );
  }

  /// Called by the import loop between items. Returns false when the user
  /// cancelled — the loop must stop immediately.
  Future<bool> checkpoint() async {
    if (_cancelRequested) return false;
    final gate = _pauseGate;
    if (gate != null) {
      state.value =
          state.value.copyWith(phase: ImportPhase.paused);
      await gate.future;
      if (!_cancelRequested) {
        state.value =
            state.value.copyWith(phase: ImportPhase.importing);
      }
    }
    return !_cancelRequested;
  }

  void pause() {
    _pauseGate ??= Completer<void>();
  }

  void resume() {
    _pauseGate?.complete();
    _pauseGate = null;
  }

  /// Request cancellation; returns true when a pause gate needs no manual
  /// resume (the checkpoint resolves as cancelled).
  void cancel() {
    _cancelRequested = true;
    if (_pauseGate != null && !_pauseGate!.isCompleted) {
      _pauseGate!.complete();
    }
    _pauseGate = null;
  }

  void finish({bool failed = false, String message = ''}) {
    state.value = state.value.copyWith(
      phase: failed ? ImportPhase.failed : ImportPhase.done,
      message: message,
    );
    // auto-clear shortly so the floating bar fades away
    Timer(const Duration(seconds: 4), () {
      if (state.value.phase == ImportPhase.done ||
          state.value.phase == ImportPhase.failed) {
        state.value = const ImportProgress(phase: ImportPhase.idle);
      }
    });
  }
}
