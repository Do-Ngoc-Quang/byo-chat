import 'local_doc.dart';

/// Một dòng của lịch sử cuộc gọi (S-14): một cuộc gọi dù có nhiều `CallEvent` (bắt đầu, kết thúc của mỗi bên, nhỡ).
class CallEntry {
  const CallEntry({required this.callId, required this.convHex, required this.tsMs, required this.missed, required this.outgoing, required this.durationMs});
  final String callId, convHex;
  final int tsMs, durationMs;
  final bool missed, outgoing;
}

/// Dựng lịch sử từ các tin `CallEvent` đã giải mã trên máy (không có RPC riêng, spec man-hinh.md S-14).
/// Nhỡ nếu có mục nhỡ và không có mục kết thúc; gọi đi nếu chính ta là bên bắt đầu; thời lượng là lớn nhất trong các mục
/// kết thúc (hai bên mỗi bên ghi một mục). Mới nhất lên đầu.
List<CallEntry> buildCallHistory(Map<String, List<ChatMessage>> msgs) {
  final out = <CallEntry>[];
  msgs.forEach((convHex, list) {
    final groups = <String, List<ChatMessage>>{};
    for (final m in list) {
      final c = m.call;
      if (c != null) groups.putIfAbsent(c.callId, () => []).add(m);
    }
    groups.forEach((callId, ms) {
      final ended = ms.where((m) => m.call!.kind == CallInfo.ended).toList();
      final missed = ended.isEmpty && ms.any((m) => m.call!.kind == CallInfo.missed);
      final dur = ended.fold<int>(0, (a, m) => m.call!.durationMs > a ? m.call!.durationMs : a);
      final ts = ms.map((m) => m.tsMs).reduce((a, b) => a < b ? a : b);
      out.add(CallEntry(callId: callId, convHex: convHex, tsMs: ts, missed: missed, outgoing: ms.any((m) => m.mine && m.call!.kind == CallInfo.started), durationMs: dur));
    });
  });
  out.sort((a, b) => b.tsMs.compareTo(a.tsMs));
  return out;
}
