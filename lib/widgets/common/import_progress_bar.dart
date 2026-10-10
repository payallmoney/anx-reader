import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/import_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Small non-blocking import progress pill shown above the app content
/// while a folder import runs. Tapping it expands pause / resume / cancel.
class ImportProgressBar extends ConsumerStatefulWidget {
  const ImportProgressBar({super.key});

  @override
  ConsumerState<ImportProgressBar> createState() => _ImportProgressBarState();
}

class _ImportProgressBarState extends ConsumerState<ImportProgressBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary: the pill rebuilds on every progress tick; isolate
    // those repaints from the navigator/app underneath (was freezing the
    // UI on real devices during imports)
    return RepaintBoundary(
      child: ValueListenableBuilder<ImportProgress>(
        valueListenable: ImportProgressService.instance.state,
        builder: (context, p, _) {
          final active = p.phase == ImportPhase.copying ||
              p.phase == ImportPhase.importing ||
              p.phase == ImportPhase.paused;
          if (!active) return const SizedBox.shrink();
          return _buildPill(context, p);
        },
      ),
    );
  }

  Widget _buildPill(BuildContext context, ImportProgress p) {
    {
      final l10n = L10n.of(context);
      final total = p.total <= 0 ? 1 : p.total;
      final doneCount = p.phase == ImportPhase.copying ? p.copied : p.imported;
      final progressValue = (doneCount / total).clamp(0.0, 1.0);

      return Align(
        alignment: Alignment.topCenter,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(24),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: p.phase == ImportPhase.paused
                                ? Icon(Icons.pause_circle_outline,
                                    size: 16,
                                    color: Theme.of(context).colorScheme.tertiary)
                                : CircularProgressIndicator(
                                    strokeWidth: 2,
                                    value: p.phase == ImportPhase.copying
                                        ? progressValue
                                        : null,
                                  ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            p.phase == ImportPhase.copying
                                ? l10n.importCopyingBooks(p.copied, p.total)
                                : p.phase == ImportPhase.paused
                                    ? l10n.importPaused(p.imported, p.total)
                                    : l10n.importImportingN(p.imported, p.total),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more,
                            size: 16,
                            color: Theme.of(context).hintColor,
                          ),
                        ],
                      ),
                      if (_expanded)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    minimumSize: const Size(0, 32)),
                                onPressed: () {
                                  if (p.phase == ImportPhase.paused) {
                                    ImportProgressService.instance.resume();
                                  } else {
                                    ImportProgressService.instance.pause();
                                  }
                                },
                                child: Text(p.phase == ImportPhase.paused
                                    ? l10n.commonResume
                                    : l10n.commonPause),
                              ),
                              TextButton(
                                style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    minimumSize: const Size(0, 32)),
                                onPressed: () =>
                                    ImportProgressService.instance.cancel(),
                                child: Text(l10n.commonCancel),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
  }
}
