import 'chatcore_api.dart';

/// Nền tảng không hỗ trợ (không có dart:ffi lẫn js_interop).
Future<ChatCore> openChatCore({String? path}) =>
    throw UnsupportedError('Nền tảng này chưa có cầu nối chatcore');
