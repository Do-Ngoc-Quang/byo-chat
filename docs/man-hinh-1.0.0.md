# Định nghĩa màn hình ứng dụng Chat

2026-11-03 · Quang

## 1. Phạm vi và quy ước

Tài liệu này chốt 18 màn hình của ứng dụng chat cá nhân và nhóm nhỏ trên mobile (Android; iOS để sau) và desktop/web, làm căn cứ để vẽ giao diện và viết mã. Phiên bản hiện tại là 1.0.0, chốt cùng đặc tả giao thức 1.0.0 (06/11/2026).

- **Phạm vi sản phẩm:** chat 1-1 và nhóm nhỏ, gọi video, đa thiết bị. Không có tổ chức, kênh hay tính năng doanh nghiệp.

- **Mã hóa đầu cuối:** là thuộc tính của hệ thống, không hiển thị trên giao diện. Không có màn hình xác minh khóa.

- **Mã màn hình:** `S-xx`, đánh số theo thứ tự trong bảng ở mục 2 và không đổi khi thêm màn mới (màn mới lấy số tiếp theo).

- **Nền tảng:** mỗi màn có bản mobile (390 × 844) và bản desktop (từ 1280 × 800). Màn nào không có bản riêng cho desktop thì ghi rõ trong cột "Desktop".

- **Phong cách:** tối giản, nền sáng, một màu nhấn xanh (`#2563EB`), phông Inter, vùng chạm tối thiểu 44 px, biểu tượng nét dạng SVG.

- **Tham chiếu:** mỗi màn ghi các RPC và sự kiện trong tài liệu "Đặc tả giao thức và luồng MLS" mà nó sử dụng; bản vẽ nằm trong "Thiết kế giao diện Chat".

## 2. Danh sách màn hình

18 màn hình, chia thành 5 nhóm; cả 18 màn đã có bản vẽ mobile và desktop trong "Thiết kế giao diện Chat".

| Mã   | Màn hình                     | Nhóm         | Trên desktop                 | Bản vẽ |
|------|------------------------------|--------------|------------------------------|--------|
| S-01 | Đăng nhập bằng số điện thoại | Vào ứng dụng | Thẻ giữa trang               | đã vẽ  |
| S-02 | Nhập mã xác nhận             | Vào ứng dụng | Thẻ giữa trang               | đã vẽ  |
| S-03 | Thiết lập hồ sơ              | Vào ứng dụng | Thẻ giữa trang               | đã vẽ  |
| S-04 | Danh sách chat               | Trò chuyện   | Cột giữa của bố cục ba cột   | đã vẽ  |
| S-05 | Khung chat                   | Trò chuyện   | Cột phải của bố cục ba cột   | đã vẽ  |
| S-06 | Menu thao tác tin nhắn       | Trò chuyện   | Menu chuột phải              | đã vẽ  |
| S-07 | Bảng đính kèm                | Trò chuyện   | Menu nổi                     | đã vẽ  |
| S-08 | Trình xem ảnh và tệp         | Trò chuyện   | Lớp phủ toàn màn hình        | đã vẽ  |
| S-09 | Trò chuyện mới               | Trò chuyện   | Hộp thoại                    | đã vẽ  |
| S-10 | Thông tin nhóm               | Trò chuyện   | Bảng bên phải                | đã vẽ  |
| S-11 | Hồ sơ liên hệ                | Trò chuyện   | Bảng bên phải                | đã vẽ  |
| S-12 | Cuộc gọi video               | Cuộc gọi     | Toàn màn hình                | đã vẽ  |
| S-13 | Cuộc gọi đến                 | Cuộc gọi     | Thẻ nổi                      | đã vẽ  |
| S-14 | Lịch sử cuộc gọi             | Cuộc gọi     | Trang trong thanh điều hướng | đã vẽ  |
| S-15 | Cài đặt                      | Cài đặt      | Trang hai cột                | đã vẽ  |
| S-16 | Thiết bị đã liên kết         | Cài đặt      | Mục con trong S-15           | đã vẽ  |
| S-17 | Liên kết thiết bị            | Cài đặt      | Trang có mã QR               | đã vẽ  |
| S-18 | Trạng thái trống và lỗi      | Dùng chung   | Theo từng vùng màn hình      | đã vẽ  |

Ghi chú: các màn cài đặt con (thông báo, quyền riêng tư, tài khoản) được gộp thành các dòng chuyển đổi trong S-15, không tách thành màn riêng ở phiên bản này.

## 3. Sơ đồ điều hướng

<figure data-embed="node/8b7b68f9-c080">

<figcaption>điều hướng giữa 17 màn hình · S-18 dùng chung nên không vẽ</figcaption>
</figure>

Người dùng đi vào qua S-01 đến S-03 rồi tới danh sách chat; từ S-04 đi tới khung chat, tạo cuộc trò chuyện mới, hoặc mở các tab Cuộc gọi và Cài đặt. Khi tài khoản đã có thiết bị khác, S-02 chuyển sang S-17 thay vì S-03 (không vẽ để tránh đường chéo). S-18 là các trạng thái dùng chung nên không có vị trí trong sơ đồ.

## 4. Đặc tả từng màn hình

Mỗi màn nêu mục đích, điều hướng, thành phần, trạng thái, dữ liệu và tiêu chí hoàn thành. Tên RPC và kiểu `Payload` lấy từ đặc tả giao thức 1.0.0.

### Nhóm Vào ứng dụng

#### S-01 Đăng nhập bằng số điện thoại

- **Mục đích:** nhập số điện thoại để nhận mã xác nhận, hoặc đăng nhập bằng passkey.

- **Điều hướng:** vào khi mở ứng dụng lần đầu hoặc hết phiên; đi tới S-02 khi bấm Tiếp tục.

- **Thành phần:** ô số kèm mã quốc gia, nút Tiếp tục, nút passkey, dòng điều khoản.

- **Trạng thái:** bình thường; đang gửi mã; số sai định dạng; bị giới hạn tần suất (hiển thị thời gian chờ); mất mạng.

- **Dữ liệu:** `AuthService.RequestOtp` (kênh SMS, kèm `captcha_token` khi hệ thống yêu cầu) trả `challenge_id` và `retry_after_ms`. Nút passkey dùng các RPC passkey của \`AuthService\` (đặc tả giao thức mục 6.11).

- **Hoàn thành khi:** số hợp lệ dẫn tới S-02 với `challenge_id`; khi bị giới hạn, nút Tiếp tục bị khóa đến hết `retry_after_ms`.

#### S-02 Nhập mã xác nhận

- **Mục đích:** xác nhận quyền sở hữu số điện thoại bằng mã 6 số.

- **Điều hướng:** từ S-01; đi tới S-03 nếu là tài khoản mới, đi tới S-17 (chế độ thiết bị mới) nếu tài khoản đã có thiết bị khác. Nếu tài khoản còn tồn tại nhưng không còn thiết bị nào đang dùng, hiện bước hỏi khóa sao lưu ngay trong S-02 (không thêm màn hình), rồi sang S-04.

- **Thành phần:** 6 ô số, đếm ngược gửi lại mã, nút Xác nhận, liên kết Đổi số điện thoại.

- **Trạng thái:** đang nhập; đang xác nhận; mã sai; mã hết hạn; hết lượt thử.

- **Dữ liệu:** `AuthService.VerifyOtp` trả `account_id`, `is_new_account` và `session_ticket` (dùng một lần, sống 10 phút). Gửi lại mã gọi lại `RequestOtp`. Bước khóa sao lưu: BackupService.GetLatestBackup (kèm session_ticket) tải bản sao lưu; người dùng nhập khóa để khôi phục hoặc chọn Bỏ qua, khi đó RegisterDevice(reset_identity = true) và tài khoản mất tin cũ.

- **Hoàn thành khi:** mã đúng chuyển đúng nhánh theo `is_new_account`; mã sai hiển thị lỗi tại ô nhập và không mất các số đã gõ.

#### S-03 Thiết lập hồ sơ

- **Mục đích:** đặt tên hiển thị và ảnh đại diện khi tạo tài khoản mới.

- **Điều hướng:** từ S-02; đi tới S-04 khi bấm Hoàn tất.

- **Thành phần:** ảnh đại diện (chọn ảnh hoặc chứ cái đầu), ô tên, nút Hoàn tất.

- **Trạng thái:** đang nhập; tên trống (nút Hoàn tất bị khóa); đang tạo tài khoản; lỗi mạng.

- **Dữ liệu:** `DeviceService.RegisterDevice` đổi `session_ticket` lấy cặp token. Tên và ảnh lưu qua ProfileService; ảnh đại diện tải lên bằng MediaService.CreateUpload với is_public = true (tệp công khai, không mã hóa).

- **Hoàn thành khi:** thiết bị được đăng ký, kết nối WebSocket thành công và người dùng vào S-04.

### Nhóm Trò chuyện

#### S-04 Danh sách chat

- **Mục đích:** xem các cuộc trò chuyện, tin mới nhất và số tin chưa đọc.

- **Điều hướng:** màn chính sau đăng nhập; đi tới S-05 (chọn một hàng), S-09 (nút soạn), S-14 và S-15 (thanh điều hướng).

- **Thành phần:** tiêu đề, nút soạn, ô tìm kiếm, bộ lọc (Tất cả, Chưa đọc, Nhóm), danh sách hàng (ảnh đại diện, tên, dòng xem trước, giờ, số chưa đọc), thanh điều hướng.

- **Trạng thái:** đang đồng bộ; có dữ liệu; trống (chưa có cuộc trò chuyện); kết quả tìm kiếm trống; mất mạng (hiển thị dữ liệu cũ).

- **Dữ liệu:** `ConversationService.ListConversations` để lấy danh sách và `head_seq`; khung `Welcome` và `SyncDone` trên WebSocket để biết đã đồng bộ xong. Dòng xem trước được giải mã trên máy, nên tìm kiếm là tìm cục bộ.

- **Hoàn thành khi:** tin mới đưa cuộc trò chuyện lên đầu và tăng số chưa đọc; mở được khi không có mạng.

- **Desktop:** cột giữa 340 px của bố cục ba cột; thanh điều hướng chuyển thành cột dọc bên trái.

#### S-05 Khung chat

- **Mục đích:** đọc và gửi tin nhắn trong một cuộc trò chuyện.

- **Điều hướng:** từ S-04 hoặc S-09; đi tới S-12 (nút gọi video), S-10 (nhóm) hoặc S-11 (1-1) qua nút thông tin, S-06 (giữ lâu tin nhắn), S-07 (nút đính kèm), S-08 (chạm vào ảnh hoặc tệp).

- **Thành phần:** thanh tiêu đề (tên, trạng thái đang nhập), danh sách tin theo thứ tự `seq`, bong bóng tin (có trích dẫn trả lời, cảm xúc, giờ và trạng thái gửi), chỉ báo đang nhập, ô nhập, nút đính kèm, nút gửi.

- **Trạng thái tin gửi:** đang gửi; đã gửi; đã xem; gửi lỗi (có nút thử lại). Tin tạo lúc mất mạng nằm trong hàng đợi và tự gửi lại.

- **Trạng thái màn:** đang tải lịch sử; hết lịch sử; cuộc trò chuyện mới (chưa có tin); mất mạng.

- **Dữ liệu:** `SendMessage` trên WebSocket (`client_msg_id` để loại trùng); `ConversationService.FetchLog` với `after_seq` (tối đa 200 mục); nội dung là `Payload` (`TextContent`, `MediaContent`, `reply_to`). Đã xem và đang nhập là tin điều khiển `ReadUpTo` và `Typing`, không phải trường WebSocket.

- **Hoàn thành khi:** tin hiển thị đúng thứ tự `seq`; gửi lại khi mất mạng không tạo tin trùng; chuyển từ đang gửi sang đã gửi sau khi server xác nhận.

- **Desktop:** cột phải của bố cục ba cột, ô nhập gửi bằng Enter, xuống dòng bằng Shift+Enter.

#### S-06 Menu thao tác tin nhắn

- **Mục đích:** thực hiện hành động trên một tin nhắn.

- **Điều hướng:** mở từ S-05 bằng thao tác giữ lâu (mobile) hoặc chuột phải (desktop); đóng về S-05.

- **Thành phần:** hàng cảm xúc nhanh; các mục Trả lời, Sao chép, Chỉnh sửa (chỉ tin của mình), Xóa.

- **Trạng thái:** tin của mình (có Chỉnh sửa); tin người khác (không có Chỉnh sửa); xác nhận trước khi Xóa.

- **Dữ liệu:** mỗi hành động là một `Payload`: `Reaction`, `Edit`, `Delete`; Trả lời dùng `reply_to`. Sao chép chỉ xảy ra trên máy.

- **Hoàn thành khi:** cảm xúc, chỉnh sửa và xóa hiển thị đồng nhất trên mọi thiết bị của cả hai bên.

#### S-07 Bảng đính kèm

- **Mục đích:** chọn ảnh, video hoặc tệp để gửi.

- **Điều hướng:** mở từ nút đính kèm ở S-05; chọn xong thì quay về S-05 kèm bản xem trước.

- **Thành phần:** các lựa chọn Thư viện ảnh, Máy ảnh, Tệp; lưới ảnh gần đây; ô ghi chú; nút Gửi.

- **Trạng thái:** chưa có quyền truy cập thư viện (hướng dẫn cấp quyền); đã chọn nhiều mục; đang tải lên (có thanh tiến độ và nút hủy); tải lên lỗi (thử lại).

- **Dữ liệu:** `MediaService.CreateUpload`, `CompleteUpload` (tải lên theo từng phần), sau đó gửi `Payload` kiểu `MediaContent` kèm `caption`, kích thước và ảnh thu nhỏ.

- **Hoàn thành khi:** tải lên bị ngắt giữa chừng có thể thử lại mà không chọn lại tệp.

- **Desktop:** menu nổi từ nút đính kèm; thêm kéo thả tệp vào khung chat.

#### S-08 Trình xem ảnh và tệp

- **Mục đích:** xem ảnh, video và tải tệp đã nhận.

- **Điều hướng:** mở từ S-05 khi chạm vào mục media; đóng về S-05.

- **Thành phần:** vùng xem toàn màn hình, thanh đầu (người gửi, thời gian, nút đóng), nút Lưu, nút Chia sẻ, vuốt để chuyển mục kế tiếp.

- **Trạng thái:** đang tải (hiển thị ảnh thu nhỏ mờ); đã tải; tải lỗi; tệp không xem trước được (chỉ hiện tên, dung lượng và nút Lưu).

- **Dữ liệu:** `MediaService.GetDownloadUrl` lấy đường dẫn tạm; nội dung được giải mã trên máy bằng khóa trong `MediaContent`.

- **Hoàn thành khi:** đường dẫn hết hạn được lấy lại tự động; ảnh đã xem được lưu đệm để mở lại không cần mạng.

- **Desktop:** lớp phủ toàn cửa sổ, phím mũi tên chuyển mục, Esc để đóng.

#### S-09 Trò chuyện mới

- **Mục đích:** bắt đầu trò chuyện 1-1 hoặc tạo nhóm.

- **Điều hướng:** mở từ nút soạn ở S-04; chọn một người thì sang S-05; chọn Tạo nhóm mới thì chọn nhiều người, đặt tên rồi sang S-05.

- **Thành phần:** ô nhập chính xác số điện thoại hoặc email, mục Tạo nhóm mới, danh sách người đã từng trò chuyện theo thứ tự tên.

- **Trạng thái:** chưa có ai đã từng trò chuyện; không tìm thấy tài khoản (số hoặc email chưa dùng ứng dụng); tra cứu bị giới hạn số lần; đang tạo cuộc trò chuyện.

- **Dữ liệu:** `KeyService.FetchKeyPackages` lấy khóa của người được chọn, rồi `ConversationService.CreateConversation`. Nếu cuộc 1-1 đã tồn tại (`existed = true`) thì mở cuộc cũ. Tìm người dùng bằng \`ProfileService.LookupAccount\` với số điện thoại hoặc email nhập chính xác, trước \`FetchKeyPackages\`; không đồng bộ danh bạ, không tìm theo tên (xem mục 7).

- **Hoàn thành khi:** chọn người đã có cuộc 1-1 sẽ mở lại cuộc đó, không tạo thêm.

- **Desktop:** hộp thoại giữa màn hình, rộng 480 px.

#### S-10 Thông tin nhóm

- **Mục đích:** xem và quản lý một nhóm.

- **Điều hướng:** mở từ nút thông tin ở S-05 của nhóm; chọn một thành viên thì sang S-11; nút Gọi video sang S-12; Rời nhóm quay về S-04.

- **Thành phần:** ảnh và tên nhóm, số thành viên, các nút nhanh (Gọi video, Tắt tiếng, Tìm kiếm), danh sách thành viên kèm vai trò, Thêm thành viên, Rời nhóm.

- **Trạng thái:** quản trị viên (có Thêm, Gỡ thành viên, đổi vai trò); thành viên thường (chỉ xem và Rời nhóm); đang áp dụng thay đổi; thay đổi thất bại do xung đột.

- **Dữ liệu:** thêm, gỡ và đổi vai trò đi qua `ConversationService.SubmitCommit` (có `added`, `removed_account_ids`, `role_changes`). Khi server trả lỗi xung đột epoch, client tự dựng lại thay đổi và gửi lại, không hiện lỗi cho người dùng.

- **Hoàn thành khi:** hai quản trị viên cùng sửa một lúc thì cả hai thay đổi đều được áp dụng.

- **Desktop:** bảng bên phải rộng 340 px, mở cùng khung chat.

#### S-11 Hồ sơ liên hệ

- **Mục đích:** xem thông tin một người và thao tác nhanh với người đó.

- **Điều hướng:** mở từ thông tin ở S-05 (1-1) hoặc từ một thành viên ở S-10; đóng về màn trước.

- **Thành phần:** ảnh đại diện, tên, số điện thoại, các nút Gọi video, Tắt tiếng, Tìm kiếm; mục Ảnh và tệp đã chia sẻ; nút Chặn.

- **Trạng thái:** bình thường; đã tắt tiếng; đã chặn; chưa có ảnh hay tệp chung.

- **Dữ liệu:** tên và ảnh lấy từ hồ sơ người đó; mục ảnh và tệp đọc từ tin đã giải mã trên máy. Tên và ảnh lấy bằng ProfileService.GetProfiles. Nút Chặn gọi BlockService.BlockUser; chặn chỉ áp dụng cho cuộc 1-1, không áp dụng trong nhóm.

- **Hoàn thành khi:** mục ảnh và tệp chỉ gồm nội dung của đúng cuộc trò chuyện đang xem.

- **Desktop:** dùng cùng bảng bên phải với S-10.

### Nhóm Cuộc gọi

#### S-12 Cuộc gọi video

- **Mục đích:** nói chuyện video với một hoặc nhiều người trong cuộc trò chuyện.

- **Điều hướng:** vào từ nút gọi ở S-05, S-10, S-11 hoặc khi trả lời ở S-13; kết thúc thì về S-05.

- **Thành phần:** hình người đối diện, hình của mình, tên và thời gian gọi, các nút Tắt micro, Tắt camera, Đổi camera (mobile), Chia sẻ màn hình (desktop), Kết thúc.

- **Trạng thái:** đang đổ chuông; đang kết nối; đang gọi; mạng yếu (hiện biểu tượng); đang kết nối lại; đã kết thúc; không được cấp quyền micro hoặc camera.

- **Dữ liệu:** `CallService.StartCall` hoặc `JoinCall` trả `CallTicket` (`livekit_url`, `token`); kết thúc bằng `EndCall`. Khi gọi xong, client gửi `Payload` kiểu `CallEvent` (bắt đầu, kết thúc, nhỡ) để làm dữ liệu cho S-14.

- **Hoàn thành khi:** rớt mạng tạm thời tự kết nối lại mà không kết thúc cuộc gọi; mọi trường hợp kết thúc đều để lại một mục `CallEvent` trong cuộc trò chuyện.

- **Desktop:** toàn màn hình; hình đối diện lớn, hình của mình ở góc phải; có chia sẻ màn hình.

#### S-13 Cuộc gọi đến

- **Mục đích:** báo có người gọi và cho phép trả lời hoặc từ chối.

- **Điều hướng:** tự hiện khi có cuộc gọi đến; Trả lời sang S-12, Từ chối quay về màn đang dùng.

- **Thành phần:** ảnh và tên người gọi, dòng "Cuộc gọi video đến", nút Từ chối (đỏ), nút Trả lời (xanh lá).

- **Trạng thái:** đang đổ chuông; người gọi đã dừng (chuyển thành cuộc gọi nhỡ); đã trả lời ở thiết bị khác của mình (tự đóng).

- **Dữ liệu:** Trả lời gọi `CallService.JoinCall`. Thông báo cuộc gọi đến đi qua `PushService` (có `voip_token` trên iOS) khi ứng dụng đóng; khi ứng dụng đang mở, máy chủ gửi khung WebSocket IncomingCall.

- **Hoàn thành khi:** trả lời ở một thiết bị thì các thiết bị khác ngừng đổ chuông; cuộc gọi nhỡ để lại mục trong S-14.

- **Desktop:** thẻ nổi giữa màn hình trên nền tối.

#### S-14 Lịch sử cuộc gọi

- **Mục đích:** xem các cuộc gọi đi, đến và nhỡ, và gọi lại.

- **Điều hướng:** mở từ tab Cuộc gọi; chạm nút gọi lại sang S-12; chạm vào hàng sang S-05.

- **Thành phần:** danh sách hàng (ảnh, tên, hướng gọi, thời điểm, thời lượng), bộ lọc Tất cả và Nhỡ, nút gọi lại trên mỗi hàng.

- **Trạng thái:** có dữ liệu; trống (chưa có cuộc gọi); cuộc gọi nhỡ được làm nổi bằng màu đỏ.

- **Dữ liệu:** không có RPC riêng; danh sách được dựng cục bộ từ các `Payload` kiểu `CallEvent` (`KIND_STARTED`, `KIND_ENDED`, `KIND_MISSED`, kèm `duration_ms`).

- **Hoàn thành khi:** mỗi cuộc gọi chỉ hiển thị một dòng dù có nhiều mục `CallEvent`.

- **Desktop:** trang riêng chọn từ cột điều hướng bên trái.

### Nhóm Cài đặt

#### S-15 Cài đặt

- **Mục đích:** chỉnh hồ sơ, thông báo, quyền riêng tư và sao lưu.

- **Điều hướng:** mở từ tab Cài đặt; mục Thiết bị đã liên kết sang S-16; Đăng xuất về S-01.

- **Thành phần:** thẻ hồ sơ (ảnh, tên, số điện thoại); các nhóm dòng: Thông báo (bật/tắt, xem trước nội dung), Quyền riêng tư (gửi trạng thái đã xem, gửi trạng thái đang nhập), Sao lưu (bật/tắt, lần gần nhất), Bảo mật (dòng Passkey, dòng Người đã chặn mở danh sách ngay trong màn này), Thiết bị đã liên kết, Đăng xuất.

- **Trạng thái:** bình thường; chưa cấp quyền thông báo của hệ điều hành (có hướng dẫn); sao lưu đang chạy; xác nhận trước khi đăng xuất.

- **Dữ liệu:** `PushService.RegisterPushToken` và `UnregisterPushToken` cho thông báo; `BackupService.GetLatestBackup` và `CreateBackupUpload` cho sao lưu. Tùy chọn đã xem và đang nhập chỉ đổi việc client có gửi tin điều khiển `ReadUpTo` và `Typing` hay không. Sửa tên và ảnh qua ProfileService; đăng ký passkey qua các RPC passkey của AuthService; danh sách chặn qua BlockService.ListBlocked và UnblockUser.

- **Hoàn thành khi:** tắt gửi trạng thái đã xem thì client ngừng gửi `ReadUpTo` nhưng vẫn nhận được tin.

- **Desktop:** trang hai cột: danh mục bên trái, nội dung bên phải; S-16 là một mục trong danh mục này.

#### S-16 Thiết bị đã liên kết

- **Mục đích:** xem và gỡ các thiết bị đang dùng tài khoản.

- **Điều hướng:** từ S-15; nút Liên kết thiết bị mới sang S-17.

- **Thành phần:** danh sách thiết bị (biểu tượng nền tảng, tên, lần hoạt động cuối, nơi đăng nhập), nhãn Thiết bị này, nút Gỡ, nút Liên kết thiết bị mới.

- **Trạng thái:** đang tải; chỉ có thiết bị này; đang gỡ (có hộp xác nhận); gỡ lỗi.

- **Dữ liệu:** `DeviceService.ListDevices` và `RevokeDevice` (cần `revocation_statement` do khóa tài khoản ký; việc ký do client thực hiện).

- **Hoàn thành khi:** không thể gỡ chính thiết bị đang dùng; thiết bị bị gỡ mất quyền truy cập và bị đăng xuất.

- **Desktop:** nội dung của mục trong S-15.

#### S-17 Liên kết thiết bị

- **Mục đích:** thêm một thiết bị mới vào tài khoản mà không cần nhập lại mật khẩu.

- **Hai chế độ:** thiết bị mới hiển thị mã QR và mã ngắn (bản desktop); thiết bị cũ quét mã và phê duyệt (bản mobile).

- **Điều hướng:** thiết bị cũ vào từ S-16; thiết bị mới vào từ S-02 khi tài khoản đã có thiết bị; thành công thì thiết bị mới sang S-04.

- **Thành phần:** khung quét QR (thiết bị cũ); thẻ thiết bị đang chờ phê duyệt; 6 số xác nhận phải khớp giữa hai máy; nút Phê duyệt và Từ chối; đếm ngược hết hạn và nút Tạo mã mới (thiết bị mới).

- **Trạng thái:** đang chờ quét; đã quét, chờ phê duyệt; mã hết hạn; bị từ chối; hoàn tất; không được cấp quyền camera.

- **Dữ liệu:** thiết bị mới gọi `DeviceService.StartLink` (nhận `link_id`, `short_code`, `expires_ms`) rồi `CompleteLink` (chờ tối đa 30 giây); thiết bị cũ gọi `ApproveLink`.

- **Hoàn thành khi:** chỉ phê duyệt được khi mã xác nhận hai máy khớp và chưa hết hạn; sau khi liên kết, thiết bị mới chỉ đọc được tin nhắn mới, không đọc được tin cũ.

### Nhóm Dùng chung

#### S-18 Trạng thái trống và lỗi

- **Mục đích:** thiết kế một lần các trạng thái trống, lỗi và mất mạng để mọi màn hình dùng chung.

- **Nội dung bản vẽ:** một tờ tổng hợp các mẫu (danh sách trống, không tìm thấy, lỗi tải có nút thử lại, thanh mất mạng, đang đồng bộ, hết phiên). Quy tắc chi tiết ở mục 5.

- **Hoàn thành khi:** mỗi màn ở mục 4 dùng đúng các mẫu này thay vì tự vẽ trạng thái riêng.

## 5. Trạng thái dùng chung

Bảy trạng thái này dùng chung cho mọi màn; màn nào cần hành vi khác phải nêu riêng ở mục 4. Bản vẽ tương ứng là S-18.

| Trạng thái     | Khi nào                                                     | Hiển thị                                                | Hành vi                                                                 |
|----------------|-------------------------------------------------------------|---------------------------------------------------------|-------------------------------------------------------------------------|
| Đang tải       | lần đầu mở màn, chưa có dữ liệu cục bộ                      | khung xương cùng hình dạng với nội dung thật            | thay bằng dữ liệu khi có; không dùng vòng quay toàn màn                 |
| Trống          | chưa có dữ liệu (chưa có cuộc trò chuyện, chưa có cuộc gọi) | biểu tượng, một câu giải thích, một nút hành động chính | nút dẫn tới việc phù hợp (ví dụ soạn tin mới)                           |
| Không tìm thấy | tìm kiếm không có kết quả                                   | câu nêu từ khóa đã tìm                                  | không có nút hành động                                                  |
| Lỗi tải        | yêu cầu thất bại khi không phải mất mạng                    | thông báo ngắn trong vùng nội dung, kèm nút Thử lại     | thử lại đúng yêu cầu đó; giữ dữ liệu cũ nếu có                          |
| Mất mạng       | không kết nối được máy chủ                                  | thanh nhỏ ở đầu màn "Đang chờ kết nối"                  | vẫn đọc được dữ liệu cũ; tin gửi vào hàng đợi và tự gửi lại khi có mạng |
| Đang đồng bộ   | sau khi kết nối lại, trước khi nhận `SyncDone`              | dòng "Đang cập nhật…" dưới tiêu đề                      | tự ẩn khi đồng bộ xong                                                  |
| Hết phiên      | token không làm mới được, hoặc thiết bị bị gỡ               | màn thông báo "Bạn đã được đăng xuất"                   | thử `RefreshToken` trước; chỉ khi thất bại mới về S-01                  |

Quy tắc chung: lỗi hiển thị bằng ngôn ngữ đời thường, không hiện mã lỗi; lỗi do xung đột epoch (mục 5 của đặc tả giao thức) được client tự thử lại và không bao giờ hiển thị.

## 6. Truy vết màn hình với giao thức

Bảng dưới đây liệt kê RPC và sự kiện mà mỗi màn sử dụng. Mọi khoảng trống so với đặc tả giao thức 0.1.0 đã được lấp bằng đặc tả 1.0.0 (xem mục 7).

| Màn  | RPC hoặc sự kiện sử dụng                                                                                                  | Khoảng trống                                 |
|------|---------------------------------------------------------------------------------------------------------------------------|----------------------------------------------|
| S-01 | `AuthService.RequestOtp`                                                                                                  | không (đã có RPC passkey)                    |
| S-02 | `AuthService.VerifyOtp`, `RequestOtp`                                                                                     | không                                        |
| S-03 | `DeviceService.RegisterDevice`                                                                                            | không (ProfileService)                       |
| S-04 | `ConversationService.ListConversations`; khung `Welcome`, `SyncDone`                                                      | không                                        |
| S-05 | `SendMessage` (WebSocket), `ConversationService.FetchLog`; `Payload`: `TextContent`, `MediaContent`, `ReadUpTo`, `Typing` | không                                        |
| S-06 | `Payload`: `Reaction`, `Edit`, `Delete`, `reply_to`                                                                       | không                                        |
| S-07 | `MediaService.CreateUpload`, `CompleteUpload`; `Payload`: `MediaContent`                                                  | không                                        |
| S-08 | `MediaService.GetDownloadUrl`                                                                                             | không                                        |
| S-09 | `KeyService.FetchKeyPackages`, `ConversationService.CreateConversation`                                                   | không (ProfileService.LookupAccount)         |
| S-10 | `ConversationService.SubmitCommit`, `GetGroupInfo`                                                                        | không                                        |
| S-11 | tin đã giải mã trên máy                                                                                                   | không (GetProfiles; BlockService)            |
| S-12 | `CallService.StartCall`, `JoinCall`, `EndCall`; `Payload`: `CallEvent`                                                    | không                                        |
| S-13 | `CallService.JoinCall`; `PushService`                                                                                     | không (khung IncomingCall)                   |
| S-14 | `Payload`: `CallEvent` (dựng cục bộ)                                                                                      | không                                        |
| S-15 | `PushService.RegisterPushToken`, `UnregisterPushToken`; `BackupService.GetLatestBackup`, `CreateBackupUpload`             | không (ProfileService; passkey; ListBlocked) |
| S-16 | `DeviceService.ListDevices`, `RevokeDevice`                                                                               | không                                        |
| S-17 | `DeviceService.StartLink`, `ApproveLink`, `CompleteLink`                                                                  | không                                        |
| S-18 | khung `Error` và mã đóng kết nối WebSocket                                                                                | không                                        |

## 7. Điểm mở và ngoài phạm vi

Sáu điểm mở trước đã được quyết định ngày 04/11/2026; kết quả ghi dưới đây và đã đưa vào đặc tả giao thức 1.0.0. Việc vẽ thêm một số phần giao diện không chặn bản 1.0.0, làm trong giai đoạn phát triển.

**Điểm mở**

1.  **Passkey (S-01):** đã quyết định giữ nút passkey ở S-01 và bổ sung RPC đăng ký, đăng nhập (đặc tả giao thức mục 6.11). Việc đăng ký passkey từ S-15 chưa có trên bản vẽ.

2.  **Hồ sơ (S-03, S-11, S-15):** đã quyết định máy chủ lưu hồ sơ dạng thường; ảnh đại diện là tệp công khai, không mã hóa. Dùng \`ProfileService\` (đặc tả giao thức mục 6.12).

3.  **Chặn người dùng (S-11):** đã quyết định đưa vào bản 1, chặn ở máy chủ bằng \`BlockService\` (đặc tả giao thức mục 6.13). Nút Chặn đã có ở S-11; danh sách người đã chặn (\`ListBlocked\`) chưa có chỗ hiển thị, cần thêm vào S-15.

4.  **Cuộc gọi đến khi ứng dụng đang mở (S-13):** đã quyết định thêm khung WebSocket \`IncomingCall\` (đặc tả giao thức mục 6.10).

5.  **Tìm người theo số điện thoại (S-09):** đã quyết định chỉ cho nhập chính xác số điện thoại hoặc email qua \`LookupAccount\`; không đồng bộ danh bạ, không tìm theo tên (mục 6.12). Bản vẽ S-09 đã sửa ô tìm.

6.  **Mất toàn bộ thiết bị:** đã quyết định đăng nhập lại bằng OTP, khôi phục lịch sử từ bản sao lưu nếu có; nếu không có thì tài khoản giữ nguyên nhưng mất tin cũ (đặc tả giao thức mục 6.14). Cần thêm một bước vào S-02 (hỏi khóa sao lưu hoặc bỏ qua), chưa vẽ. Khi không có bản sao lưu, thiết bị mới tự vào lại các nhóm cũ và người khác không thấy cảnh báo; chấp nhận rủi ro chiếm số điện thoại (đặc tả giao thức 6.14).

**Ngoài phạm vi 0.2.0**

- Chuyển tiếp tin nhắn, ghim tin, tìm kiếm trong một cuộc trò chuyện, tin nhắn biến mất.

- Cuộc gọi thoại thuần (không video) và cuộc gọi nhóm có giao diện riêng.

- Chế độ tối và đa ngôn ngữ (hiện chỉ tiếng Việt, giao diện sáng).

- Tổ chức, kênh và các tính năng doanh nghiệp.

- Màn hình xác minh khóa mã hóa (ẩn khỏi người dùng theo quyết định thiết kế).
