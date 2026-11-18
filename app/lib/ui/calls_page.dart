import 'package:flutter/material.dart';

import '../chat/call_history.dart';
import '../chat/chat_engine.dart';
import '../gen/chat/v1/common.pbenum.dart' show CallKind;
import 'desktop_shell.dart' show desktopBreakpoint;
import 'theme.dart';

const _red = Color(0xFFDC2626);

/// "Hôm qua, 20:15" / "Thứ hai, 18:40" / "12/11, 09:02", kèm " · 12 phút" khi có thời lượng (docs/ui/Mobile-Calls).
String callWhen(CallEntry e, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch(e.tsMs);
  String two(int v) => v.toString().padLeft(2, '0');
  final day = shortTime(e.tsMs, now: now);
  final clock = '${two(t.hour)}:${two(t.minute)}';
  final head = RegExp(r'^\d\d:\d\d$').hasMatch(day) ? 'Hôm nay, $clock' : '$day, $clock';
  if (e.durationMs <= 0 || e.missed) return head;
  final min = (e.durationMs / 60000).ceil();
  return '$head · $min phút';
}

/// Lịch sử cuộc gọi (S-14): bộ lọc Tất cả/Nhỡ, hàng 68, nút gọi lại. Mobile là trang riêng; Desktop dùng cột 480.
class CallsView extends StatefulWidget {
  const CallsView({super.key, required this.entries, required this.nameOf, this.onOpen, this.onCallBack, this.onBack, this.desktop = false});
  final List<CallEntry> entries;
  final String Function(String convHex) nameOf;
  final ValueChanged<CallEntry>? onOpen, onCallBack;
  final VoidCallback? onBack;
  final bool desktop;

  @override
  State<CallsView> createState() => _CallsViewState();
}

class _CallsViewState extends State<CallsView> {
  bool _missedOnly = false;

  Widget _chip(String label, bool on, Key key, VoidCallback tap) => GestureDetector(
    key: key,
    onTap: tap,
    child: Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: on ? Ui.text : Ui.surface, borderRadius: BorderRadius.circular(18)),
      child: Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: on ? Colors.white : Ui.text)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final list = widget.entries.where((e) => !_missedOnly || e.missed).toList();
    final pad = widget.desktop ? 32.0 : 20.0;
    return Material(
      color: Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(widget.onBack != null ? 8 : pad, widget.desktop ? 32 : 20, pad, widget.desktop ? 16 : 12),
              child: Row(
                children: [
                  if (widget.onBack != null) IconButton(key: const Key('calls-back'), tooltip: 'Quay lại', icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
                  Text('Cuộc gọi', key: const Key('calls-title'), style: TextStyle(fontSize: widget.desktop ? 24 : 28, fontWeight: FontWeight.w600, letterSpacing: -0.3, height: 1.2, color: Ui.text)),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
              child: Row(
                children: [
                  _chip('Tất cả', !_missedOnly, const Key('calls-filter-all'), () => setState(() => _missedOnly = false)),
                  const SizedBox(width: 8),
                  _chip('Nhỡ', _missedOnly, const Key('calls-filter-missed'), () => setState(() => _missedOnly = true)),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? Center(child: Text(_missedOnly ? 'Không có cuộc gọi nhỡ' : 'Chưa có cuộc gọi nào', key: const Key('calls-empty'), style: const TextStyle(fontSize: 15, color: Ui.muted)))
                  : ListView.builder(
                      padding: EdgeInsets.symmetric(horizontal: pad),
                      itemCount: list.length,
                      itemBuilder: (context, i) => _Row(entry: list[i], name: widget.nameOf(list[i].convHex), onOpen: widget.onOpen, onCallBack: widget.onCallBack),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.entry, required this.name, this.onOpen, this.onCallBack});
  final CallEntry entry;
  final String name;
  final ValueChanged<CallEntry>? onOpen, onCallBack;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final color = e.missed ? _red : Ui.muted;
    return SizedBox(
      key: Key('call-row-${e.callId}'),
      height: 68,
      child: InkWell(
        onTap: onOpen == null ? null : () => onOpen!(e),
        child: Row(
          children: [
            Avatar(name, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: e.missed ? _red : Ui.text)),
                  Row(
                    children: [
                      Icon(e.missed ? Icons.call_missed : (e.outgoing ? Icons.call_made : Icons.call_received), size: 14, color: color),
                      const SizedBox(width: 4),
                      Flexible(child: Text(callWhen(e), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: color))),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(
              width: Ui.tap,
              height: Ui.tap,
              child: IconButton(key: Key('call-back-${e.callId}'), tooltip: 'Gọi lại', onPressed: onCallBack == null ? null : () => onCallBack!(e), icon: const Icon(Icons.videocam_outlined, color: Ui.primary)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Trang lịch sử cuộc gọi nối với engine. `onOpen` mở hội thoại (Desktop chuyển về khung chat; Mobile mở ChatPage).
class CallsPage extends StatelessWidget {
  const CallsPage({super.key, required this.engine, this.onOpen, this.onBack, this.desktop = false});
  final ChatEngine engine;
  final ValueChanged<String>? onOpen;
  final VoidCallback? onBack;
  final bool desktop;

  String _name(String convHex) => engine.conversations.where((c) => c.hexId == convHex).firstOrNull?.title ?? 'Cuộc trò chuyện';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: engine,
    builder: (context, _) => CallsView(
      desktop: desktop || MediaQuery.sizeOf(context).width >= desktopBreakpoint,
      entries: engine.callHistory(),
      nameOf: _name,
      onBack: onBack,
      onOpen: onOpen == null ? null : (e) => onOpen!(e.convHex),
      onCallBack: (e) async {
        final messenger = ScaffoldMessenger.of(context);
        try {
          await engine.startCall(e.convHex, CallKind.CALL_KIND_VIDEO);
        } on Exception {
          if (engine.calls.error == null) messenger.showSnackBar(const SnackBar(content: Text('Không gọi được lúc này')));
        }
      },
    ),
  );
}
