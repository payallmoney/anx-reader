/// While a folder import runs, its headless metadata webviews compete with
/// the reader's webview for the main thread — reading stutters or freezes.
/// This gate pauses metadata extraction whenever the user is inside the
/// reader and resumes when they leave; the copy phase (plain IO) is not
/// affected.
///
/// The reader sets [reading] on enter/leave (EpubPlayerState lifecycle);
/// import code awaits [waitWhileReading] before spawning a webview.
class ImportReadingGate {
  ImportReadingGate._();

  /// Set by the reader page: true while a book is open on screen.
  static bool reading = false;

  /// Wait until the reader is closed (polling keeps this trivially
  /// correct). No-op when the user is not reading. [maxWait] bounds the
  /// wait so an abandoned reader session cannot stall an import forever —
  /// after it elapses the import proceeds anyway (a brief stutter beats a
  /// silently stalled import).
  static Future<void> waitWhileReading({
    Duration maxWait = const Duration(minutes: 30),
  }) async {
    if (!reading) return;
    final deadline = DateTime.now().add(maxWait);
    while (reading) {
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
}
