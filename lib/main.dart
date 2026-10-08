import 'dart:async';
import 'dart:io';

import 'package:anx_reader/utils/platform_utils.dart';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/enums/sync_direction.dart';
import 'package:anx_reader/enums/sync_trigger.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/window_info.dart';
import 'package:anx_reader/page/home_page.dart';
import 'package:anx_reader/page/migration_page.dart';
import 'package:anx_reader/service/book_player/book_player_server.dart';
import 'package:anx_reader/service/network/http_proxy_overrides.dart';
import 'package:anx_reader/service/tts/system_tts.dart';
import 'package:anx_reader/service/tts/tts_service.dart' as tts_service;
import 'package:anx_reader/service/tts/tts_handler.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/utils/saf_tree.dart';
import 'package:anx_reader/page/home_page/bookshelf_page.dart';
import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/utils/get_path/macos_migration.dart';
import 'package:anx_reader/utils/color_scheme.dart';
import 'package:anx_reader/utils/error/common.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/window_position_validator.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:heroine/heroine.dart';
import 'package:provider/provider.dart' as provider;
import 'package:window_manager/window_manager.dart';
import 'package:webview_cef/webview_cef.dart' as cef;

final navigatorKey = GlobalKey<NavigatorState>();
late AudioHandler audioHandler;
final heroineController = HeroineController();

/// Whether macOS data migration is needed (checked at startup)
bool _needsMigration = false;
MigrationCheckResult? _migrationCheckResult;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Prefs().initPrefs();
  HttpOverrides.global = AnxHttpProxyOverrides();

  // Initialize desktop window with validated position
  if (AnxPlatform.isDesktop) {
    await initializeDesktopWindow();
  }

  if (AnxPlatform.isLinux) {
    await cef.WebviewManager().initialize();
  }

  // Check if migration is needed before initializing paths
  if (AnxPlatform.isMacOS) {
    _migrationCheckResult = await checkMigrationNeeded();
    _needsMigration = _migrationCheckResult?.needsMigration ?? false;
  }

  // If no migration needed, initialize paths normally
  if (!_needsMigration) {
    initBasePath();
    AnxLog.init();
    AnxError.init();
    await DBHelper().initDB();
  }

  Server().start();

  audioHandler = await AudioService.init(
    builder: () => TtsHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.anx.reader.tts.channel.audio',
      androidNotificationChannelName: 'ANX Reader TTS',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

  SmartDialog.config.custom = SmartConfigCustom(
    maskColor: Colors.black.withAlpha(35),
    useAnimation: !Prefs().eInkMode,
    animationType: SmartAnimationType.centerFade_otherSlide,
  );

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp>
    with WidgetsBindingObserver, WindowListener {
  static const Locale _englishFallbackLocale = Locale('en');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    if (AnxPlatform.isAndroid) {
      // poll so warm starts (onNewIntent with a new auto_tts_path) are
      // picked up too; consumeAutoTtsPath returns null when nothing pending
      _autoTestTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        _maybeRunAutoTtsTest();
        _maybeRunAutoImportFolder();
        _maybeRunAutoSafImport();
        _maybeActivateForcedTtsTimeout();
      });
    }
  }

  Timer? _autoTestTimer;

  /// adb-driven narration test: `am start ... --es auto_tts_path <file>`
  /// imports the book and starts playback without any UI interaction.
  Future<void> _maybeRunAutoTtsTest() async {
    await Future.delayed(const Duration(seconds: 2));
    final path = await SafTree.consumeAutoTtsPath();
    if (path == null || path.isEmpty) return;
    final context = navigatorKey.currentContext;
    if (context == null) return;

    debugPrint('AUTO-TTS: importing $path');
    final md5 = await MD5Service.calculateFileMd5(path);
    Book? book =
        md5 != null ? await bookDao.getBookByMd5(md5) : null;
    if (book == null || book.isDeleted) {
      // importBook skips the duplicate/confirm dialogs used by the shelf UI
      try {
        await importBook(File(path), ref);
      } catch (e, s) {
        debugPrint('AUTO-TTS: import error: $e / $s');
      }
      for (var i = 0; i < 100; i++) {
        await Future.delayed(const Duration(milliseconds: 300));
        final books = await bookDao.selectNotDeleteBooks();
        if (books.isNotEmpty) {
          book = books.first;
          break;
        }
      }
    }
    if (book == null || book.isDeleted) {
      debugPrint('AUTO-TTS: import failed');
      return;
    }
    debugPrint('AUTO-TTS: opening book ${book.id}');
    // do not await: pushToReadingPage completes only when reading ends
    unawaited(pushToReadingPage(ref, context, book));
    // the reading webview may take a while on first launch; retry
    var player = epubPlayerKey.currentState;
    for (var i = 0; i < 90 && player == null; i++) {
      await Future.delayed(const Duration(seconds: 2));
      player = epubPlayerKey.currentState;
    }
    if (player == null) {
      debugPrint('AUTO-TTS: player not ready');
      return;
    }
    // pick any available system voice so narration can start unattended
    try {
      final voices = await SystemTts().getVoices();
      if (voices.isNotEmpty) {
        // prefer an offline voice: network voices stall the engine when
        // the emulator has no connectivity
        final local = voices
            .where((v) => v.shortName.contains('local'))
            .toList();
        final pick = local.isNotEmpty ? local.first : voices.first;
        tts_service.SystemTtsProvider().setSelectedVoice(pick.shortName);
        debugPrint('AUTO-TTS: voice ${pick.shortName}');
      }
    } catch (e) {
      debugPrint('AUTO-TTS: voice pick failed: $e');
    }
    final forceTimeout =
        await SafTree.consumeAutoExtraString('auto_tts_force_timeout');
    if (forceTimeout == '1') {
      EpubPlayerState.debugForceTtsTimeout = true;
      debugPrint('AUTO-TTS: forcing webview timeouts (dart fallback test)');
    }
    await TtsHandler().init(player.initTts, player.ttsNext, player.ttsPrev);
    debugPrint('AUTO-TTS: starting playback');
    await audioHandler.play();
  }

  /// adb-driven SAF import test: `am start ... --es auto_import_saf
  /// <folderPath>` builds the SAF tree uri for a public-storage folder
  /// and runs the real SAF folder-import path (DocumentFile enumeration
  /// + streaming copy), exactly like the in-app folder picker.
  Future<void> _maybeRunAutoSafImport() async {
    final folder = await SafTree.consumeAutoExtraString('auto_import_saf');
    if (folder.isEmpty) return;
    var sub = folder;
    const prefix = '/storage/emulated/0/';
    if (folder.startsWith(prefix)) {
      sub = folder.substring(prefix.length);
    } else if (folder.startsWith('/sdcard/')) {
      sub = folder.substring('/sdcard/'.length);
    } else {
      debugPrint('AUTO-SAF: folder must be under $prefix');
      return;
    }
    final encoded = Uri.encodeComponent('primary:$sub');
    final treeUri =
        'content://com.android.externalstorage.documents/tree/$encoded';
    debugPrint('AUTO-SAF: importing tree $treeUri');
    try {
      final n = await importSafTreeCore(treeUri, ref);
      debugPrint('AUTO-SAF: imported $n books');
    } catch (e, s) {
      debugPrint('AUTO-SAF: error $e / $s');
    }
  }

  /// Runtime switch: `am start --es auto_tts_force_timeout 1` while
  /// narration is running simulates the WebView freezing mid-book (the
  /// real-device screen-off timing) without restarting playback.
  Future<void> _maybeActivateForcedTtsTimeout() async {
    if (EpubPlayerState.debugForceTtsTimeout) return;
    final v = await SafTree.consumeAutoExtraString('auto_tts_force_timeout');
    if (v == '1') {
      EpubPlayerState.debugForceTtsTimeout = true;
      debugPrint('AUTO-TTS: forcing webview timeouts NOW (mid-book freeze)');
    }
  }

  /// adb-driven folder import test: `am start ... --es auto_import_folder
  /// <dir>` imports every book under the folder into file/<folder>/ and
  /// groups them on the shelf, mirroring the SAF folder import flow.
  Future<void> _maybeRunAutoImportFolder() async {
    final path = await SafTree.consumeAutoImportFolder();
    if (path == null || path.isEmpty) return;
    final context = navigatorKey.currentContext;
    if (context == null) return;

    debugPrint('AUTO-IMPORT: folder $path');
    try {
      final files = await collectBookFiles([path]);
      debugPrint('AUTO-IMPORT: ${files.length} books found');
      if (files.isEmpty) return;
      final dirName = path
          .split(Platform.pathSeparator)
          .last
          .replaceAll(RegExp(r'[<>:"/\\|?*#%&@$^+=\[\]{}`~;!]'), '_')
          .trim();
      final subDir = dirName.isEmpty ? 'file' : 'file/$dirName';
      final destDir = getBasePath(subDir);
      await Directory(destDir).create(recursive: true);
      final md5s = <String>[];
      for (final src in files) {
        final base = src.path.split(Platform.pathSeparator).last;
        final dest = '$destDir${Platform.pathSeparator}$base';
        await src.copy(dest);
        final md5 = await MD5Service.calculateFileMd5(dest);
        await importBook(File(dest), ref,
            precomputedMd5: md5, storageSubDir: subDir);
        if (md5 != null) md5s.add(md5);
      }
      await groupImportedBooks(dirName, md5s, ref);
      debugPrint('AUTO-IMPORT: done, grouped into "$dirName"');
    } catch (e, s) {
      debugPrint('AUTO-IMPORT: error $e / $s');
    }
  }

  @override
  void dispose() {
    _autoTestTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    await Server().stop();
    await webViewEnvironment?.dispose();
    webViewEnvironment = null;
    if (AnxPlatform.isLinux) {
      await cef.WebviewManager().quit();
    }
    await DBHelper.close();
    await windowManager.destroy();
  }

  @override
  Future<void> onWindowMoved() async {
    await _updateWindowInfo();
  }

  @override
  Future<void> onWindowMaximize() async {
    await _updateWindowInfo();
  }

  @override
  Future<void> onWindowUnmaximize() async {
    await _updateWindowInfo();
  }

  @override
  Future<void> onWindowResized() async {
    await _updateWindowInfo();
  }

  Future<void> _updateWindowInfo() async {
    if (!AnxPlatform.isDesktop) {
      return;
    }
    final windowOffset = await windowManager.getPosition();
    final windowSize = await windowManager.getSize();
    final isMaximized = await windowManager.isMaximized();

    Prefs().windowInfo = WindowInfo(
        x: windowOffset.dx,
        y: windowOffset.dy,
        width: windowSize.width,
        height: windowSize.height,
        isMaximized: isMaximized);
    AnxLog.info('onWindowClose: Offset: $windowOffset, Size: $windowSize');
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (Prefs().webdavStatus) {
        ref
            .read(syncProvider.notifier)
            .syncData(SyncDirection.both, ref, trigger: SyncTrigger.auto);
      }
    } else if (state == AppLifecycleState.resumed) {
      if (AnxPlatform.isIOS) {
        Server().start();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return provider.MultiProvider(
      providers: [
        provider.ChangeNotifierProvider(
          create: (_) => Prefs(),
        ),
      ],
      child: provider.Consumer<Prefs>(
        builder: (context, prefsNotifier, child) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            scrollBehavior: ScrollConfiguration.of(context).copyWith(
              physics: const BouncingScrollPhysics(),
              // dragDevices: {
              //   PointerDeviceKind.touch,
              //   PointerDeviceKind.mouse,
              // },
            ),
            navigatorObservers: [
              FlutterSmartDialog.observer,
              heroineController
            ],
            builder: FlutterSmartDialog.init(),
            navigatorKey: navigatorKey,
            locale: prefsNotifier.locale,
            localeListResolutionCallback: _resolveLocale,
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            title: 'Anx Reader',
            themeMode: prefsNotifier.themeMode,
            theme: colorSchema(prefsNotifier, context, Brightness.light),
            darkTheme: colorSchema(prefsNotifier, context, Brightness.dark),
            home: _needsMigration
                ? _MigrationWrapper(
                    migrationCheckResult: _migrationCheckResult!)
                : const HomePage(),
          );
        },
      ),
    );
  }

  Locale _resolveLocale(
    List<Locale>? preferredLocales,
    Iterable<Locale> supportedLocales,
  ) {
    if (preferredLocales == null || preferredLocales.isEmpty) {
      return _englishFallbackLocale;
    }

    final Locale resolvedLocale = basicLocaleListResolution(
      preferredLocales,
      supportedLocales,
    );

    final bool hasMatch = preferredLocales.any((Locale preferredLocale) {
      return supportedLocales.any((Locale supportedLocale) {
        if (preferredLocale.languageCode != supportedLocale.languageCode) {
          return false;
        }

        final String? preferredCountryCode = preferredLocale.countryCode;
        final String? supportedCountryCode = supportedLocale.countryCode;

        return preferredCountryCode == null ||
            supportedCountryCode == null ||
            preferredCountryCode == supportedCountryCode;
      });
    });

    return hasMatch ? resolvedLocale : _englishFallbackLocale;
  }
}

/// Widget that wraps the migration flow on macOS.
/// Shows MigrationPage during migration, then navigates to HomePage.
class _MigrationWrapper extends StatefulWidget {
  final MigrationCheckResult migrationCheckResult;

  const _MigrationWrapper({required this.migrationCheckResult});

  @override
  State<_MigrationWrapper> createState() => _MigrationWrapperState();
}

class _MigrationWrapperState extends State<_MigrationWrapper> {
  bool _migrationComplete = false;

  Future<void> _onMigrationComplete() async {
    // Initialize paths and DB after migration
    initBasePath();
    AnxLog.init();
    AnxError.init();
    await DBHelper().initDB();

    if (mounted) {
      setState(() {
        _migrationComplete = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_migrationComplete) {
      return const HomePage();
    }
    return MigrationPage(onMigrationComplete: _onMigrationComplete);
  }
}
