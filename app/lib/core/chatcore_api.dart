import 'dart:typed_data';

/// Bề mặt API của lõi. Mọi hàm bất đồng bộ vì trên Web lõi chạy trong Web Worker.
/// Một `ChatCore` = một thiết bị MLS; phải `open` trước khi gọi thao tác MLS.
abstract interface class ChatCore {
  /// Phiên bản lõi, để kiểm tra nạp đúng thư viện.
  Future<String> version();

  /// Tạo thiết bị với `identity` (byte của credential, spec 6.1).
  Future<void> open(Uint8List identity);

  /// Tạo thiết bị theo spec 6.1 (khóa ký, khóa danh tính, credential); xem [ChatCoreDevice.openDevice].
  Future<void> openDeviceRaw(Uint8List packedArgs);

  /// Khôi phục thiết bị từ snapshot đã mã hóa (ADR 0008); xem [ChatCoreDevice.openRestore].
  Future<void> openRestoreRaw(Uint8List packedArgs);

  /// Gọi thao tác mức thấp; đối số đã `packList`. Dùng qua [ChatCoreMls] thay vì gọi trực tiếp.
  /// Lỗi của lõi ném [ChatCoreException].
  Future<Uint8List> callRaw(String op, Uint8List packedArgs);

  /// Giải phóng tài nguyên (hủy thiết bị, đóng Worker trên Web).
  Future<void> dispose();
}

class ChatCoreException implements Exception {
  ChatCoreException(this.message);
  final String message;
  @override
  String toString() => 'ChatCoreException: $message';
}

/// Đóng gói danh sách byte như `chatcore::api::pack`: u32 little-endian độ dài rồi dữ liệu.
Uint8List packList(List<Uint8List> items) {
  final out = BytesBuilder(copy: false);
  for (final i in items) {
    final len = ByteData(4)..setUint32(0, i.length, Endian.little);
    out.add(len.buffer.asUint8List());
    out.add(i);
  }
  return out.toBytes();
}

List<Uint8List> unpackList(Uint8List b) {
  final out = <Uint8List>[];
  var o = 0;
  while (o < b.length) {
    if (o + 4 > b.length) throw ChatCoreException('gói bị cắt cụt');
    final len = ByteData.sublistView(b, o, o + 4).getUint32(0, Endian.little);
    o += 4;
    if (o + len > b.length) throw ChatCoreException('gói bị cắt cụt');
    out.add(Uint8List.sublistView(b, o, o + len));
    o += len;
  }
  return out;
}

/// Kết quả một Commit để gửi qua `SubmitCommit` (`welcome` rỗng nếu không có ai mới).
class CommitOut {
  CommitOut(this.commit, this.welcome, this.groupInfo);
  final Uint8List commit, welcome, groupInfo;
}

/// Các thao tác MLS, ánh xạ một-một với `chatcore::api::Core::call`. `conv` là khóa nhóm
/// phía app đặt (thường là `group_id`).
extension ChatCoreMls on ChatCore {
  Future<List<Uint8List>> _call(String op, List<Uint8List> args) async => unpackList(await callRaw(op, packList(args)));

  Future<Uint8List> keyPackage() async => (await _call('key_package', []))[0];

  Future<void> createGroup(Uint8List conv) => _call('create_group', [conv]);

  Future<CommitOut> addMembers(Uint8List conv, List<Uint8List> keyPackages) async {
    final r = await _call('add_members', [conv, ...keyPackages]);
    return CommitOut(r[0], r[1], r[2]);
  }

  /// Dựng Commit thêm thiết bị vào nhóm đã có mà CHƯA áp dụng: gọi [mergeCommit] sau khi server nhận,
  /// hoặc [clearCommit] nếu bị từ chối (EPOCH_MISMATCH).
  Future<CommitOut> stageAdd(Uint8List conv, List<Uint8List> keyPackages) async {
    final r = await _call('stage_add', [conv, ...keyPackages]);
    return CommitOut(r[0], r[1], r[2]);
  }

  /// Dựng Commit gỡ mọi thiết bị của các tài khoản (chưa áp dụng, như [stageAdd]).
  Future<CommitOut> stageRemove(Uint8List conv, List<Uint8List> accountIds) async {
    final r = await _call('stage_remove', [conv, ...accountIds]);
    return CommitOut(r[0], r[1], r[2]);
  }

  /// Dựng Commit gỡ các thiết bị theo device_id (chưa áp dụng, như [stageAdd]); lỗi nếu không thiết bị nào có trong nhóm.
  Future<CommitOut> stageRemoveDevices(Uint8List conv, List<Uint8List> deviceIds) async {
    final r = await _call('stage_remove_devices', [conv, ...deviceIds]);
    return CommitOut(r[0], r[1], r[2]);
  }

  /// Xin rời nhóm (6.4): Remove proposal cho chính mình, gửi qua `SubmitProposal`.
  Future<Uint8List> leaveProposal(Uint8List conv) async => (await _call('leave_proposal', [conv]))[0];

  /// Nhận Proposal của người khác từ log; sẽ được gom khi [stageCommitPending] hoặc khi áp dụng Commit.
  Future<void> applyProposal(Uint8List conv, Uint8List proposal) => _call('apply_proposal', [conv, proposal]);

  /// Commit gom các proposal đang chờ (gỡ người xin rời), chưa áp dụng; lỗi nếu không có proposal nào.
  Future<CommitOut> stageCommitPending(Uint8List conv) async {
    final r = await _call('stage_commit_pending', [conv]);
    return CommitOut(r[0], r[1], r[2]);
  }

  Future<void> mergeCommit(Uint8List conv) => _call('merge_commit', [conv]);
  Future<void> clearCommit(Uint8List conv) => _call('clear_commit', [conv]);

  /// false khi thiết bị này đã bị gỡ khỏi nhóm.
  Future<bool> isActive(Uint8List conv) async => (await _call('is_active', [conv]))[0][0] == 1;

  Future<Uint8List> groupInfo(Uint8List conv) async => (await _call('group_info', [conv]))[0];

  Future<void> joinWelcome(Uint8List conv, Uint8List welcome) => _call('join_welcome', [conv, welcome]);

  Future<void> applyCommit(Uint8List conv, Uint8List commit) => _call('apply_commit', [conv, commit]);

  /// Tự vào nhóm bằng External Commit; trả Commit để gửi `SubmitCommit(external: true)`.
  Future<Uint8List> externalJoin(Uint8List conv, Uint8List groupInfo) async => (await _call('external_join', [conv, groupInfo]))[0];

  Future<Uint8List> encrypt(Uint8List conv, Uint8List plaintext) async => (await _call('encrypt', [conv, plaintext]))[0];

  Future<Uint8List> decrypt(Uint8List conv, Uint8List ciphertext) async => (await _call('decrypt', [conv, ciphertext]))[0];

  Future<int> epoch(Uint8List conv) async {
    final b = (await _call('epoch', [conv]))[0];
    // dart2js không có getUint64; epoch nhỏ hơn 2^53 nên ghép hai nửa 32 bit là đủ.
    final d = ByteData.sublistView(b);
    return d.getUint32(0, Endian.little) + d.getUint32(4, Endian.little) * 0x100000000;
  }

  Future<Uint8List> sframeKey(Uint8List conv, Uint8List callId) async => (await _call('sframe_key', [conv, callId]))[0];
}

Uint8List _u64(int v) {
  final b = ByteData(8)..setUint32(0, v & 0xffffffff, Endian.little);
  b.setUint32(4, v ~/ 0x100000000, Endian.little); // dart2js không có setUint64
  return b.buffer.asUint8List();
}

/// Khóa và credential của thiết bị (spec 6.1). Khóa danh tính tài khoản chỉ có ở thiết bị đầu tiên
/// hoặc thiết bị khôi phục từ sao lưu.
class DeviceCredential {
  DeviceCredential(this.credential, this.devicePublicKey, this.identityPublicKey);

  /// 136 byte: account_id | device_id | device_public_key | created_ms | chữ ký.
  final Uint8List credential, devicePublicKey, identityPublicKey;
}

extension ChatCoreDevice on ChatCore {
  /// Tạo thiết bị: sinh khóa ký, và khóa danh tính tài khoản nếu `identityKey` rỗng/null
  /// (thiết bị đầu tiên); có `identityKey` (từ [identityExport]) khi khôi phục.
  Future<void> openDevice({required Uint8List accountId, required Uint8List deviceId, Uint8List? identityKey, required int createdMs}) {
    return openDeviceRaw(packList([accountId, deviceId, identityKey ?? Uint8List(0), _u64(createdMs)]));
  }

  /// Bản xác nhận thu hồi thiết bị (88 byte) ký bằng khóa danh tính; chỉ thiết bị giữ khóa danh tính ký được.
  Future<Uint8List> revocationSign(Uint8List deviceId, int revokedMs) async =>
      (await _dcall('revocation_sign', [deviceId, _u64(revokedMs)]))[0];

  /// Recovery key mới (32 byte ngẫu nhiên từ lõi) cho sao lưu (giao-thuc.md 6.14, ADR 0012).
  Future<Uint8List> backupKeyNew() async => (await _dcall('backup_key_new', []))[0];

  /// Bản sao lưu đã mã hóa: khóa danh tính + lịch sử (`app_state`), không gồm trạng thái MLS.
  Future<Uint8List> backupSeal(Uint8List recoveryKey) async => (await _dcall('backup_seal', [recoveryKey]))[0];

  /// Mở bản sao lưu: (khóa danh tính, app_state). Sai recovery key hoặc dữ liệu bị sửa ném [ChatCoreException].
  Future<(Uint8List, Uint8List)> backupOpen(Uint8List recoveryKey, Uint8List blob) async {
    final r = await _dcall('backup_open', [recoveryKey, blob]);
    return (r[0], r[1]);
  }

  /// Thiết bị mới chờ liên kết (giao-thuc.md 6.5): `accountId` rỗng. Sau đó [linkStart], rồi [linkFinish].
  Future<void> openPending(Uint8List deviceId) => openDeviceRaw(packList([Uint8List(0), deviceId, Uint8List(0), _u64(0)]));

  /// Thiết bị mới: (khóa công khai thiết bị, khóa X25519 tạm) để gửi `StartLink`.
  Future<(Uint8List, Uint8List)> linkStart() async {
    final r = await _dcall('link_start', []);
    return (r[0], r[1]);
  }

  /// Thiết bị cũ: credential ký cho thiết bị mới + gói khóa danh tính đã mã hóa, để gửi `ApproveLink`.
  Future<(Uint8List, Uint8List)> linkApprove({
    required Uint8List linkId,
    required Uint8List newDeviceId,
    required Uint8List newDevicePublicKey,
    required Uint8List ephemeralPublicKey,
    required int createdMs,
  }) async {
    final r = await _dcall('link_approve', [linkId, newDeviceId, newDevicePublicKey, ephemeralPublicKey, _u64(createdMs)]);
    return (r[0], r[1]);
  }

  /// Thiết bị mới: mở gói, kiểm credential, trở thành thiết bị đầy đủ của tài khoản.
  Future<void> linkFinish(Uint8List linkId, Uint8List credential, Uint8List sealedBundle) =>
      _dcall('link_finish', [linkId, credential, sealedBundle]);

  /// Đổi khóa nhóm (nhóm tạo bằng `group_id` tạm, sau khi server cấp `conv_id` thì đổi sang `conv_id`).
  Future<void> renameGroup(Uint8List from, Uint8List to) => _dcall('rename_group', [from, to]);

  /// Bỏ nhóm và xóa khóa của nó (ví dụ `CreateConversation` trả `existed`).
  Future<void> dropGroup(Uint8List conv) => _dcall('drop_group', [conv]);

  /// Credential (136 byte) của từng lá trong nhóm; 16 byte đầu của mỗi credential là `account_id`.
  Future<List<Uint8List>> groupMembers(Uint8List conv) => _dcall('group_members', [conv]);

  /// Dữ liệu ứng dụng đi cùng snapshot (kho tin nhắn cục bộ...), ghi cùng lúc với trạng thái MLS.
  Future<void> setAppState(Uint8List bytes) => _dcall('app_state_set', [bytes]);
  Future<Uint8List> getAppState() async => (await _dcall('app_state_get', []))[0];

  /// Khôi phục thiết bị (khóa, credential, mọi nhóm) từ [snapshot]; ném [ChatCoreException]
  /// nếu sai khóa hoặc dữ liệu bị sửa.
  Future<void> openRestore(Uint8List sealed, Uint8List key) => openRestoreRaw(packList([sealed, key]));

  /// Snapshot trạng thái đã mã hóa bằng [key] (32 byte) để ghi bền. Gọi sau MỖI thay đổi trạng thái MLS.
  Future<Uint8List> snapshot(Uint8List key) async => (await _dcall('snapshot', [key]))[0];

  Future<List<Uint8List>> _dcall(String op, List<Uint8List> args) async => unpackList(await callRaw(op, packList(args)));

  Future<DeviceCredential> deviceCredential() async {
    final r = await _dcall('credential', []);
    return DeviceCredential(r[0], r[1], r[2]);
  }

  /// Khóa danh tính tài khoản (NHẠY CẢM): chỉ để cất vào keystore hoặc chuyển cho thiết bị mới.
  Future<Uint8List> identityExport() async => (await _dcall('identity_export', []))[0];

  /// `count` KeyPackage một lần (hạn 30 ngày) để gửi `RegisterDevice`/`UploadKeyPackages`.
  Future<List<Uint8List>> keyPackages(int count) async {
    final n = ByteData(4)..setUint32(0, count, Endian.little);
    return _dcall('key_packages', [n.buffer.asUint8List()]);
  }

  /// KeyPackage last resort (hạn 90 ngày).
  Future<Uint8List> lastResortKeyPackage() async => (await _dcall('last_resort_key_package', []))[0];

  /// Kiểm một KeyPackage nhận từ `FetchKeyPackages` (spec 6.2 bước 2); ném [ChatCoreException] nếu sai.
  Future<void> verifyKeyPackage({
    required Uint8List keyPackage,
    required Uint8List credential,
    required Uint8List identityPublicKey,
    required Uint8List expectedAccountId,
  }) => _dcall('verify_key_package', [keyPackage, credential, identityPublicKey, expectedAccountId]);
}
