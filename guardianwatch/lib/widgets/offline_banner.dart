// ─── lib/widgets/offline_banner.dart ─────────────────────────────────────────

import 'package:flutter/material.dart';

/// A full-width banner shown when the app is displaying cached data.
///
/// Announces itself to screen readers via a live region.
class OfflineBanner extends StatelessWidget {
  /// Message shown in the banner. Defaults to a generic offline notice.
  final String message;

  const OfflineBanner({
    super.key,
    this.message = "You're offline — showing cached data",
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: Material(
        color: colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Row(
            children: [
              Icon(
                Icons.wifi_off,
                size: 16,
                color: colorScheme.onTertiaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: colorScheme.onTertiaryContainer,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
