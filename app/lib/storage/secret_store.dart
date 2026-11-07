import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Kho bí mật nhỏ (khóa mã hóa snapshot, token). Android: Keystore; Web: WebCrypto + localStorage
/// (KHÔNG có phần cứng, xem ADR 0008). Giá trị là chuỗi (base64/JSON do người gọi tự mã hóa).
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? s]) : _s = s ?? const FlutterSecureStorage();

  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// Dùng cho test.
class MemorySecretStore implements SecretStore {
  final map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}
