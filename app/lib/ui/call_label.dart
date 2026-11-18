import 'package:flutter/material.dart';

import '../chat/local_doc.dart';
import 'theme.dart';

String durationLabel(int ms) {
  final s = ms ~/ 1000;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Chữ mô tả một `CallEvent` (dòng xem trước và dòng trong chat).
String callLabel(CallInfo c, {required bool mine}) => switch (c.kind) {
  CallInfo.started => mine ? 'Bạn đã gọi' : 'Cuộc gọi đến',
  CallInfo.ended => c.durationMs > 0 ? 'Cuộc gọi · ${durationLabel(c.durationMs)}' : 'Cuộc gọi đã kết thúc',
  CallInfo.missed => 'Cuộc gọi nhỡ',
  _ => 'Cuộc gọi',
};

/// Dòng hệ thống giữa khung chat cho một cuộc gọi. Cuộc gọi nhỡ màu đỏ như danh sách cuộc gọi (spec S-14).
class CallLine extends StatelessWidget {
  const CallLine(this.call, {super.key, required this.mine});
  final CallInfo call;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final missed = call.kind == CallInfo.missed;
    final color = missed ? const Color(0xFFB91C1C) : Ui.muted;
    return Padding(
      key: Key('call-${call.callId}-${call.kind}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(missed ? Icons.call_missed : Icons.videocam_outlined, size: 16, color: color),
          const SizedBox(width: 6),
          Text(callLabel(call, mine: mine), style: TextStyle(fontSize: 13, color: color)),
        ],
      ),
    );
  }
}
