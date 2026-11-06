# 0002 — Cách tách file proto `chat.v1`

- **Trạng thái:** Chấp nhận (06/11/2026)
- **Bối cảnh:** Spec 1.0.0 đặt `CallKind` trong `services.proto` nhưng `ws.proto` (IncomingCall) cũng dùng; buf không cho import vòng. `Payload` (mục 7.3) cần mã sinh cho `chatcore`. Số trường nằm trong ô trống `13, 14` / `14` của khung chỉ ghi chú.
- **Quyết định:** chuyển `CallKind` sang `common.proto`; thêm `payload.proto` cho `Payload`; ghi `reserved 13, 14` (ClientFrame) và `reserved 14` (ServerFrame). Không đổi số trường nên không phá tương thích. `buf.yaml` miễn `RPC_RESPONSE_STANDARD_NAME` và `RPC_REQUEST_RESPONSE_UNIQUE` vì spec chủ ý dùng chung response (TokenPair, CallTicket, Profile...).
- **Hệ quả:** spec lên 1.0.1 (làm rõ). Muốn đổi tên response cho đúng luật buf thì phải sửa spec trước.
