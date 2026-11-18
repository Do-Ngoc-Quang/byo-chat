import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../chat/chat_engine.dart';
import '../chat/local_doc.dart';
import 'theme.dart';
import 'viewer_page.dart';

/// Nội dung media trong bong bóng chat: ảnh (tải, giải mã, bấm để xem) hoặc thẻ tệp (tên và dung lượng).
/// Thiết kế Mobile-Chat chưa vẽ bong bóng media; dùng góc bo, màu và chữ của bong bóng (docs/notes.md).
class MediaBubbleBody extends StatefulWidget {
  const MediaBubbleBody({super.key, required this.engine, required this.m, required this.sender, required this.maxWidth});

  final ChatEngine engine;
  final ChatMessage m;
  final String sender;
  final double maxWidth;

  @override
  State<MediaBubbleBody> createState() => _MediaBubbleBodyState();
}

class _MediaBubbleBodyState extends State<MediaBubbleBody> {
  Future<Uint8List>? _bytes;

  @override
  void initState() {
    super.initState();
    if (widget.m.media!.isImage) _bytes = widget.engine.mediaBytes(widget.m);
  }

  void _retry() {
    final f = widget.engine.mediaBytes(widget.m);
    setState(() {
      _bytes = f;
    });
  }

  static String _size(int b) => b >= 1 << 20 ? '${(b / (1 << 20)).toStringAsFixed(1)} MB' : '${(b / 1024).ceil()} KB';

  @override
  Widget build(BuildContext context) {
    final ref = widget.m.media!;
    if (!ref.isImage) {
      return Row(
        key: Key('file-${widget.m.id}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file_outlined, color: widget.m.mine ? Colors.white : Ui.muted),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ref.name.isEmpty ? 'Tệp' : ref.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: widget.m.mine ? Colors.white : Ui.text),
                ),
                Text(_size(ref.size), style: TextStyle(fontSize: 12, color: widget.m.mine ? const Color(0xCCFFFFFF) : Ui.muted)),
              ],
            ),
          ),
        ],
      );
    }
    final w = (widget.maxWidth - 28).clamp(120.0, 360.0);
    final ratio = ref.width > 0 && ref.height > 0 ? (ref.height / ref.width).clamp(0.5, 1.5) : 0.75;
    return SizedBox(
      width: w,
      height: w * ratio,
      child: FutureBuilder<Uint8List>(
        future: _bytes,
        builder: (context, snap) {
          if (snap.hasError) {
            return InkWell(
              key: Key('image-error-${widget.m.id}'),
              onTap: _retry,
              child: const Center(
                child: Text('Không tải được ảnh. Chạm để thử lại', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Ui.muted)),
              ),
            );
          }
          final data = snap.data;
          if (data == null) {
            return const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)));
          }
          return GestureDetector(
            key: Key('image-${widget.m.id}'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (ctx) => ViewerView(
                  sender: widget.sender,
                  when: _when(widget.m.tsMs),
                  content: Image.memory(data, fit: BoxFit.contain),
                  onClose: () => Navigator.of(ctx).pop(),
                ),
              ),
            ),
            child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(data, fit: BoxFit.cover, gaplessPlayback: true)),
          );
        },
      ),
    );
  }

  static String _when(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}
