import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fixnum/fixnum.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import '../auth/uuid7.dart';
import '../core/chatcore.dart';
import '../gen/chat/v1/common.pbenum.dart';
import '../gen/chat/v1/services.pb.dart';
import '../net/api.dart';
import '../storage/session_store.dart';
import 'local_doc.dart';

class BackupException implements Exception {
  BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sao lưu và khôi phục tài khoản (giao-thuc.md 6.14, ADR 0012). Bản sao lưu = khóa danh tính + lịch sử, mã hóa bằng
/// recovery key 256 bit do người dùng giữ; server không giải mã được. Mất hết thiết bị và quên recovery key là mất lịch sử.
class BackupService {
  BackupService({required this.api, http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final ChatApi api;
  final http.Client _http;

  /// Recovery key hiển thị cho người dùng: 64 ký tự hex chia nhóm 4 ("a1b2-c3d4-...").
  static String formatKey(Uint8List k) {
    final h = hex(k);
    return [for (var i = 0; i < h.length; i += 4) h.substring(i, i + 4)].join('-');
  }

  static Uint8List parseKey(String s) {
    final h = s.replaceAll(RegExp(r'[\s-]'), '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(h)) throw BackupException('Recovery key phải gồm 64 ký tự hex');
    return Uint8List.fromList([for (var i = 0; i < 64; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
  }

  /// Tạo bản sao lưu từ trạng thái hiện tại của [session] (kho cục bộ đã nằm trong lõi nhờ `ChatEngine`) và tải lên.
  /// Trả recovery key mới nếu [recoveryKey] null (hiển thị cho người dùng ĐÚNG MỘT LẦN và dặn họ cất).
  Future<Uint8List> backUp(Session session, {Uint8List? recoveryKey}) async {
    final key = recoveryKey ?? await session.core.backupKeyNew();
    final blob = await session.core.backupSeal(key);
    final up = await api.createBackupUpload(
      CreateBackupUploadRequest(sizeBytes: Int64(blob.length), ciphertextSha256: crypto.sha256.convert(blob).bytes),
    );
    // Một phần (part_size >= kích thước). Tải nhiều phần khi S3 thật có giới hạn phần: việc dở.
    if (up.partUrls.length != 1 || up.partSize < blob.length) throw BackupException('Máy chủ cấp URL tải lên không dùng được');
    final r = await _http.put(Uri.parse(up.partUrls.single), body: blob);
    if (r.statusCode != 200) throw BackupException('Tải bản sao lưu lên thất bại (${r.statusCode})');
    return key;
  }

  /// Khôi phục trên thiết bị MỚI (6.14): tải bản sao lưu bằng [ticket] (từ OTP, tài khoản đã có), mở bằng
  /// [recoveryKey], dựng thiết bị với khóa danh tính cũ, `RegisterDevice` (không gửi khóa danh tính), rồi giữ lịch sử.
  /// Trả phiên; gọi `ChatEngine.joinAllConversations` để vào lại từng hội thoại bằng External Commit.
  /// Lá của thiết bị đã mất vẫn còn trong nhóm tới khi người dùng thu hồi thiết bị đó (`ChatEngine.revokeDevice`).
  Future<Session> restore({
    required Uint8List ticket,
    required Uint8List accountId,
    required Uint8List recoveryKey,
    required Future<ChatCore> Function() openCore,
    required Platform platform,
    SessionStore? store,
    DateTime Function()? now,
  }) async {
    final clock = now ?? DateTime.now;
    final latest = await api.getLatestBackup(GetLatestBackupRequest(sessionTicket: ticket));
    final dl = await _http.get(Uri.parse(latest.downloadUrl));
    if (dl.statusCode != 200) throw BackupException('Tải bản sao lưu về thất bại (${dl.statusCode})');

    // Mở bản sao lưu bằng một lõi tạm (op không cần trạng thái), sai khóa thì lõi báo lỗi.
    final deviceId = newUuidV7(now: clock());
    final probe = await openCore();
    final Uint8List identity, history;
    try {
      await probe.openPending(deviceId);
      (identity, history) = await probe.backupOpen(recoveryKey, Uint8List.fromList(dl.bodyBytes));
    } on ChatCoreException catch (e) {
      throw BackupException('Recovery key sai hoặc bản sao lưu hỏng: ${e.message}');
    } finally {
      await probe.dispose();
    }

    final core = await openCore();
    try {
      await core.openDevice(accountId: accountId, deviceId: deviceId, identityKey: identity, createdMs: clock().millisecondsSinceEpoch);
      final cred = await core.deviceCredential();
      final resp = await api.registerDevice(
        RegisterDeviceRequest(
          sessionTicket: ticket,
          deviceId: deviceId,
          platform: platform,
          deviceName: 'Thiết bị khôi phục',
          devicePublicKey: cred.devicePublicKey,
          credential: cred.credential,
          keyPackages: await core.keyPackages(100),
          lastResortKeyPackage: await core.lastResortKeyPackage(),
        ),
      );
      api.client.accessToken = resp.tokens.accessToken;
      // Giữ lịch sử, bỏ trạng thái đồng bộ MLS cũ: các hội thoại sẽ được vào lại bằng External Commit.
      final doc = LocalDoc.fromBytes(history);
      doc.convs.clear();
      doc.cursor = Uint8List(0);
      for (final list in doc.msgs.values) {
        for (final m in list) {
          if (m.state == MsgState.pending) {
            m.state = MsgState.failed;
            m.ct = null;
          }
        }
      }
      await core.setAppState(doc.toBytes());
      final count = await api.countKeyPackages();
      final s = Session(accountId, deviceId, core, resp.tokens, count.remaining);
      await store?.save(s);
      return s;
    } catch (_) {
      await core.dispose();
      rethrow;
    }
  }
}
