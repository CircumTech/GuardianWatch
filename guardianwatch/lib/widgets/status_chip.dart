// ─── lib/widgets/status_chip.dart ────────────────────────────────────────────

import 'package:flutter/material.dart';
import '../providers/ble_provider.dart';

class BleStatusChip extends StatelessWidget {
  final BleStatus status;
  const BleStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      BleStatus.connected => ('Connected', Colors.green),
      BleStatus.connecting => ('Connecting…', Colors.orange),
      BleStatus.scanning => ('Scanning…', Colors.blue),
      BleStatus.disconnected => ('Disconnected', Colors.grey),
      BleStatus.error => ('Error', Colors.red),
      BleStatus.idle => ('Not paired', Colors.grey),
    };
    return Chip(
      avatar: CircleAvatar(backgroundColor: color, radius: 6),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      padding: EdgeInsets.zero,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
