// ─── lib/widgets/status_chip.dart ────────────────────────────────────────────

import 'package:flutter/material.dart';
import '../providers/ble_provider.dart';

class BleStatusChip extends StatelessWidget {
  final BleStatus status;
  const BleStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    String label;
    Color color;

    switch (status) {
      case BleStatus.connected:
        label = 'Connected';
        color = Colors.green;
        break;
      case BleStatus.connecting:
        label = 'Connecting…';
        color = Colors.orange;
        break;
      case BleStatus.scanning:
        label = 'Scanning…';
        color = Colors.blue;
        break;
      case BleStatus.disconnected:
        label = 'Disconnected';
        color = Colors.grey;
        break;
      case BleStatus.error:
        label = 'Error';
        color = Colors.red;
        break;
      case BleStatus.idle:
        label = 'Not paired';
        color = Colors.grey;
        break;
    }

    return Chip(
      avatar: CircleAvatar(backgroundColor: color, radius: 6),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      padding: EdgeInsets.zero,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}