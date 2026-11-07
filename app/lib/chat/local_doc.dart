import 'dart:convert';
import 'dart:typed_data';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _b64(String s) => base64.decode(s);

enum MsgState { pending, sent, failed, received, undecryptable }

/// Một tin trong hội thoại. `ct`/`epoch` chỉ có khi tin đang chờ gửi: ciphertext đã dựng và ghi bền
/// TRƯỚC khi gửi để gửi lại đúng bản đó (không dùng lại khóa MLS cho nội dung khác).
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.mine,
    required this.text,
    required this.tsMs,
    this.seq = 0,
    this.state = MsgState.pending,
    this.ct,
    this.epoch = 0,
  });

  final String id; // hex của client_msg_id
  final bool mine;
  String text;
  int tsMs;
  int seq; // 0 khi chưa có từ server
  MsgState state;
  Uint8List? ct;
  int epoch;

  Map<String, Object?> toJson() => {
        'id': id,
        'mine': mine,
        'text': text,
        'ts': tsMs,
        'seq': seq,
        'state': state.name,
        if (ct != null) 'ct': base64.encode(ct!),
        'epoch': epoch,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        mine: j['mine'] as bool,
        text: j['text'] as String,
        tsMs: j['ts'] as int,
        seq: j['seq'] as int,
        state: MsgState.values.byName(j['state'] as String),
        ct: j['ct'] == null ? null : _b64(j['ct'] as String),
        epoch: j['epoch'] as int,
      );
}

/// Trạng thái một hội thoại 1-1 ở máy này.
class ConvState {
  ConvState({
    required this.convId,
    required this.title,
    this.peerAccount,
    this.lastSeq = 0,
    Set<int>? skip,
    this.lastActivityMs = 0,
  }) : skip = skip ?? {};

  final Uint8List convId;
  String title;
  Uint8List? peerAccount;

  /// `seq` cuối đã áp dụng liên tục (giao-thuc.md 3: áp dụng theo seq tăng dần).
  int lastSeq;

  /// `seq` của các mục do chính thiết bị này ghi (tin, Commit): server không gửi lại cho ta nên phải
  /// bỏ qua khi tính liên tục.
  final Set<int> skip;
  int lastActivityMs;

  String get hexId => hex(convId);

  Map<String, Object?> toJson() => {
        'conv': base64.encode(convId),
        'title': title,
        if (peerAccount != null) 'peer': base64.encode(peerAccount!),
        'lastSeq': lastSeq,
        'skip': skip.toList()..sort(),
        'activity': lastActivityMs,
      };

  factory ConvState.fromJson(Map<String, dynamic> j) => ConvState(
        convId: _b64(j['conv'] as String),
        title: j['title'] as String,
        peerAccount: j['peer'] == null ? null : _b64(j['peer'] as String),
        lastSeq: j['lastSeq'] as int,
        skip: (j['skip'] as List).cast<int>().toSet(),
        lastActivityMs: j['activity'] as int,
      );
}

/// Kho cục bộ của app: hội thoại, tin nhắn, con trỏ hộp thư, khóa danh tính đã thấy (TOFU).
/// Được chatcore giữ cùng snapshot MLS (ADR 0009) nên luôn khớp trạng thái MLS sau khi sập.
class LocalDoc {
  LocalDoc();

  /// `inbox_id` cuối đã xử lý (gửi trong Hello để server bỏ qua phần đã nhận).
  Uint8List cursor = Uint8List(0);
  final convs = <String, ConvState>{};
  final msgs = <String, List<ChatMessage>>{};

  /// account_id (hex) -> khóa danh tính công khai đã thấy lần đầu (giao-thuc.md 6.2 bước 2).
  final peerIdentities = <String, Uint8List>{};

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'v': 1,
        'cursor': base64.encode(cursor),
        'convs': convs.values.map((c) => c.toJson()).toList(),
        'msgs': msgs.map((k, v) => MapEntry(k, v.map((m) => m.toJson()).toList())),
        'peers': peerIdentities.map((k, v) => MapEntry(k, base64.encode(v))),
      })));

  factory LocalDoc.fromBytes(Uint8List b) {
    final d = LocalDoc();
    if (b.isEmpty) return d;
    final j = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
    if (j['v'] != 1) throw FormatException('LocalDoc: phiên bản ${j['v']} không hỗ trợ');
    d.cursor = _b64(j['cursor'] as String);
    for (final c in (j['convs'] as List)) {
      final cs = ConvState.fromJson(c as Map<String, dynamic>);
      d.convs[cs.hexId] = cs;
    }
    (j['msgs'] as Map<String, dynamic>).forEach((k, v) {
      d.msgs[k] = (v as List).map((m) => ChatMessage.fromJson(m as Map<String, dynamic>)).toList();
    });
    (j['peers'] as Map<String, dynamic>).forEach((k, v) => d.peerIdentities[k] = _b64(v as String));
    return d;
  }
}
