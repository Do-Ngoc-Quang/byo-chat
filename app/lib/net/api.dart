import '../gen/chat/v1/services.pb.dart';
import 'connect_client.dart';

/// Các RPC của server dưới dạng hàm có kiểu (AuthService, DeviceService, KeyService).
/// Mỏng, không logic: logic đăng nhập nằm ở `auth/login_controller.dart`.
class ChatApi {
  ChatApi(this.client);

  final ConnectClient client;

  Future<RequestOtpResponse> requestOtp(RequestOtpRequest r) =>
      client.unary('AuthService', 'RequestOtp', r, RequestOtpResponse.new);

  Future<VerifyOtpResponse> verifyOtp(VerifyOtpRequest r) =>
      client.unary('AuthService', 'VerifyOtp', r, VerifyOtpResponse.new);

  Future<TokenPair> refreshToken(RefreshTokenRequest r) =>
      client.unary('AuthService', 'RefreshToken', r, TokenPair.new);

  Future<RegisterDeviceResponse> registerDevice(RegisterDeviceRequest r) =>
      client.unary('DeviceService', 'RegisterDevice', r, RegisterDeviceResponse.new);

  Future<KeyPackageCount> countKeyPackages() =>
      client.unary('KeyService', 'CountKeyPackages', CountKeyPackagesRequest(), KeyPackageCount.new);

  Future<KeyPackageCount> uploadKeyPackages(UploadKeyPackagesRequest r) =>
      client.unary('KeyService', 'UploadKeyPackages', r, KeyPackageCount.new);

  Future<FetchKeyPackagesResponse> fetchKeyPackages(FetchKeyPackagesRequest r) =>
      client.unary('KeyService', 'FetchKeyPackages', r, FetchKeyPackagesResponse.new);

  Future<LookupAccountResponse> lookupAccount(LookupAccountRequest r) =>
      client.unary('ProfileService', 'LookupAccount', r, LookupAccountResponse.new);

  Future<CreateConversationResponse> createConversation(CreateConversationRequest r, {String? idempotencyKey}) =>
      client.unary('ConversationService', 'CreateConversation', r, CreateConversationResponse.new, idempotencyKey: idempotencyKey);

  Future<FetchLogResponse> fetchLog(FetchLogRequest r) =>
      client.unary('ConversationService', 'FetchLog', r, FetchLogResponse.new);

  Future<ListConversationsResponse> listConversations() =>
      client.unary('ConversationService', 'ListConversations', ListConversationsRequest(), ListConversationsResponse.new);
}
