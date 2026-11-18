import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/call_controller.dart';
import '../chat/chat_engine.dart';
import '../chat/local_doc.dart';
import '../gen/chat/v1/common.pbenum.dart' show CallKind;
import 'call_label.dart';
import 'desktop_shell.dart' show desktopBreakpoint;
import 'theme.dart';

// Màu riêng của màn gọi (docs/ui/Mobile-Call, Mobile-Incoming, Desktop-Call, Desktop-Incoming).
const _callTop = Color(0xFF2A3142), _callBottom = Color(0xFF151821), _selfView = Color(0xFF3A4256);
const _muted = Color(0xFFD5D8DE), _ctl = Color(0x29FFFFFF), _green = Color(0xFF16A34A);

BoxDecoration _gradient() => const BoxDecoration(
  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_callTop, _callBottom]),
);

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.label, required this.size, this.color = _ctl, this.width, this.onTap});
  final IconData icon;
  final String label;
  final double size;
  final double? width;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: onTap == null ? 0.45 : 1,
    child: Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: width ?? size,
          height: size,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size / 2)),
          child: Icon(icon, size: size >= 64 ? 28 : 26, color: Colors.white),
        ),
      ),
    ),
  );
}

/// Cuộc gọi đến (S-13). Mobile: toàn màn nền gradient; Desktop (≥ 900): thẻ nổi 420 giữa nền tối.
class IncomingCallView extends StatelessWidget {
  const IncomingCallView({super.key, required this.name, required this.video, this.onDecline, this.onAnswer});
  final String name;
  final bool video;
  final VoidCallback? onDecline, onAnswer;

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= desktopBreakpoint;
    final b = desktop ? 64.0 : 68.0;
    Widget col(Widget btn, String label) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn,
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 13, color: _muted)),
      ],
    );
    final who = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Avatar(name, size: 128),
        const SizedBox(height: 20),
        Text(
          name,
          key: const Key('incoming-name'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        const SizedBox(height: 12),
        Text(video ? 'Cuộc gọi video đến…' : 'Cuộc gọi thoại đến…', style: const TextStyle(fontSize: 15, color: _muted)),
      ],
    );
    final buttons = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        col(_RoundButton(key: const Key('call-decline'), icon: Icons.call_end, label: 'Từ chối', size: b, color: Ui.danger, onTap: onDecline), 'Từ chối'),
        const SizedBox(width: 64),
        col(_RoundButton(key: const Key('call-answer'), icon: video ? Icons.videocam : Icons.call, label: 'Trả lời', size: b, color: _green, onTap: onAnswer), 'Trả lời'),
      ],
    );
    if (desktop) {
      return Material(
        type: MaterialType.transparency,
        child: ColoredBox(
        key: const Key('incoming-call'),
        color: const Color(0xFF0E1016),
        child: Center(
          child: Container(
            width: 420,
            padding: const EdgeInsets.fromLTRB(32, 48, 32, 40),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1F2A),
              borderRadius: BorderRadius.circular(28),
              boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 60, offset: Offset(0, 24))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [who, const SizedBox(height: 40), buttons]),
          ),
        ),
      ),
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: Container(
        key: const Key('incoming-call'),
        decoration: _gradient(),
        child: Column(
          children: [
            Expanded(child: Padding(padding: const EdgeInsets.only(top: 40), child: Center(child: who))),
            Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 72), child: buttons),
          ],
        ),
      ),
    );
  }
}

/// Cuộc gọi đang diễn ra (S-12). Mic, camera, đổi camera, chia sẻ màn hình cần luồng media LiveKit nên hiện mờ
/// (docs/notes.md); chỉ nút Kết thúc chạy.
class CallView extends StatelessWidget {
  const CallView({super.key, required this.name, required this.status, this.onEnd, this.error});
  final String name, status;
  final String? error;
  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) => Material(type: MaterialType.transparency, child: _build(context));

  Widget _build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= desktopBreakpoint;
    final end = _RoundButton(key: const Key('call-end'), icon: Icons.call_end, label: 'Kết thúc cuộc gọi', size: desktop ? 56 : 60, width: desktop ? 72 : null, color: Ui.danger, onTap: onEnd);
    final stat = Text(error ?? status, key: const Key('call-status'), style: TextStyle(fontSize: desktop ? 13 : 14, color: error == null ? _muted : const Color(0xFFFCA5A5)));
    if (desktop) {
      Widget tag(String t) => Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: const Color(0x73000000), borderRadius: BorderRadius.circular(14)),
        alignment: Alignment.center,
        child: Text(t, style: const TextStyle(fontSize: 13, color: Colors.white)),
      );
      return ColoredBox(
        key: const Key('call-screen'),
        color: _callBottom,
        child: Stack(
          children: [
            Positioned(
              left: 28,
              top: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
                  const SizedBox(height: 2),
                  stat,
                ],
              ),
            ),
            Positioned(
              left: 28,
              right: 28,
              top: 88,
              bottom: 120,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_callTop, Color(0xFF1B1F2A)])),
                      child: Stack(children: [Center(child: Avatar(name, size: 120)), Positioned(left: 16, bottom: 16, child: tag(name))]),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      width: 320,
                      height: 240,
                      decoration: BoxDecoration(color: _selfView, borderRadius: BorderRadius.circular(20)),
                      child: Stack(
                        children: [
                          const Center(child: Text('Camera của bạn', style: TextStyle(fontSize: 13, color: _muted))),
                          Positioned(left: 12, bottom: 12, child: tag('Bạn')),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 104,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const _RoundButton(icon: Icons.mic_none, label: 'Tắt micro', size: 56),
                  const SizedBox(width: 16),
                  const _RoundButton(icon: Icons.videocam_outlined, label: 'Tắt camera', size: 56),
                  const SizedBox(width: 16),
                  const _RoundButton(icon: Icons.screen_share_outlined, label: 'Chia sẻ màn hình', size: 56),
                  const SizedBox(width: 16),
                  end,
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      key: const Key('call-screen'),
      decoration: _gradient(),
      child: Stack(
        children: [
          Center(child: Avatar(name, size: 128)),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 56, 20, 0),
              child: Column(
                children: [
                  Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
                  const SizedBox(height: 6),
                  stat,
                ],
              ),
            ),
          ),
          Positioned(
            right: 16,
            top: 176,
            child: Container(
              width: 104,
              height: 148,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: _selfView, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0x66FFFFFF), width: 2)),
              child: const Text('Bạn', style: TextStyle(fontSize: 12, color: _muted)),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 44),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const _RoundButton(icon: Icons.mic_none, label: 'Tắt micro', size: 60),
                  const SizedBox(width: 16),
                  const _RoundButton(icon: Icons.videocam_outlined, label: 'Tắt camera', size: 60),
                  const SizedBox(width: 16),
                  const _RoundButton(icon: Icons.cameraswitch_outlined, label: 'Đổi camera', size: 60),
                  const SizedBox(width: 16),
                  end,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Nối `CallController` với giao diện: chuông, đang gọi, và trạng thái kết thúc (tự đóng sau 2 giây).
class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.engine});
  final ChatEngine engine;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  Timer? _tick, _close;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.engine.calls.phase == CallPhase.connected) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _close?.cancel();
    super.dispose();
  }

  String _name(CallController c) {
    final conv = c.convId;
    if (conv == null) return 'Cuộc gọi';
    final h = hex(conv);
    for (final cs in widget.engine.conversations) {
      if (cs.hexId == h) return cs.title;
    }
    return 'Cuộc gọi';
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;
    return ListenableBuilder(
      listenable: e.calls,
      builder: (context, _) {
        final c = e.calls;
        final name = _name(c);
        final video = c.kind == CallKind.CALL_KIND_VIDEO;
        switch (c.phase) {
          case CallPhase.idle:
            return const SizedBox.shrink();
          case CallPhase.ringing:
            return IncomingCallView(name: name, video: video, onDecline: () => unawaited(e.endCall()), onAnswer: () => unawaited(_answer()));
          case CallPhase.connecting:
          case CallPhase.connected:
            final ms = c.startedAtMs == null ? 0 : DateTime.now().millisecondsSinceEpoch - c.startedAtMs!;
            return CallView(name: name, status: c.phase == CallPhase.connected ? durationLabel(ms) : 'Đang kết nối…', onEnd: () => unawaited(e.endCall()));
          case CallPhase.ended:
            _close ??= Timer(const Duration(seconds: 2), () {
              _close = null;
              c.dismiss();
            });
            return CallView(name: name, status: 'Cuộc gọi đã kết thúc', error: c.error);
        }
      },
    );
  }

  Future<void> _answer() async {
    try {
      await widget.engine.answerCall();
    } on Exception {
      // CallController đã đặt `error` và chuyển sang trạng thái kết thúc.
    }
  }
}

/// Đặt lớp cuộc gọi lên trên toàn app khi có cuộc gọi (chuông, đang gọi), như một lớp phủ không qua Navigator.
class CallHost extends StatelessWidget {
  const CallHost({super.key, required this.engine, required this.child});
  final ChatEngine engine;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      child,
      ListenableBuilder(
        listenable: engine.calls,
        builder: (context, _) => engine.calls.phase == CallPhase.idle ? const SizedBox.shrink() : Positioned.fill(child: Material(child: CallPage(engine: engine))),
      ),
    ],
  );
}
