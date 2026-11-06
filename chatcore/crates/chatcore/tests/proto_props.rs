//! Kiểm thử thuộc tính: mã hóa rồi giải mã Protobuf trả lại đúng giá trị (spec mục 8).
use chatcore::pb::*;
use prost::Message;
use proptest::prelude::*;

fn id() -> impl Strategy<Value = Vec<u8>> {
    prop::collection::vec(any::<u8>(), 16)
}

proptest! {
    #[test]
    fn send_message_roundtrip(conv in id(), cmid in id(), epoch in any::<u64>(), ct in prop::collection::vec(any::<u8>(), 0..2048), eph in any::<bool>()) {
        let f = ClientFrame { req_id: 7, body: Some(client_frame::Body::Send(SendMessage { conv_id: conv, client_msg_id: cmid, mls_epoch: epoch, ciphertext: ct, ephemeral: eph })) };
        let back = ClientFrame::decode(f.encode_to_vec().as_slice()).unwrap();
        prop_assert_eq!(f, back);
    }

    #[test]
    fn deliver_roundtrip(inbox in id(), conv in id(), seq in any::<u64>(), kind in 0i32..5, dev in id(), ep in any::<u64>(), ct in prop::collection::vec(any::<u8>(), 0..2048), ts in any::<u64>()) {
        let f = ServerFrame { req_id: 0, body: Some(server_frame::Body::Deliver(Deliver { inbox_id: inbox, conv_id: conv, seq, kind, sender_device_id: dev, mls_epoch: ep, ciphertext: ct, server_ts_ms: ts })) };
        prop_assert_eq!(ServerFrame::decode(f.encode_to_vec().as_slice()).unwrap(), f);
    }

    #[test]
    fn error_roundtrip(code in 0i32..12, msg in ".{0,64}", retry in any::<u32>(), epoch in any::<u64>()) {
        let e = Error { code, message: msg, retry_after_ms: retry, current_epoch: epoch };
        prop_assert_eq!(Error::decode(e.encode_to_vec().as_slice()).unwrap(), e);
    }

    #[test]
    fn payload_roundtrip(cmid in id(), at in any::<u64>(), body in ".{0,256}") {
        let p = Payload { version: 1, client_msg_id: cmid, sent_at_ms: at, reply_to: vec![], content: Some(payload::Content::Text(TextContent { body })) };
        prop_assert_eq!(Payload::decode(p.encode_to_vec().as_slice()).unwrap(), p);
    }

    // Dữ liệu rác không được làm panic: chỉ trả Err hoặc Ok.
    #[test]
    fn decode_garbage_never_panics(bytes in prop::collection::vec(any::<u8>(), 0..512)) {
        let _ = ClientFrame::decode(bytes.as_slice());
        let _ = ServerFrame::decode(bytes.as_slice());
        let _ = Payload::decode(bytes.as_slice());
    }
}

/// Số trường là hợp đồng: kiểm vài byte đã biết (ClientFrame.req_id = 1, ping = 16).
#[test]
fn wire_field_numbers_are_stable() {
    let f = ClientFrame { req_id: 1, body: Some(client_frame::Body::Ping(Ping { nonce: 5 })) };
    assert_eq!(f.encode_to_vec(), vec![0x08, 0x01, 0x82, 0x01, 0x02, 0x08, 0x05]);
}
