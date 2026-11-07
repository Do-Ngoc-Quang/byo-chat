import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'chatcore_api.dart';

/// Mở lõi trên Web: WASM chạy trong Web Worker `chatcore_worker.js` (ADR 0006).
/// `path` bị bỏ qua trên Web. Mỗi `ChatCore` có Worker riêng (một thiết bị).
Future<ChatCore> openChatCore({String? path}) async =>
    _WebChatCore(web.Worker('chatcore_worker.js'.toJS, web.WorkerOptions(type: 'module')));

class _WebChatCore implements ChatCore {
  _WebChatCore(this._worker) {
    _worker.onmessage = ((web.MessageEvent e) {
      final data = e.data as JSObject;
      final id = (data['id']! as JSNumber).toDartInt;
      final c = _pending.remove(id);
      if (c == null) return;
      final err = data['error'];
      if (err != null && !err.isUndefined) {
        c.completeError(ChatCoreException((err as JSString).toDart));
      } else {
        c.complete(data['result']);
      }
    }).toJS;
    _worker.onerror = ((web.Event e) {
      for (final c in _pending.values) {
        c.completeError(StateError('Worker chatcore lỗi'));
      }
      _pending.clear();
    }).toJS;
  }

  final web.Worker _worker;
  final _pending = <int, Completer<JSAny?>>{};
  var _next = 0;

  Future<JSAny?> _send(String op, List<JSAny?> args) {
    final id = _next++;
    final c = Completer<JSAny?>();
    _pending[id] = c;
    final msg = JSObject()
      ..['id'] = id.toJS
      ..['op'] = op.toJS
      ..['args'] = args.toJS;
    _worker.postMessage(msg);
    return c.future;
  }

  @override
  Future<String> version() async => ((await _send('core_version', []))! as JSString).toDart;

  @override
  Future<void> open(Uint8List identity) async {
    await _send('open', [identity.toJS]);
  }

  @override
  Future<void> openDeviceRaw(Uint8List packedArgs) async {
    await _send('open_device', [packedArgs.toJS]);
  }

  @override
  Future<void> openRestoreRaw(Uint8List packedArgs) async {
    await _send('open_restore', [packedArgs.toJS]);
  }

  @override
  Future<Uint8List> callRaw(String op, Uint8List packedArgs) async {
    final r = await _send('call', [op.toJS, packedArgs.toJS]);
    return (r! as JSUint8Array).toDart;
  }

  @override
  Future<void> dispose() async => _worker.terminate();
}
