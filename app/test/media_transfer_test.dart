// Chạy với lõi thật: CHATCORE_LIB=<libchatcore_ffi.so> flutter test test/media_transfer_test.dart
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:byo_chat/chat/media.dart';
import 'package:byo_chat/core/chatcore.dart';
import 'package:byo_chat/gen/chat/v1/services.pb.dart';
import 'package:byo_chat/net/api.dart';
import 'package:byo_chat/net/connect_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Máy chủ giả: MediaService (Connect) và kho blob (PUT/GET) trong bộ nhớ.
class _FakeMedia {
  final blobs = <String, Uint8List>{};
  var next = 0;
  int putStatus = 200;
  bool tamper = false;

  late final client = MockClient((req) async {
    final p = req.url.path;
    if (p.endsWith('.MediaService/CreateUpload')) {
      final r = CreateUploadRequest.fromBuffer(req.bodyBytes);
      expect(r.ciphertextSha256.length, 32);
      final id = Uint8List(16)..[15] = ++next;
      final res = CreateUploadResponse(mediaId: id, partUrls: ['http://blob.test/${id[15]}'], partSize: r.sizeBytes.toInt());
      return http.Response.bytes(res.writeToBuffer(), 200);
    }
    if (p.endsWith('.MediaService/CompleteUpload')) return http.Response.bytes(CompleteUploadResponse().writeToBuffer(), 200);
    if (p.endsWith('.MediaService/GetDownloadUrl')) {
      final r = GetDownloadUrlRequest.fromBuffer(req.bodyBytes);
      return http.Response.bytes(GetDownloadUrlResponse(url: 'http://blob.test/${r.mediaId[15]}').writeToBuffer(), 200);
    }
    if (req.url.host == 'blob.test') {
      final k = req.url.path.substring(1);
      if (req.method == 'PUT') {
        if (putStatus == 200) blobs[k] = Uint8List.fromList(req.bodyBytes);
        return http.Response('', putStatus);
      }
      final b = blobs[k];
      if (b == null) return http.Response('', 404);
      final out = Uint8List.fromList(b);
      if (tamper) out[3] ^= 1;
      return http.Response.bytes(out, 200);
    }
    return http.Response('?', 500);
  });
}

void main() {
  final skip = Platform.environment['CHATCORE_LIB'] == null ? 'đặt CHATCORE_LIB để chạy' : false;

  Future<(ChatCore, _FakeMedia, MediaTransfer)> setup() async {
    final core = await openChatCore();
    await core.open(Uint8List.fromList('alice-1'.codeUnits));
    final fake = _FakeMedia();
    final api = ChatApi(ConnectClient(Uri.parse('http://api.test'), httpClient: fake.client));
    return (core, fake, MediaTransfer(core: core, api: api, httpClient: fake.client));
  }

  test('tải lên rồi tải xuống: server chỉ thấy ciphertext, giải mã đúng', () async {
    final (core, fake, mt) = await setup();
    final plain = Uint8List.fromList(List.generate(150000, (i) => i % 251));
    final ref = await mt.upload(plain, mime: 'image/png', name: 'a.png', width: 300, height: 200);
    expect(ref.size, plain.length);
    expect((ref.key.length, ref.noncePrefix.length, ref.sha256.length), (32, 7, 32));
    final stored = fake.blobs.values.single;
    expect(stored.length, greaterThan(plain.length)); // có tag
    expect(stored.sublist(0, 32), isNot(plain.sublist(0, 32)));
    expect(await mt.download(ref), plain);
    await core.dispose();
  }, skip: skip);

  test('MediaRef đi vòng qua proto và JSON không mất trường', () async {
    final (core, _, mt) = await setup();
    final ref = await mt.upload(Uint8List.fromList([1, 2, 3]), mime: 'application/pdf', name: 'x.pdf', caption: 'bản vẽ');
    for (final r in [MediaRef.fromProto(ref.toProto()), MediaRef.fromJson(ref.toJson())]) {
      expect(r.mediaId, orderedEquals(ref.mediaId));
      expect(r.key, orderedEquals(ref.key));
      expect(r.noncePrefix, orderedEquals(ref.noncePrefix));
      expect(r.sha256, orderedEquals(ref.sha256));
      expect((r.size, r.mime, r.name, r.caption, r.isImage), (3, 'application/pdf', 'x.pdf', 'bản vẽ', false));
    }
    await core.dispose();
  }, skip: skip);

  test('lỗi: tệp rỗng, tải lên bị từ chối, ciphertext bị sửa', () async {
    final (core, fake, mt) = await setup();
    await expectLater(mt.upload(Uint8List(0), mime: 'image/png'), throwsA(isA<MediaException>()));
    fake.putStatus = 500;
    await expectLater(mt.upload(Uint8List.fromList([9]), mime: 'image/png'), throwsA(isA<MediaException>()));
    fake.putStatus = 200;
    final ref = await mt.upload(Uint8List.fromList(List.filled(1000, 7)), mime: 'image/png');
    fake.tamper = true;
    await expectLater(mt.download(ref), throwsA(isA<MediaException>().having((e) => e.message, 'message', contains('hỏng'))));
    await core.dispose();
  }, skip: skip);
}
