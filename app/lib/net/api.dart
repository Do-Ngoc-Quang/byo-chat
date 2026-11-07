import '../gen/chat/v1/services.pb.dart';
import 'connect_client.dart';

/// Các RPC của server dưới dạng hàm có kiểu (AuthService, DeviceService, KeyService).
/// Mỏng, không logic: logic đăng nhập nằm ở `auth/login_controller.dart`.
class ChatApi {
  ChatApi(this.client);

  final ConnectClient client;

  Future<RequestOtpResponse> requestOtp(RequestOtpRequest r) => client.unary('AuthService', 'RequestOtp', r, RequestOtpResponse.new);

  Future<VerifyOtpResponse> verifyOtp(VerifyOtpRequest r) => client.unary('AuthService', 'VerifyOtp', r, VerifyOtpResponse.new);

  Future<TokenPair> refreshToken(RefreshTokenRequest r) => client.unary('AuthService', 'RefreshToken', r, TokenPair.new);

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

  Future<StartLinkResponse> startLink(StartLinkRequest r) => client.unary('DeviceService', 'StartLink', r, StartLinkResponse.new);

  Future<ApproveLinkResponse> approveLink(ApproveLinkRequest r) => client.unary('DeviceService', 'ApproveLink', r, ApproveLinkResponse.new);

  /// Chờ tới 30 giây phía server.
  Future<CompleteLinkResponse> completeLink(CompleteLinkRequest r) =>
      client.unary('DeviceService', 'CompleteLink', r, CompleteLinkResponse.new);

  Future<GetGroupInfoResponse> getGroupInfo(GetGroupInfoRequest r) =>
      client.unary('ConversationService', 'GetGroupInfo', r, GetGroupInfoResponse.new);

  Future<CreateBackupUploadResponse> createBackupUpload(CreateBackupUploadRequest r) =>
      client.unary('BackupService', 'CreateBackupUpload', r, CreateBackupUploadResponse.new);

  /// Chưa có thiết bị: dùng session_ticket (giao-thuc.md 6.14).
  Future<GetLatestBackupResponse> getLatestBackup(GetLatestBackupRequest r) =>
      client.unary('BackupService', 'GetLatestBackup', r, GetLatestBackupResponse.new);

  Future<ListDevicesResponse> listDevices() => client.unary('DeviceService', 'ListDevices', ListDevicesRequest(), ListDevicesResponse.new);

  Future<RevokeDeviceResponse> revokeDevice(RevokeDeviceRequest r) =>
      client.unary('DeviceService', 'RevokeDevice', r, RevokeDeviceResponse.new);

  Future<SubmitCommitResponse> submitCommit(SubmitCommitRequest r, {required String idempotencyKey}) =>
      client.unary('ConversationService', 'SubmitCommit', r, SubmitCommitResponse.new, idempotencyKey: idempotencyKey);

  Future<FetchLogResponse> fetchLog(FetchLogRequest r) => client.unary('ConversationService', 'FetchLog', r, FetchLogResponse.new);

  Future<ListConversationsResponse> listConversations() =>
      client.unary('ConversationService', 'ListConversations', ListConversationsRequest(), ListConversationsResponse.new);
}
