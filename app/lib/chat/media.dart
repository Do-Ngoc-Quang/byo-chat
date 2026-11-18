import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:http/http.dart' as http;

import '../core/chatcore.dart';
import '../gen/chat/v1/payload.pb.dart';
import '../gen/chat/v1/services.pb.dart';
import '../net/api.dart';

/// Tham chiếu tới một tệp media đã mã hóa (spec thiet-ke-chinh.md mục 11, `MediaContent`). Khóa nằm ở đây
/// nên chỉ lưu trong kho cục bộ đã mã hóa và trong tin MLS, không bao giờ gửi cho server.
class MediaRef {
  MediaRef({
    required this.mediaId,
    required this.key,
    required this.noncePrefix,
    required this.sha256,
    required this.size,
    required this.mime,
    this.name = '',
    this.caption = '',
    this.width = 0,
    this.height = 0,
  });

  final Uint8List mediaId, key, noncePrefix, sha256;
  final int size, width, height;
  final String mime, name, caption;

  bool get isImage => mime.startsWith('image/');

  MediaContent toProto() => MediaContent(
    mediaId: mediaId,
    key: key,
    noncePrefix: noncePrefix,
    ciphertextSha256: sha256,
    sizeBytes: Int64(size),
    mime: mime,
    fileName: name,
    caption: caption,
    width: width,
    height: height,
  );

  factory MediaRef.fromProto(MediaContent m) => MediaRef(
    mediaId: Uint8List.fromList(m.mediaId),
    key: Uint8List.fromList(m.key),
    noncePrefix: Uint8List.fromList(m.noncePrefix),
    sha256: Uint8List.fromList(m.ciphertextSha256),
    size: m.sizeBytes.toInt(),
    mime: m.mime,
    name: m.fileName,
    caption: m.caption,
    width: m.width,
    height: m.height,
  );

  Map<String, Object?> toJson() => {
    'id': _hex(mediaId),
    'key': _hex(key),
    'np': _hex(noncePrefix),
    'sha': _hex(sha256),
    'size': size,
    'mime': mime,
    if (name.isNotEmpty) 'name': name,
    if (caption.isNotEmpty) 'cap': caption,
    if (width > 0) 'w': width,
    if (height > 0) 'h': height,
  };

  factory MediaRef.fromJson(Map<String, dynamic> j) => MediaRef(
    mediaId: _unhex(j['id'] as String),
    key: _unhex(j['key'] as String),
    noncePrefix: _unhex(j['np'] as String),
    sha256: _unhex(j['sha'] as String),
    size: j['size'] as int,
    mime: j['mime'] as String,
    name: (j['name'] as String?) ?? '',
    caption: (j['cap'] as String?) ?? '',
    width: (j['w'] as int?) ?? 0,
    height: (j['h'] as int?) ?? 0,
  );
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _unhex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

class MediaException implements Exception {
  MediaException(this.message);
  final String message;
  @override
  String toString() => 'MediaException: $message';
}

/// Mã hóa rồi tải lên, hoặc tải xuống rồi giải mã một tệp media. Không giữ trạng thái; bộ nhớ đệm do bên gọi lo.
class MediaTransfer {
  MediaTransfer({required this.core, required this.api, http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final ChatCore core;
  final ChatApi api;
  final http.Client _http;

  /// Tệp lớn hơn mức này bị từ chối ở client trước khi mã hóa (khớp `MaxMediaBytes` của server, trừ phần tag).
  static const maxBytes = 99 * 1024 * 1024;

  Future<MediaRef> upload(Uint8List plain, {required String mime, String name = '', String caption = '', int width = 0, int height = 0}) async {
    if (plain.isEmpty) throw MediaException('Tệp rỗng');
    if (plain.length > maxBytes) throw MediaException('Tệp quá lớn');
    final (key, prefix) = await core.mediaKeyNew();
    final (ct, hash) = await core.mediaEncrypt(key, prefix, plain);
    final up = await api.createUpload(CreateUploadRequest(sizeBytes: Int64(ct.length), ciphertextSha256: hash));
    if (up.partUrls.length != 1) throw MediaException('Server trả ${up.partUrls.length} phần, mới hỗ trợ 1');
    final r = await _http.put(Uri.parse(up.partUrls.first), body: ct);
    if (r.statusCode != 200) throw MediaException('Tải lên thất bại (${r.statusCode})');
    await api.completeUpload(CompleteUploadRequest(mediaId: up.mediaId));
    return MediaRef(
      mediaId: Uint8List.fromList(up.mediaId),
      key: key,
      noncePrefix: prefix,
      sha256: hash,
      size: plain.length,
      mime: mime,
      name: name,
      caption: caption,
      width: width,
      height: height,
    );
  }

  /// Tải và giải mã; kiểm SHA-256 của ciphertext trước khi giải mã (lõi làm việc đó).
  Future<Uint8List> download(MediaRef ref) async {
    final dl = await api.getDownloadUrl(GetDownloadUrlRequest(mediaId: ref.mediaId));
    final r = await _http.get(Uri.parse(dl.url));
    if (r.statusCode != 200) throw MediaException('Tải xuống thất bại (${r.statusCode})');
    try {
      return await core.mediaDecrypt(ref.key, ref.noncePrefix, ref.sha256, r.bodyBytes);
    } on ChatCoreException {
      throw MediaException('Tệp bị hỏng hoặc bị sửa');
    }
  }
}
