import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';

import '../auth/session.dart';
import '../auth/uuid7.dart';
import '../core/chatcore.dart';
import '../gen/chat/v1/common.pb.dart' show Member;
import '../gen/chat/v1/common.pbenum.dart';
import '../gen/chat/v1/payload.pb.dart';
import '../gen/chat/v1/services.pb.dart';
import '../gen/chat/v1/ws.pb.dart';
import '../net/api.dart';
import '../net/gateway_client.dart';
import '../storage/session_store.dart';
import 'local_doc.dart';

/// Khóa danh tính của người kia khác lần đã thấy (giao-thuc.md 6.2 bước 2): không tự tạo hội thoại.
class IdentityChangedException implements Exception {
  IdentityChangedException(this.accountHex);
  final String accountHex;
  @override
  String toString() => 'Khóa danh tính của $accountHex đã thay đổi';
}

class ChatException implements Exception {
  ChatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Mutex bất đồng bộ: mọi thay đổi trạng thái MLS + kho cục bộ + ghi bền đi qua đây, tuần tự.
class _Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() f) {
    final done = Completer<T>();
    final prev = _tail;
    _tail = done.future.then((_) {}, onError: (_) {});
    prev.then((_) async {
      try {
        done.complete(await f());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }
}

/// Chat 1-1: tạo hội thoại (6.2), nhận Welcome/Commit/tin qua WebSocket (3, 7.2), gửi tin (7.1), kho cục bộ.
///
/// Bất biến chịu lực:
/// - Ack chỉ sau khi đã ghi bền cả trạng thái MLS lẫn kho cục bộ (một snapshot duy nhất, ADR 0009).
/// - Mã hóa rồi GHI BỀN rồi mới gửi: sập giữa chừng thì gửi lại đúng ciphertext đó, không dùng lại khóa MLS.
/// - Áp dụng theo `seq` liên tục; khoảng trống thì lấy `FetchLog`; mục do chính thiết bị này ghi được bỏ qua.
class ChatEngine extends ChangeNotifier {
  ChatEngine({
    required this.session,
    required this.api,
    required this.store,
    required this.apiBase,
    this.platform = Platform.PLATFORM_UNSPECIFIED,
    this.backoffBase = const Duration(seconds: 1),
    this.now,
    Random? random,
  }) : _rng = random ?? Random.secure();

  final Session session;
  final ChatApi api;
  final SessionStore store;
  final Uri apiBase;
  final Platform platform;
  final Duration backoffBase;
  final DateTime Function()? now;
  final Random _rng;

  final _mu = _Mutex();
  LocalDoc doc = LocalDoc();
  GatewayClient? _gw;
  StreamSubscription<GatewayState>? _gwSub;
  var _started = false;
  final _flushing = <String>{};

  /// Báo cho app khi thiết bị bị thu hồi (mã đóng 4003): app xóa dữ liệu, về màn đăng nhập.
  void Function()? onRevoked;

  ChatCore get _core => session.core;
  int get _nowMs => (now?.call() ?? DateTime.now()).millisecondsSinceEpoch;
  GatewayState get connection => _gw?.state ?? GatewayState.disconnected;

  List<ConvState> get conversations => doc.convs.values.toList()..sort((a, b) => b.lastActivityMs.compareTo(a.lastActivityMs));
  List<ChatMessage> messages(String convHex) => List.unmodifiable(doc.msgs[convHex] ?? const []);

  // ---------------------------------------------------------------- vòng đời

  Future<void> start() async {
    if (_started) return;
    _started = true;
    doc = LocalDoc.fromBytes(await _core.getAppState());
    _gw = GatewayClient(
      url: _wsUrl(),
      deviceId: session.deviceId,
      platform: platform,
      accessToken: () => session.tokens.accessToken,
      inboxCursor: () => doc.cursor,
      onDeliver: _onDeliver,
      onTokenExpired: _refreshToken,
      onRevoked: () => onRevoked?.call(),
      backoffBase: backoffBase,
    );
    _gwSub = _gw!.states.listen((s) {
      notifyListeners();
      if (s == GatewayState.online) {
        for (final c in doc.convs.keys.toList()) {
          unawaited(_flush(c));
        }
      }
    });
    _gw!.start();
    notifyListeners();
  }

  Future<void> stop() async {
    _started = false;
    await _gwSub?.cancel();
    await _gw?.stop();
    _gw = null;
  }

  Uri _wsUrl() => apiBase.replace(scheme: apiBase.scheme == 'https' ? 'wss' : 'ws', path: '/v1/connect');

  Future<void> whenOnline() => _gw!.whenOnline();

  Future<void> _refreshToken() async {
    session.tokens = await api.refreshToken(RefreshTokenRequest(deviceId: session.deviceId, refreshToken: session.tokens.refreshToken));
    api.client.accessToken = session.tokens.accessToken;
    await _mu.run(_persist);
  }

  /// Ghi bền: kho cục bộ vào app_state của lõi rồi snapshot (MỘT lần ghi cho cả hai).
  Future<void> _persist() async {
    await _core.setAppState(doc.toBytes());
    await store.save(session);
  }

  // ---------------------------------------------------------------- tạo hội thoại

  /// Mở hội thoại 1-1 với người có số điện thoại/email [destination] (giao-thuc.md 6.2, 6.12).
  Future<ConvState> openDirect(OtpChannel channel, String destination) async {
    final found = await api.lookupAccount(LookupAccountRequest(channel: channel, destination: destination.trim()));
    final peer = Uint8List.fromList(found.profile.accountId);
    if (hex(peer) == hex(session.accountId)) throw ChatException('Không thể nhắn cho chính mình');
    for (final c in doc.convs.values) {
      if (c.peerAccount != null && hex(c.peerAccount!) == hex(peer)) return c; // đã có
    }

    // 1. Khóa của cả hai tài khoản; kiểm từng gói (6.2 bước 2).
    final keys = await api.fetchKeyPackages(FetchKeyPackagesRequest(accountIds: [session.accountId, peer]));
    final adds = <Uint8List>[];
    final recipients = <Uint8List>[];
    Uint8List? peerIdentity;
    var peerDevices = 0;
    for (final a in keys.accounts) {
      final acct = Uint8List.fromList(a.accountId);
      final identity = Uint8List.fromList(a.accountIdentityPublicKey);
      final isPeer = hex(acct) == hex(peer);
      if (isPeer) {
        final seen = doc.peerIdentities[hex(acct)];
        if (seen != null && !listEquals(seen, identity)) throw IdentityChangedException(hex(acct));
        peerIdentity = identity;
      }
      for (final d in a.devices) {
        if (hex(d.deviceId) == hex(session.deviceId)) continue; // bỏ gói của chính thiết bị này
        await _core.verifyKeyPackage(
          keyPackage: Uint8List.fromList(d.keyPackage),
          credential: Uint8List.fromList(d.credential),
          identityPublicKey: identity,
          expectedAccountId: acct,
        );
        adds.add(Uint8List.fromList(d.keyPackage));
        recipients.add(Uint8List.fromList(d.deviceId));
        if (isPeer) peerDevices++;
      }
    }
    if (peerIdentity == null || peerDevices == 0) {
      throw ChatException('Người này chưa có thiết bị nào sẵn sàng nhận tin');
    }

    // 2. Tạo nhóm MLS dưới khóa tạm (group_id), gửi lên server, rồi đổi sang conv_id.
    final groupId = Uint8List.fromList(List.generate(32, (_) => _rng.nextInt(256)));
    return _mu.run(() async {
      await _core.createGroup(groupId);
      CreateConversationResponse resp;
      try {
        final out = await _core.addMembers(groupId, adds);
        resp = await api.createConversation(CreateConversationRequest(
          kind: ConvKind.CONV_KIND_DIRECT,
          groupId: groupId,
          members: [
            Member(accountId: session.accountId, role: Role.ROLE_MEMBER),
            Member(accountId: peer, role: Role.ROLE_MEMBER),
          ],
          commit: out.commit,
          welcomes: [for (final r in recipients) WelcomeEnvelope(recipientDeviceId: r, welcome: out.welcome)],
          groupInfo: out.groupInfo,
        ), idempotencyKey: hex(newUuidV7()));
      } catch (_) {
        await _core.dropGroup(groupId);
        rethrow;
      }
      final convId = Uint8List.fromList(resp.convId);
      final h = hex(convId);
      if (resp.existed) {
        // Đã có hội thoại 1-1 giữa hai tài khoản: bỏ nhóm vừa tạo; Welcome của người kia tới qua hộp thư.
        await _core.dropGroup(groupId);
        await _persist();
        final existing = doc.convs[h];
        if (existing != null) return existing;
        throw ChatException('Hội thoại đã tồn tại; đang chờ lời mời từ người kia, thử lại sau');
      }
      await _core.renameGroup(groupId, convId);
      final cs = ConvState(convId: convId, title: destination.trim(), peerAccount: peer, lastSeq: resp.seq.toInt(), lastActivityMs: _nowMs);
      doc.convs[h] = cs;
      doc.peerIdentities[hex(peer)] = peerIdentity!;
      await _persist();
      notifyListeners();
      return cs;
    });
  }

  // ---------------------------------------------------------------- nhận

  Future<void> _onDeliver(Deliver d) => _mu.run(() async {
        final h = hex(d.convId);
        if (d.inboxId.isNotEmpty) doc.cursor = Uint8List.fromList(d.inboxId);
        switch (d.kind) {
          case EntryKind.ENTRY_KIND_WELCOME:
            if (!doc.convs.containsKey(h)) await _joinFromWelcome(d);
          case EntryKind.ENTRY_KIND_COMMIT || EntryKind.ENTRY_KIND_APPLICATION || EntryKind.ENTRY_KIND_PROPOSAL:
            final cs = doc.convs[h];
            if (cs != null) {
              await _applyEntry(cs, _Entry(d.kind, d.senderDeviceId, d.seq.toInt(), d.ciphertext, d.serverTsMs.toInt()));
            }
          default:
            break;
        }
        await _persist(); // Ack chỉ được gửi sau dòng này (GatewayClient)
        notifyListeners();
      });

  Future<void> _joinFromWelcome(Deliver d) async {
    final convId = Uint8List.fromList(d.convId);
    try {
      await _core.joinWelcome(convId, Uint8List.fromList(d.ciphertext));
    } on ChatCoreException {
      return; // Welcome không dùng được (gói đã mất khóa...): bỏ qua, không kẹt hộp thư
    }
    Uint8List? peer;
    for (final cred in await _core.groupMembers(convId)) {
      final acct = cred.sublist(0, 16);
      if (hex(acct) != hex(session.accountId)) peer = Uint8List.fromList(acct);
    }
    doc.convs[hex(convId)] = ConvState(
      convId: convId,
      title: peer == null ? 'Hội thoại' : 'Tài khoản ${hex(peer).substring(0, 8)}',
      peerAccount: peer,
      lastSeq: d.seq.toInt(),
      lastActivityMs: d.serverTsMs.toInt(),
    );
  }

  /// Áp dụng một mục log theo thứ tự; lấp khoảng trống bằng FetchLog (giao-thuc.md 3).
  Future<void> _applyEntry(ConvState cs, _Entry e) async {
    if (e.seq <= cs.lastSeq) return; // trùng (gửi lại sau khi sập)
    if (e.seq > cs.lastSeq + 1) await _fetchUntil(cs, e.seq - 1);
    if (e.seq <= cs.lastSeq) return; // FetchLog đã áp dụng
    await _process(cs, e);
  }

  Future<void> _fetchUntil(ConvState cs, int upTo) async {
    while (cs.lastSeq < upTo) {
      final r = await api.fetchLog(FetchLogRequest(convId: cs.convId, afterSeq: Int64(cs.lastSeq), limit: 200));
      if (r.entries.isEmpty) return;
      for (final le in r.entries) {
        if (le.seq.toInt() <= cs.lastSeq) continue;
        await _process(cs, _Entry(le.kind, le.senderDeviceId, le.seq.toInt(), le.ciphertext, le.serverTsMs.toInt()));
      }
      if (!r.more) return;
    }
  }

  Future<void> _process(ConvState cs, _Entry e) async {
    final mine = hex(e.sender) == hex(session.deviceId);
    if (!mine) {
      switch (e.kind) {
        case EntryKind.ENTRY_KIND_COMMIT:
          await _core.applyCommit(cs.convId, Uint8List.fromList(e.ct));
        case EntryKind.ENTRY_KIND_APPLICATION:
          await _receiveApplication(cs, e);
        default:
          break; // PROPOSAL: chưa xử lý
      }
    }
    cs.lastSeq = e.seq;
    cs.lastActivityMs = max(cs.lastActivityMs, e.tsMs);
    _advanceSkips(cs);
  }

  /// Bỏ qua các seq do chính thiết bị này ghi, nối liền với seq đã áp dụng.
  void _advanceSkips(ConvState cs) {
    while (cs.skip.remove(cs.lastSeq + 1)) {
      cs.lastSeq++;
    }
  }

  Future<void> _receiveApplication(ConvState cs, _Entry e) async {
    final list = doc.msgs.putIfAbsent(cs.hexId, () => []);
    try {
      final pt = await _core.decrypt(cs.convId, Uint8List.fromList(e.ct));
      final p = Payload.fromBuffer(pt);
      if (p.whichContent() != Payload_Content.text) return; // phản ứng, sửa, xóa... làm sau
      final id = hex(p.clientMsgId);
      if (list.any((m) => m.id == id)) return; // khử trùng theo client_msg_id
      list.add(ChatMessage(id: id, mine: false, text: p.text.body, tsMs: e.tsMs, seq: e.seq, state: MsgState.received));
    } on ChatCoreException {
      // Spec 7.2: chỗ giữ chỗ "không giải mã được"; vào lại nhóm (6.7) làm ở giai đoạn sau.
      list.add(ChatMessage(id: 'x${cs.hexId}-${e.seq}', mine: false, text: '', tsMs: e.tsMs, seq: e.seq, state: MsgState.undecryptable));
    }
  }

  // ---------------------------------------------------------------- gửi

  /// Ghi tin vào hàng chờ (đã lưu bền) rồi thử gửi. Hoàn tất khi lần thử đầu xong (thành công hoặc để lại hàng chờ).
  Future<void> sendText(String convHex, String text) async {
    await _mu.run(() async {
      final cs = doc.convs[convHex] ?? (throw ChatException('Hội thoại không tồn tại'));
      final m = ChatMessage(id: hex(newUuidV7()), mine: true, text: text, tsMs: _nowMs);
      doc.msgs.putIfAbsent(convHex, () => []).add(m);
      cs.lastActivityMs = m.tsMs;
      await _persist();
      notifyListeners();
    });
    await _flush(convHex);
  }

  /// Gửi lần lượt các tin đang chờ của một hội thoại (giao-thuc.md 7.1).
  Future<void> _flush(String convHex) async {
    if (!_flushing.add(convHex)) return;
    try {
      var mismatches = 0;
      while (true) {
        final cs = doc.convs[convHex];
        final m = doc.msgs[convHex]?.where((m) => m.mine && m.state == MsgState.pending).firstOrNull;
        if (cs == null || m == null) return;
        // 1. Dựng ciphertext theo epoch hiện tại và ghi bền TRƯỚC khi gửi.
        await _mu.run(() async {
          if (m.ct != null) return; // đã dựng ở lần trước (sập giữa chừng): gửi lại đúng bản đó
          final p = Payload(version: 1, clientMsgId: _unhex(m.id), sentAtMs: Int64(m.tsMs), text: TextContent(body: m.text));
          m.epoch = await _core.epoch(cs.convId);
          m.ct = await _core.encrypt(cs.convId, Uint8List.fromList(p.writeToBuffer()));
          await _persist();
        });
        // 2. Gửi; server khử trùng theo client_msg_id nên gửi lại an toàn.
        try {
          final r = await _gw!.send(SendMessage(convId: cs.convId, clientMsgId: _unhex(m.id), mlsEpoch: Int64(m.epoch), ciphertext: m.ct));
          await _mu.run(() async {
            m.seq = r.seq.toInt();
            m.tsMs = r.serverTsMs.toInt();
            m.state = MsgState.sent;
            m.ct = null;
            cs.skip.add(m.seq);
            _advanceSkips(cs);
            await _persist();
            notifyListeners();
          });
        } on GatewayException catch (e) {
          if (e.code == ErrorCode.ERROR_CODE_EPOCH_MISMATCH && ++mismatches <= 5) {
            // Đồng bộ tới head rồi dựng lại theo epoch mới (không tính vào backoff, tối đa 5 lần).
            await _mu.run(() async {
              await _fetchUntil(cs, 1 << 62);
              m.ct = null;
              await _persist();
            });
            continue;
          }
          if (e.code == ErrorCode.ERROR_CODE_INVALID_ARGUMENT || e.code == ErrorCode.ERROR_CODE_PERMISSION_DENIED || e.code == ErrorCode.ERROR_CODE_EPOCH_MISMATCH) {
            await _mu.run(() async {
              m.state = MsgState.failed;
              m.ct = null;
              await _persist();
              notifyListeners();
            });
            continue;
          }
          return; // offline/quá hạn: để lại hàng chờ, thử lại khi online
        }
      }
    } finally {
      _flushing.remove(convHex);
    }
  }

  static Uint8List _unhex(String h) =>
      Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }

  /// Dùng cho test: chuyển nội dung kho cục bộ thành chuỗi gọn.
  @visibleForTesting
  String debugDump() => utf8.decode(doc.toBytes());
}

class _Entry {
  _Entry(this.kind, this.sender, this.seq, this.ct, this.tsMs);
  final EntryKind kind;
  final List<int> sender;
  final int seq;
  final List<int> ct;
  final int tsMs;
}
