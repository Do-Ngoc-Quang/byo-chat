//! Liên kết thiết bị mới vào tài khoản đã có (giao-thuc.md 6.5, ADR 0010).
//! `sealed_bundle` = HPKE (X25519, HKDF-SHA256, AES-128-GCM, cùng bộ với cipher suite MLS) seal khóa danh tính
//! tới khóa công khai tạm của thiết bị mới; `info` = "chat.v1.link", `aad` = link_id. Không tự viết primitive.
use super::{pack, unpack, Core, Pending};
use crate::credential::{self, Credential};
use crate::mls::{Device, Result, CIPHERSUITE};
use openmls::prelude::tls_codec::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_traits::{
    crypto::OpenMlsCrypto,
    random::OpenMlsRand,
    types::{HpkeCiphertext, HpkeConfig},
    OpenMlsProvider,
};

const INFO: &[u8] = b"chat.v1.link";

fn hpke() -> HpkeConfig {
    HpkeConfig(CIPHERSUITE.into(), CIPHERSUITE.into(), CIPHERSUITE.into())
}

impl Core {
    /// Thiết bị mới chưa có tài khoản: có khóa ký riêng và chờ `link_finish`.
    pub(super) fn new_pending(device_id: &[u8]) -> Result<Self> {
        let device_id: [u8; 16] = device_id.try_into().map_err(|_| "device_id phải 16 byte")?;
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())?;
        let device = Device::from_parts(signer, Vec::new())?;
        let ikm = device.provider.rand().random_vec(32).map_err(|e| format!("rand: {e:?}"))?;
        let kp = device.provider.crypto().derive_hpke_keypair(hpke(), &ikm).map_err(|e| format!("hpke: {e:?}"))?;
        let pending = Pending { device_id, hpke_private: kp.private.to_vec(), hpke_public: kp.public };
        let mut c = Self::from_device(device, None);
        c.pending = Some(pending);
        Ok(c)
    }

    /// `link_start` [] -> [device_public_key, ephemeral_public_key] (cho `StartLink`).
    pub(super) fn link_start(&self) -> Result<Vec<u8>> {
        let p = self.pending.as_ref().ok_or("thiết bị này không ở trạng thái chờ liên kết")?;
        Ok(pack(&[self.device.signer.public(), &p.hpke_public]))
    }

    /// Thiết bị cũ (giữ khóa danh tính): `link_approve` [link_id, new_device_id, new_device_pub, ephemeral_pub,
    /// created_ms u64 LE] -> [credential, sealed_bundle] (cho `ApproveLink`).
    pub(super) fn link_approve(&self, a: &[Vec<u8>]) -> Result<Vec<u8>> {
        if a.len() != 5 {
            return Err("link_approve: cần 5 đối số".into());
        }
        let id = self.identity.as_ref().ok_or("thiết bị này không giữ khóa danh tính")?;
        let own = Credential::parse(&self.device.identity)?;
        let new_dev: [u8; 16] = a[1].as_slice().try_into().map_err(|_| "new_device_id phải 16 byte")?;
        let created = u64::from_le_bytes(a[4].as_slice().try_into().map_err(|_| "created_ms phải 8 byte")?);
        let cred = credential::build(id, &own.account_id, &new_dev, &a[2], created)?;
        let ct = self
            .device
            .provider
            .crypto()
            .hpke_seal(hpke(), &a[3], INFO, &a[0], &credential::identity_to_bytes(id)?)
            .map_err(|e| format!("seal: {e:?}"))?;
        Ok(pack(&[&cred, &pack(&[ct.kem_output.as_slice(), ct.ciphertext.as_slice()])]))
    }

    /// Thiết bị mới: `link_finish` [link_id, credential, sealed_bundle] -> []. Mở gói, kiểm credential bằng khóa
    /// danh tính vừa nhận và khớp khóa/ID của chính mình, rồi trở thành thiết bị đầy đủ (giữ khóa danh tính).
    pub(super) fn link_finish(&mut self, a: &[Vec<u8>]) -> Result<()> {
        if a.len() != 3 {
            return Err("link_finish: cần 3 đối số".into());
        }
        let p = self.pending.as_ref().ok_or("thiết bị này không ở trạng thái chờ liên kết")?;
        let parts = unpack(&a[2])?;
        if parts.len() != 2 {
            return Err("sealed_bundle sai bố cục".into());
        }
        let ct = HpkeCiphertext { kem_output: parts[0].clone().into(), ciphertext: parts[1].clone().into() };
        let raw = self
            .device
            .provider
            .crypto()
            .hpke_open(hpke(), &ct, &p.hpke_private, INFO, &a[0])
            .map_err(|e| format!("mở sealed_bundle: {e:?}"))?;
        let identity = credential::identity_from_bytes(&raw)?;
        let cred = Credential::parse(&a[1])?;
        cred.verify(identity.public())?;
        if cred.device_id != p.device_id || cred.device_public_key.as_slice() != self.device.signer.public() {
            return Err("credential không dành cho thiết bị này".into());
        }
        let signer = SignatureKeyPair::tls_deserialize_exact(&self.device.signer.tls_serialize_detached()?)?;
        *self = Self::from_device(Device::from_parts(signer, a[1].clone())?, Some(identity));
        Ok(())
    }
}
