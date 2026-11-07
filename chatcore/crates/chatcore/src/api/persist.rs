//! Lưu bền trạng thái của `Core` (ADR 0008): snapshot gồm kho khóa OpenMLS (khóa ký, khóa riêng của
//! KeyPackage, mọi nhóm), khóa danh tính tài khoản và ánh xạ conv -> group_id; mã hóa AEAD bằng khóa
//! 32 byte do ứng dụng giữ trong keystore. Core không tự ghi file: app gọi `snapshot_sealed` sau mỗi
//! thay đổi trạng thái rồi ghi ra nơi nó chọn.
use super::{credential, unpack, pack, Core};
use crate::mls::{Device, Result, CIPHERSUITE};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::{crypto::OpenMlsCrypto, random::OpenMlsRand, types::AeadType, OpenMlsProvider};
use std::collections::HashMap;

const VERSION: u8 = 2; // 2: thêm app_state (ADR 0009)
const AAD: &[u8] = b"chat.v1.snapshot\x02";
const NONCE_LEN: usize = 12;
const AEAD: AeadType = AeadType::Aes256Gcm;

fn check_key(key: &[u8]) -> Result<()> {
    if key.len() != 32 {
        return Err("khóa lưu trữ phải 32 byte".into());
    }
    Ok(())
}

impl Core {
    /// Snapshot đã mã hóa: `version(1) ‖ nonce(12) ‖ AES-256-GCM(plaintext)`. Nhạy cảm sau khi giải mã.
    pub fn snapshot_sealed(&self, key: &[u8]) -> Result<Vec<u8>> {
        check_key(key)?;
        let plain = self.snapshot_plain()?;
        let crypto = OpenMlsRustCrypto::default();
        let nonce = crypto.rand().random_vec(NONCE_LEN).map_err(|e| format!("nonce: {e:?}"))?;
        let ct = crypto.crypto().aead_encrypt(AEAD, key, &plain, &nonce, AAD).map_err(|e| format!("mã hóa snapshot: {e:?}"))?;
        let mut out = vec![VERSION];
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&ct);
        Ok(out)
    }

    /// Khôi phục từ `snapshot_sealed`. Sai khóa hoặc dữ liệu bị sửa đều báo lỗi (không trả trạng thái nửa vời).
    pub fn restore_sealed(sealed: &[u8], key: &[u8]) -> Result<Self> {
        check_key(key)?;
        if sealed.len() < 1 + NONCE_LEN + 16 || sealed[0] != VERSION {
            return Err("snapshot sai định dạng hoặc phiên bản".into());
        }
        let plain = OpenMlsRustCrypto::default()
            .crypto()
            .aead_decrypt(AEAD, key, &sealed[1 + NONCE_LEN..], &sealed[1..1 + NONCE_LEN], AAD)
            .map_err(|_| "giải mã snapshot thất bại (sai khóa hoặc dữ liệu bị sửa)")?;
        Self::restore_plain(&plain)
    }

    /// Như `restore_sealed` nhưng nhận đối số đóng gói qua cầu nối: [sealed, key].
    pub fn open_restore(args: &[u8]) -> Result<Self> {
        let a = unpack(args)?;
        if a.len() != 2 {
            return Err(format!("open_restore: cần 2 đối số, nhận {}", a.len()).into());
        }
        Self::restore_sealed(&a[0], &a[1])
    }

    fn snapshot_plain(&self) -> Result<Vec<u8>> {
        let d = &self.device;
        let acct = match &self.identity {
            Some(k) => credential::identity_to_bytes(k)?,
            None => vec![],
        };
        let mut head: Vec<Vec<u8>> = vec![vec![VERSION], d.identity.clone(), d.signer.public().to_vec(), acct, self.app_state.clone()];
        // nhóm: conv -> group_id
        head.push((self.groups.len() as u32).to_le_bytes().to_vec());
        for (conv, g) in &self.groups {
            head.push(conv.clone());
            head.push(g.group_id().as_slice().to_vec());
        }
        // kho khóa
        let values = d.provider.storage().values.read().map_err(|_| "kho khóa bị khóa lỗi")?;
        for (k, v) in values.iter() {
            head.push(k.clone());
            head.push(v.clone());
        }
        Ok(pack(&head.iter().map(|b| b.as_slice()).collect::<Vec<_>>()))
    }

    fn restore_plain(plain: &[u8]) -> Result<Self> {
        let items = unpack(plain)?;
        if items.len() < 6 || items[0] != [VERSION] {
            return Err("snapshot hỏng".into());
        }
        let (identity, signer_pub, acct, app_state) = (&items[1], &items[2], &items[3], &items[4]);
        let n_groups = u32::from_le_bytes(items[5].as_slice().try_into().map_err(|_| "snapshot hỏng")?) as usize;
        let group_end = 6 + 2 * n_groups;
        if items.len() < group_end || (items.len() - group_end) % 2 != 0 {
            return Err("snapshot hỏng".into());
        }

        let provider = OpenMlsRustCrypto::default();
        {
            let mut values = provider.storage().values.write().map_err(|_| "kho khóa bị khóa lỗi")?;
            for kv in items[group_end..].chunks(2) {
                values.insert(kv[0].clone(), kv[1].clone());
            }
        }
        let signer = SignatureKeyPair::read(provider.storage(), signer_pub, CIPHERSUITE.signature_algorithm())
            .ok_or("snapshot thiếu khóa ký của thiết bị")?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.clone()).into(),
            signature_key: signer.public().into(),
        };
        let mut groups = HashMap::new();
        for pair in items[6..group_end].chunks(2) {
            let g = MlsGroup::load(provider.storage(), &GroupId::from_slice(&pair[1]))
                .map_err(|e| format!("nạp nhóm: {e:?}"))?
                .ok_or("snapshot thiếu trạng thái nhóm")?;
            groups.insert(pair[0].clone(), g);
        }
        let identity_key = if acct.is_empty() { None } else { Some(credential::identity_from_bytes(acct)?) };
        Ok(Core {
            device: Device { provider, signer, credential, identity: identity.clone() },
            groups,
            identity: identity_key,
            app_state: app_state.clone(),
            pending: None,
            proposals: Default::default(),
        })
    }
}
