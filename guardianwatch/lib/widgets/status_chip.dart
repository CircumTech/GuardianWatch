// ─── lib/widgets/status_chip.dart ────────────────────────────────────────────

import 'package:flutter/material.dart';

import '../providers/ble_provider.dart';

/// A compact chip that shows the current BLE connection status.
///
/// Status is conveyed by both an icon and a color, per accessibility
/// guidance.
class BleStatusChip extends StatelessWidget {
  final BleStatus status;

  const BleStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final data = _resolve(colorScheme);

    return Semantics(
      container: true,
      label: 'Guardian Watch connection status: ${data.label}',
      child: Chip(
        avatar: Icon(data.icon, size: 14, color: data.color),
        label: Text(
          data.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: data.color,
          ),
        ),
        backgroundColor: data.color.withValues(alpha: 0.10),
        side: BorderSide(color: data.color.withValues(alpha: 0.20)),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  _ChipData _resolve(ColorScheme colorScheme) {
    switch (status) {
      case BleStatus.connected:
        return _ChipData(
          label: 'Connected',
          color: colorScheme.primary,
          icon: Icons.bluetooth_connected,
        );
      case BleStatus.connecting:
        return _ChipData(
          label: 'Connecting',
          color: Colors.orange,
          icon: Icons.bluetooth_searching,
        );
      case BleStatus.scanning:
        return _ChipData(
          label: 'Scanning',
          color: Colors.blue,
          icon: Icons.search,
        );
      case BleStatus.disconnected:
        return _ChipData(
          label: 'Disconnected',
          color: colorScheme.onSurface.withValues(alpha: 0.55),
          icon: Icons.bluetooth_disabled,
        );
      case BleStatus.error:
        return _ChipData(
          label: 'Error',
          color: colorScheme.error,
          icon: Icons.error_outline,
        );
      case BleStatus.idle:
        return _ChipData(
          label: 'Not paired',
          color: colorScheme.onSurface.withValues(alpha: 0.55),
          icon: Icons.bluetooth,
        );
    }
  }
}

class _ChipData {
  final String label;
  final Color color;
  final IconData icon;

  const _ChipData({
    required this.label,
    required this.color,
    required this.icon,
  });
}
