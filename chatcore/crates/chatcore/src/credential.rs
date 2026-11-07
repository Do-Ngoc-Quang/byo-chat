//! Credential của thiết bị (spec giao-thuc.md 6.1, làm rõ ở 1.1.1). Bố cục cố định 136 byte:
//! account_id(16) | device_id(16) | device_public_key(32) | created_ms(8, BE) | signature(64).
//! `signature` = Ed25519 của khóa danh tính tài khoản lên "chat.v1.credential" ‖ 72 byte đầu.
//! Cùng bố cục với `server/internal/account/credential.go`; vector chung ở `tests/credential.rs`.
use crate::mls::{Result, CIPHERSUITE};
use openmls::prelude::{tls_codec::*, *};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::signatures::Signer;

pub const CREDENTIAL_LEN: usize = 136;
const DOMAIN: &[u8] = b"chat.v1.credential";

/// Credential đã tách trường (chưa chắc hợp lệ: gọi `verify`).
pub struct Credential {
    pub account_id: [u8; 16],
    pub device_id: [u8; 16],
    pub device_public_key: [u8; 32],
    pub created_ms: u64,
    signature: [u8; 64],
    signed: [u8; 72],
}

impl Credential {
    pub fn parse(b: &[u8]) -> Result<Self> {
        if b.len() != CREDENTIAL_LEN {
            return Err(format!("credential phải {CREDENTIAL_LEN} byte, nhận {}", b.len()).into());
        }
        Ok(Self {
            account_id: b[0..16].try_into()?,
            device_id: b[16..32].try_into()?,
            device_public_key: b[32..64].try_into()?,
            created_ms: u64::from_be_bytes(b[64..72].try_into()?),
            signature: b[72..136].try_into()?,
            signed: b[0..72].try_into()?,
        })
    }

    /// Kiểm chữ ký bằng khóa danh tính công khai của tài khoản (Ed25519, 32 byte).
    pub fn verify(&self, identity_public_key: &[u8]) -> Result<()> {
        let mut msg = DOMAIN.to_vec();
        msg.extend_from_slice(&self.signed);
        use openmls_traits::{crypto::OpenMlsCrypto, OpenMlsProvider};
        OpenMlsRustCrypto::default()
            .crypto()
            .verify_signature(CIPHERSUITE.signature_algorithm(), &msg, identity_public_key, &self.signature)
            .map_err(|e| format!("chữ ký credential sai: {e:?}").into())
    }
}

/// Dựng và ký credential bằng khóa danh tính tài khoản.
pub fn build(identity: &SignatureKeyPair, account_id: &[u8; 16], device_id: &[u8; 16], device_public_key: &[u8], created_ms: u64) -> Result<Vec<u8>> {
    if device_public_key.len() != 32 {
        return Err("khóa thiết bị phải 32 byte".into());
    }
    let mut out = Vec::with_capacity(CREDENTIAL_LEN);
    out.extend_from_slice(account_id);
    out.extend_from_slice(device_id);
    out.extend_from_slice(device_public_key);
    out.extend_from_slice(&created_ms.to_be_bytes());
    let mut msg = DOMAIN.to_vec();
    msg.extend_from_slice(&out);
    out.extend_from_slice(identity.sign(&msg).map_err(|e| format!("ký credential: {e:?}"))?.as_slice());
    Ok(out)
}

/// Khóa danh tính tài khoản dạng byte (TLS-serialize của `SignatureKeyPair`, gồm cả khóa bí mật)
/// để lưu bền/chuyển cho thiết bị mới (giai đoạn 4). Nhạy cảm: chỉ cất trong keystore.
pub fn identity_to_bytes(k: &SignatureKeyPair) -> Result<Vec<u8>> {
    Ok(k.tls_serialize_detached()?)
}

pub fn identity_from_bytes(b: &[u8]) -> Result<SignatureKeyPair> {
    let k = SignatureKeyPair::tls_deserialize_exact(b)?;
    if k.signature_scheme() != CIPHERSUITE.signature_algorithm() {
        return Err("khóa danh tính sai thuật toán".into());
    }
    // Chặn khóa hỏng/ghép sai: ký thử rồi kiểm bằng khóa công khai đi kèm.
    let sig = k.sign(b"chat.v1.selftest").map_err(|e| format!("khóa danh tính hỏng: {e:?}"))?;
    use openmls_traits::{crypto::OpenMlsCrypto, OpenMlsProvider};
    OpenMlsRustCrypto::default()
        .crypto()
        .verify_signature(CIPHERSUITE.signature_algorithm(), b"chat.v1.selftest", k.public(), sig.as_slice())
        .map_err(|_| "khóa danh tính: private và public không khớp")?;
    Ok(k)
}

/// Bản xác nhận thu hồi thiết bị (spec 6.6): device_id(16) | revoked_ms(8, BE) | chữ ký(64) của khóa danh tính lên
/// "chat.v1.revocation" ‖ 24 byte đầu. Cùng bố cục với `server/internal/account/revocation.go`.
pub fn revocation_sign(identity: &SignatureKeyPair, device_id: &[u8; 16], revoked_ms: u64) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(88);
    out.extend_from_slice(device_id);
    out.extend_from_slice(&revoked_ms.to_be_bytes());
    let mut msg = b"chat.v1.revocation".to_vec();
    msg.extend_from_slice(&out);
    out.extend_from_slice(identity.sign(&msg).map_err(|e| format!("ký revocation: {e:?}"))?.as_slice());
    Ok(out)
}

/// Nội dung identity của BasicCredential trong KeyPackage (để kiểm khớp credential).
pub fn leaf_identity(kp: &KeyPackage) -> Result<Vec<u8>> {
    Ok(BasicCredential::try_from(kp.leaf_node().credential().clone())?.identity().to_vec())
}
