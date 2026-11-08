import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/chatcore.dart';
import '../gen/chat/v1/common.pbenum.dart';
import '../gen/chat/v1/services.pb.dart';
import '../net/api.dart';
import '../net/connect_client.dart';
import '../storage/session_store.dart';
import 'login_controller.dart' show describeError;
import 'session.dart';
import 'uuid7.dart';

/// Nội dung mã QR của thiết bị mới (giao-thuc.md 6.5 bước 1): link_id, device_id, khóa thiết bị, khóa X25519 tạm,
/// mã 6 số. Dạng văn bản (base64url của danh sách đóng gói) để hiển thị bằng mọi thư viện QR hoặc dán tay.
class LinkOffer {
  LinkOffer(this.linkId, this.deviceId, this.devicePublicKey, this.ephemeralPublicKey, this.shortCode);

  final Uint8List linkId, deviceId, devicePublicKey, ephemeralPublicKey;
  final String shortCode;

  String encode() =>
      base64Url.encode(packList([linkId, deviceId, devicePublicKey, ephemeralPublicKey, Uint8List.fromList(utf8.encode(shortCode))]));

  factory LinkOffer.decode(String s) {
    final p = unpackList(Uint8List.fromList(base64Url.decode(base64Url.normalize(s.trim()))));
    if (p.length != 5 || p[0].length != 16 || p[1].length != 16 || p[2].length != 32 || p[3].length != 32) {
      throw const FormatException('Mã liên kết không hợp lệ');
    }
    return LinkOffer(p[0], p[1], p[2], p[3], utf8.decode(p[4]));
  }
}

enum LinkStep { idle, waiting, registering, done }

/// Thiết bị MỚI của tài khoản đã có: StartLink -> (người dùng duyệt ở thiết bị cũ) -> CompleteLink ->
/// RegisterDevice không kèm khóa danh tính (giao-thuc.md 6.5 bước 1-4). Việc vào từng nhóm là của `ChatEngine`.
class LinkController extends ChangeNotifier {
  LinkController({
    required this.api,
    required this.openCore,
    this.store,
    this.platform = Platform.PLATFORM_UNSPECIFIED,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ChatApi api;
  final Future<ChatCore> Function() openCore;
  final SessionStore? store;
  final Platform platform;
  final DateTime Function() _now;

  LinkStep step = LinkStep.idle;
  String? error;
  LinkOffer? offer;
  Session? session;

  ChatCore? _core;
  Uint8List? _deviceId;

  /// Bước 1: sinh khóa và xin mã liên kết; trả [LinkOffer] để hiển thị cho thiết bị cũ quét.
  Future<LinkOffer> start() async {
    await _core?.dispose();
    final deviceId = newUuidV7(now: _now());
    final core = await openCore();
    try {
      await core.openPending(deviceId);
      final (devicePub, eph) = await core.linkStart();
      final r = await api.startLink(
        StartLinkRequest(platform: platform, deviceName: 'Thiết bị mới', devicePublicKey: devicePub, ephemeralPublicKey: eph),
      );
      _core = core;
      _deviceId = deviceId;
      step = LinkStep.waiting;
      error = null;
      notifyListeners();
      return offer = LinkOffer(Uint8List.fromList(r.linkId), deviceId, devicePub, eph, r.shortCode);
    } catch (_) {
      await core.dispose();
      rethrow;
    }
  }

  /// Bước 3-4: chờ thiết bị cũ duyệt (mỗi lần gọi chờ tới 30 giây phía server; UNAVAILABLE thì hỏi lại tới
  /// khi hết [timeout]), rồi đăng ký thiết bị và ghi bền phiên. Trả null (và đặt [error]) nếu thất bại.
  Future<Session?> complete({Duration timeout = const Duration(minutes: 5)}) async {
    final o = offer ?? (throw StateError('chưa gọi start()'));
    final core = _core!;
    final end = _now().add(timeout);
    try {
      CompleteLinkResponse done;
      while (true) {
        try {
          done = await api.completeLink(CompleteLinkRequest(linkId: o.linkId));
          break;
        } on ConnectException catch (e) {
          if (e.errorCode != ErrorCode.ERROR_CODE_UNAVAILABLE || !_now().isBefore(end)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      step = LinkStep.registering;
      notifyListeners();
      await core.linkFinish(o.linkId, Uint8List.fromList(done.credential), Uint8List.fromList(done.sealedBundle));
      final cred = await core.deviceCredential();
      final kps = await core.keyPackages(100);
      final last = await core.lastResortKeyPackage();
      final resp = await api.registerDevice(
        RegisterDeviceRequest(
          sessionTicket: done.sessionTicket,
          deviceId: _deviceId,
          platform: platform,
          deviceName: 'Thiết bị liên kết',
          devicePublicKey: cred.devicePublicKey,
          credential: cred.credential, // do thiết bị cũ ký; KHÔNG gửi account_identity_public_key
          keyPackages: kps,
          lastResortKeyPackage: last,
        ),
      );
      api.client.accessToken = resp.tokens.accessToken;
      final count = await api.countKeyPackages();
      final accountId = Uint8List.fromList(done.credential.sublist(0, 16));
      final s = Session(accountId, _deviceId!, core, resp.tokens, count.remaining);
      await store?.save(s);
      _core = null;
      step = LinkStep.done;
      notifyListeners();
      return session = s;
    } on ConnectException catch (e) {
      error = describeError(e);
    } on ChatCoreException catch (e) {
      error = 'Lỗi lõi mã hóa: ${e.message}';
    }
    await core.dispose();
    _core = null;
    step = LinkStep.idle;
    notifyListeners();
    return null;
  }
}
