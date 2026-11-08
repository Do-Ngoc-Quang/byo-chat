//! Sao lưu và khôi phục tài khoản (giao-thuc.md 6.14, ADR 0012). Bản sao lưu = khóa danh tính tài khoản + lịch sử
//! (`app_state`), KHÔNG gồm trạng thái MLS (khóa epoch cũ không được giữ; thiết bị khôi phục tự vào nhóm bằng
//! External Commit). Mã hóa AES-256-GCM với khóa dẫn xuất HKDF-SHA256 từ recovery key 256 bit; server không giải mã được.
use super::{credential, pack, unpack, Core};
use crate::mls::Result;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::{
    crypto::OpenMlsCrypto,
    random::OpenMlsRand,
    types::{AeadType, HashType},
    OpenMlsProvider,
};

const VERSION: u8 = 1;
const AAD: &[u8] = b"chat.v1.backup\x01";
const SALT: &[u8] = b"chat.v1.backup.salt";
const INFO: &[u8] = b"chat.v1.backup.key";
const NONCE_LEN: usize = 12;

fn derive(recovery_key: &[u8]) -> Result<Vec<u8>> {
    if recovery_key.len() != 32 {
        return Err("recovery key phải 32 byte".into());
    }
    let c = OpenMlsRustCrypto::default();
    let prk = c.crypto().hkdf_extract(HashType::Sha2_256, SALT, recovery_key).map_err(|e| format!("hkdf: {e:?}"))?;
    Ok(c.crypto().hkdf_expand(HashType::Sha2_256, prk.as_slice(), INFO, 32).map_err(|e| format!("hkdf: {e:?}"))?.as_slice().to_vec())
}

impl Core {
    /// Recovery key mới, 32 byte ngẫu nhiên.
    pub(super) fn backup_key_new() -> Result<Vec<u8>> {
        OpenMlsRustCrypto::default().rand().random_vec(32).map_err(|e| format!("rand: {e:?}").into())
    }

    /// `version(1) ‖ nonce(12) ‖ AES-256-GCM(pack([khóa danh tính, app_state]))`.
    pub(super) fn backup_seal(&self, recovery_key: &[u8]) -> Result<Vec<u8>> {
        let key = derive(recovery_key)?;
        let id = self.identity.as_ref().ok_or("thiết bị này không giữ khóa danh tính, không sao lưu được")?;
        let plain = pack(&[&credential::identity_to_bytes(id)?, &self.app_state]);
        let c = OpenMlsRustCrypto::default();
        let nonce = c.rand().random_vec(NONCE_LEN).map_err(|e| format!("rand: {e:?}"))?;
        let ct = c.crypto().aead_encrypt(AeadType::Aes256Gcm, &key, &plain, &nonce, AAD).map_err(|e| format!("mã hóa: {e:?}"))?;
        let mut out = vec![VERSION];
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&ct);
        Ok(out)
    }

    /// Mở bản sao lưu: [khóa danh tính, app_state]. Sai recovery key hoặc dữ liệu bị sửa đều lỗi.
    pub(super) fn backup_open(recovery_key: &[u8], blob: &[u8]) -> Result<Vec<u8>> {
        let key = derive(recovery_key)?;
        if blob.len() < 1 + NONCE_LEN + 16 || blob[0] != VERSION {
            return Err("bản sao lưu sai định dạng hoặc phiên bản".into());
        }
        let plain = OpenMlsRustCrypto::default()
            .crypto()
            .aead_decrypt(AeadType::Aes256Gcm, &key, &blob[1 + NONCE_LEN..], &blob[1..1 + NONCE_LEN], AAD)
            .map_err(|_| "giải mã bản sao lưu thất bại (sai recovery key hoặc dữ liệu bị sửa)")?;
        let parts = unpack(&plain)?;
        if parts.len() != 2 {
            return Err("bản sao lưu sai bố cục".into());
        }
        credential::identity_from_bytes(&parts[0])?; // khóa danh tính phải hợp lệ trước khi giao ra
        Ok(pack(&[&parts[0], &parts[1]]))
    }
}
