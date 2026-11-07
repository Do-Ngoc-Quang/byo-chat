//! Bề mặt API của lõi cho cầu nối FFI/WASM (ADR 0006): mọi tham số và kết quả là byte.
//! Một `Core` = một thiết bị + các nhóm MLS theo khóa `conv` do phía gọi đặt (thường là `group_id`).
//! `call(op, args)` nhận/trả danh sách byte đã đóng gói bằng `pack`/`unpack`, để FFI và WASM chỉ
//! cần chuyển một hàm duy nhất. Trạng thái nằm trong bộ nhớ; lưu bền là việc của giai đoạn sau.
use crate::credential::{self, Credential};
use crate::mls::{Device, Result, CIPHERSUITE};
use openmls::prelude::{tls_codec::*, *};
use openmls_basic_credential::SignatureKeyPair;
use std::collections::HashMap;

mod persist;

/// Đóng gói danh sách byte: mỗi phần tử là độ dài u32 little-endian rồi dữ liệu.
pub fn pack(items: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::with_capacity(items.iter().map(|i| 4 + i.len()).sum());
    for i in items {
        out.extend_from_slice(&(i.len() as u32).to_le_bytes());
        out.extend_from_slice(i);
    }
    out
}

/// Ngược lại của `pack`; lỗi nếu cắt cụt.
pub fn unpack(mut b: &[u8]) -> Result<Vec<Vec<u8>>> {
    let mut out = Vec::new();
    while !b.is_empty() {
        let (len, rest) = b.split_at_checked(4).ok_or("gói bị cắt cụt")?;
        let len = u32::from_le_bytes(len.try_into().unwrap()) as usize;
        let (item, rest) = rest.split_at_checked(len).ok_or("gói bị cắt cụt")?;
        out.push(item.to_vec());
        b = rest;
    }
    Ok(out)
}

pub struct Core {
    device: Device,
    groups: HashMap<Vec<u8>, MlsGroup>,
    /// Khóa danh tính tài khoản, có ở thiết bị đầu tiên hoặc thiết bị khôi phục từ sao lưu.
    identity: Option<SignatureKeyPair>,
    /// Dữ liệu ứng dụng đi cùng snapshot (kho tin nhắn cục bộ, con trỏ hộp thư...): ghi MỘT lần với trạng thái
    /// MLS nên không bao giờ lệch nhau sau khi sập (ADR 0009).
    app_state: Vec<u8>,
}

const NO_GROUP: &str = "không có nhóm cho conv này";

impl Core {
    pub fn new(identity: &[u8]) -> Result<Self> {
        Ok(Self { device: Device::new(identity)?, groups: HashMap::new(), identity: None, app_state: Vec::new() })
    }

    /// Như `new_device` nhưng nhận đối số đóng gói qua cầu nối:
    /// [account_id, device_id, identity_key (rỗng = sinh mới), created_ms u64 LE].
    pub fn open_device(args: &[u8]) -> Result<Self> {
        let a = unpack(args)?;
        if a.len() != 4 {
            return Err(format!("open_device: cần 4 đối số, nhận {}", a.len()).into());
        }
        let created = u64::from_le_bytes(a[3].as_slice().try_into().map_err(|_| "created_ms phải 8 byte")?);
        Self::new_device(&a[0], &a[1], if a[2].is_empty() { None } else { Some(&a[2]) }, created)
    }

    /// Tạo thiết bị theo spec 6.1: sinh khóa ký của thiết bị, và khóa danh tính tài khoản nếu chưa có
    /// (`identity_key` = kết quả `identity_export`, dùng khi khôi phục), rồi dựng credential 136 byte.
    pub fn new_device(account_id: &[u8], device_id: &[u8], identity_key: Option<&[u8]>, created_ms: u64) -> Result<Self> {
        let acct: [u8; 16] = account_id.try_into().map_err(|_| "account_id phải 16 byte")?;
        let dev: [u8; 16] = device_id.try_into().map_err(|_| "device_id phải 16 byte")?;
        let identity = match identity_key {
            Some(b) => credential::identity_from_bytes(b)?,
            None => SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())?,
        };
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())?;
        let cred = credential::build(&identity, &acct, &dev, signer.public(), created_ms)?;
        Ok(Self { device: Device::from_parts(signer, cred)?, groups: HashMap::new(), identity: Some(identity), app_state: Vec::new() })
    }

    /// Gọi một thao tác theo tên. Bảng thao tác (đối số -> kết quả):
    /// `key_package` [] -> [kp]; `create_group` [conv] -> []; `add_members` [conv, kp...] ->
    /// [commit, welcome, group_info]; `group_info` [conv] -> [gi]; `join_welcome` [conv, welcome] -> [];
    /// `apply_commit` [conv, commit] -> []; `external_join` [conv, gi] -> [commit];
    /// `encrypt` [conv, pt] -> [ct]; `decrypt` [conv, ct] -> [pt]; `epoch` [conv] -> [u64 LE];
    /// `sframe_key` [conv, call_id] -> [key]; `credential` [] -> [credential, device_pub, identity_pub];
    /// `identity_export` [] -> [khóa danh tính, NHẠY CẢM]; `key_packages` [count u32 LE] -> [kp...] (một lần,
    /// hạn 30 ngày); `last_resort_key_package` [] -> [kp] (hạn 90 ngày); `verify_key_package`
    /// [kp, credential, identity_pub, expected_account_id] -> [] (spec 6.2 bước 2); `snapshot` [key 32 byte] ->
    /// [sealed] (lưu bền, ADR 0008; khôi phục bằng `Core::open_restore`); `rename_group` [cũ, mới] -> []; `drop_group`
    /// [conv] -> [] (xóa cả khóa); `group_members` [conv] -> [credential của từng lá]; `app_state_set` [bytes] -> [];
    /// `app_state_get` [] -> [bytes] (đi cùng snapshot).
    pub fn call(&mut self, op: &str, args: &[u8]) -> Result<Vec<u8>> {
        let a = unpack(args)?;
        let need = |n: usize| -> Result<()> {
            if a.len() == n {
                Ok(())
            } else {
                Err(format!("{op}: cần {n} đối số, nhận {}", a.len()).into())
            }
        };
        let d = &self.device;
        Ok(match op {
            "key_package" => {
                need(0)?;
                let kp = MlsMessageOut::from(d.key_package()?).tls_serialize_detached()?;
                pack(&[&kp])
            }
            "create_group" => {
                need(1)?;
                if self.groups.contains_key(&a[0]) {
                    return Err("nhóm đã tồn tại".into());
                }
                self.groups.insert(a[0].clone(), d.create_group()?);
                pack(&[])
            }
            "add_members" => {
                if a.len() < 2 {
                    return Err("add_members: cần conv và ít nhất một KeyPackage".into());
                }
                let kps = a[1..].iter().map(|b| parse_key_package(d, b)).collect::<Result<Vec<_>>>()?;
                let g = self.groups.get_mut(&a[0]).ok_or(NO_GROUP)?;
                let out = d.add(g, &kps)?;
                pack(&[&out.commit, &out.welcome.unwrap_or_default(), &out.group_info])
            }
            "group_info" => {
                need(1)?;
                pack(&[&d.group_info(self.groups.get(&a[0]).ok_or(NO_GROUP)?)?])
            }
            "join_welcome" => {
                need(2)?;
                let g = d.join_welcome(&a[1])?;
                self.groups.insert(a[0].clone(), g);
                pack(&[])
            }
            "apply_commit" => {
                need(2)?;
                d.apply_commit(self.groups.get_mut(&a[0]).ok_or(NO_GROUP)?, &a[1])?;
                pack(&[])
            }
            "external_join" => {
                need(2)?;
                let (g, commit) = d.external_join(&a[1])?;
                self.groups.insert(a[0].clone(), g);
                pack(&[&commit])
            }
            "encrypt" => {
                need(2)?;
                pack(&[&d.encrypt(self.groups.get_mut(&a[0]).ok_or(NO_GROUP)?, &a[1])?])
            }
            "decrypt" => {
                need(2)?;
                pack(&[&d.decrypt(self.groups.get_mut(&a[0]).ok_or(NO_GROUP)?, &a[1])?])
            }
            "epoch" => {
                need(1)?;
                let e = self.groups.get(&a[0]).ok_or(NO_GROUP)?.epoch().as_u64();
                pack(&[&e.to_le_bytes()])
            }
            "sframe_key" => {
                need(2)?;
                pack(&[&d.sframe_key(self.groups.get(&a[0]).ok_or(NO_GROUP)?, &a[1])?])
            }
            "credential" => {
                need(0)?;
                let id = self.identity.as_ref().ok_or("thiết bị này không giữ khóa danh tính")?;
                pack(&[&d.identity, d.signer.public(), id.public()])
            }
            "identity_export" => {
                need(0)?;
                let id = self.identity.as_ref().ok_or("thiết bị này không giữ khóa danh tính")?;
                pack(&[&credential::identity_to_bytes(id)?])
            }
            "key_packages" => {
                need(1)?;
                let n = u32::from_le_bytes(a[0].as_slice().try_into().map_err(|_| "count phải 4 byte")?) as usize;
                if n > crate::api::MAX_KEY_PACKAGES_PER_CALL {
                    return Err(format!("tối đa {} KeyPackage mỗi lần", crate::api::MAX_KEY_PACKAGES_PER_CALL).into());
                }
                let blobs = (0..n)
                    .map(|_| Ok(MlsMessageOut::from(d.key_package_for_server(false)?).tls_serialize_detached()?))
                    .collect::<Result<Vec<_>>>()?;
                pack(&blobs.iter().map(|b| b.as_slice()).collect::<Vec<_>>())
            }
            "last_resort_key_package" => {
                need(0)?;
                pack(&[&MlsMessageOut::from(d.key_package_for_server(true)?).tls_serialize_detached()?])
            }
            "verify_key_package" => {
                need(4)?;
                verify_key_package(d, &a[0], &a[1], &a[2], &a[3])?;
                pack(&[])
            }
            "rename_group" => {
                need(2)?;
                if self.groups.contains_key(&a[1]) {
                    return Err("khóa nhóm đích đã tồn tại".into());
                }
                let g = self.groups.remove(&a[0]).ok_or(NO_GROUP)?;
                self.groups.insert(a[1].clone(), g);
                pack(&[])
            }
            "drop_group" => {
                need(1)?;
                // Xóa cả trạng thái trong kho khóa để không còn khóa nào của nhóm bị bỏ.
                let mut g = self.groups.remove(&a[0]).ok_or(NO_GROUP)?;
                g.delete(d.provider.storage()).map_err(|e| format!("xóa nhóm: {e:?}"))?;
                pack(&[])
            }
            "group_members" => {
                need(1)?;
                let g = self.groups.get(&a[0]).ok_or(NO_GROUP)?;
                let creds = g
                    .members()
                    .map(|m| Ok(BasicCredential::try_from(m.credential.clone())?.identity().to_vec()))
                    .collect::<Result<Vec<_>>>()?;
                pack(&creds.iter().map(|c| c.as_slice()).collect::<Vec<_>>())
            }
            "app_state_set" => {
                need(1)?;
                self.app_state = a[0].clone();
                pack(&[])
            }
            "app_state_get" => {
                need(0)?;
                pack(&[&self.app_state])
            }
            "snapshot" => {
                need(1)?;
                pack(&[&self.snapshot_sealed(&a[0])?])
            }
            _ => return Err(format!("thao tác không tồn tại: {op}").into()),
        })
    }
}

/// KeyPackage nhận từ server là `MLSMessage`; kiểm chữ ký, cipher suite, phiên bản.
fn parse_key_package(d: &Device, b: &[u8]) -> Result<KeyPackage> {
    let MlsMessageBodyIn::KeyPackage(kp) = MlsMessageIn::tls_deserialize_exact(b)?.extract() else {
        return Err("không phải KeyPackage".into());
    };
    Ok(kp.validate(d.provider.crypto(), ProtocolVersion::Mls10)?)
}

/// Số KeyPackage tối đa mỗi lần gọi `key_packages` (khớp giới hạn upload 200 của spec mục 2).
pub const MAX_KEY_PACKAGES_PER_CALL: usize = 200;

/// Kiểm một KeyPackage nhận từ server (spec 6.2 bước 2, ADR 0007): chữ ký gói, credential được khóa
/// danh tính ký đúng, thuộc đúng tài khoản mong đợi, và khóa ký của lá trùng khóa thiết bị trong credential.
fn verify_key_package(d: &Device, kp: &[u8], cred: &[u8], identity_pub: &[u8], expected_account: &[u8]) -> Result<()> {
    let kp = parse_key_package(d, kp)?;
    let c = Credential::parse(cred)?;
    c.verify(identity_pub)?;
    if c.account_id.as_slice() != expected_account {
        return Err("credential thuộc tài khoản khác".into());
    }
    if credential::leaf_identity(&kp)? != cred {
        return Err("credential trong KeyPackage khác credential server trả".into());
    }
    if kp.leaf_node().signature_key().as_slice() != c.device_public_key.as_slice() {
        return Err("khóa ký của KeyPackage khác khóa thiết bị trong credential".into());
    }
    Ok(())
}
