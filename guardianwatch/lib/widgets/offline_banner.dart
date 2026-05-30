// ─── lib/widgets/offline_banner.dart ─────────────────────────────────────────

import 'package:flutter/material.dart';

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.orange.shade800,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: const Row(
        children: [
          Icon(Icons.wifi_off, size: 16, color: Colors.white),
          SizedBox(width: 8),
          Text(
            'You\'re offline — showing cached data',
            style: TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
