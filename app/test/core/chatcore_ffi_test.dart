// Chạy với thư viện thật: CHATCORE_LIB=<đường dẫn chatcore_ffi.dll|so> flutter test.
// Bỏ qua nếu chưa build thư viện (xem app/README.md).
@TestOn('vm')
library;

import 'dart:io';

import 'dart:typed_data';

import 'package:byo_chat/core/chatcore.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/chat_e2e.dart';
import '../../integration_test/backup_e2e.dart';
import '../../integration_test/revoke_e2e.dart';
import '../../integration_test/login_e2e.dart';
import '../../integration_test/mls_scenario.dart';
import '../../integration_test/persist_e2e.dart';
import 'package:byo_chat/storage/blob_store_io.dart';
import 'package:byo_chat/storage/secret_store.dart';

void main() {
  final skip = Platform.environment['CHATCORE_LIB'] == null ? 'đặt CHATCORE_LIB để chạy' : false;

  test('FFI trả phiên bản lõi', () async {
    final core = await openChatCore();
    expect(await core.version(), matches(RegExp(r'^\d+\.\d+\.\d+$')));
    await core.dispose();
  }, skip: skip);

  test('MLS 1-1, External Commit, SFrame qua FFI', () => runMlsScenario(openChatCore), skip: skip);

  test('credential, KeyPackage hàng loạt qua FFI', () => runCredentialScenario(openChatCore), skip: skip);

  final api = Platform.environment['CHAT_API'];
  test('đăng nhập OTP + đăng ký thiết bị với server thật (FFI)', () => runLoginE2E(Uri.parse(api!)),
      skip: api == null || skip != false ? 'đặt CHAT_API và CHATCORE_LIB để chạy' : false);

  test('lưu bền + khôi phục với server thật (FFI, kho tệp)', () async {
    final dir = Directory.systemTemp.createTempSync('byo-persist');
    addTearDown(() => dir.deleteSync(recursive: true));
    await runPersistE2E(Uri.parse(api!), MemorySecretStore(), FileBlobStore(dir));
  }, skip: api == null || skip != false ? 'đặt CHAT_API và CHATCORE_LIB để chạy' : false);

  test('chat 1-1 hai thiết bị với server thật (FFI)', () => runChatE2E(Uri.parse(api!)),
      timeout: const Timeout(Duration(minutes: 3)),
      skip: api == null || skip != false ? 'đặt CHAT_API và CHATCORE_LIB để chạy' : false);

  test('nhóm 3 người với server thật (FFI)', () => runGroupE2E(Uri.parse(api!)),
      timeout: const Timeout(Duration(minutes: 3)),
      skip: api == null || skip != false ? 'đặt CHAT_API và CHATCORE_LIB để chạy' : false);

  test('rời nhóm với server thật (FFI)', () => runLeaveE2E(Uri.parse(api!)),
      timeout: const Timeout(Duration(minutes: 3)),
      skip: api == null || skip != false ? 'đặt CHAT_API và CHATCORE_LIB để chạy' : false);

  test('liên kết thiết bị + External Commit vào nhóm với server thật (FFI)', () => runLinkE2E(Uri.parse(api!)),
      timeout: const Timeout(Duration(minutes: 3)),
      skip: api == null || skip != false ? 'đặt CHAT_API và CHATCORE_LIB để chạy' : false);

  test('thu hồi thiết bị với server thật (FFI)', () => runRevokeE2E(Uri.parse(api!)),
      timeout: const Timeout(Duration(minutes: 3)),
      skip: api == null || skip != false ? 'đặt CHAT_API và CHATCORE_LIB để chạy' : false);

  test('sao lưu + khôi phục tài khoản với server thật (FFI)', () => runBackupE2E(Uri.parse(api!)),
      timeout: const Timeout(Duration(minutes: 3)),
      skip: api == null || skip != false ? 'đặt CHAT_API và CHATCORE_LIB để chạy' : false);

  test('gói byte khớp phía Rust', () {
    final items = [Uint8List(0), Uint8List.fromList([1, 2, 3])];
    expect(unpackList(packList(items)), items);
    expect(() => unpackList(Uint8List.fromList([5, 0, 0, 0, 1])), throwsA(isA<ChatCoreException>()));
  });
}
