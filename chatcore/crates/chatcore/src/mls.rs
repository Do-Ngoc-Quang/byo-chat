//! Thiết bị MLS: khóa, credential, nhóm, Commit/Welcome/External Commit, exporter.
use openmls::prelude::{tls_codec::*, *};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

/// Cipher suite cố định (CLAUDE.md): MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519.
pub const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

/// Một thiết bị: provider (kho khóa trong bộ nhớ), khóa ký, credential.
pub struct Device {
    pub provider: OpenMlsRustCrypto,
    pub signer: SignatureKeyPair,
    pub credential: CredentialWithKey,
    pub identity: Vec<u8>,
}

/// Kết quả một Commit để gửi qua `SubmitCommit`.
pub struct CommitOut {
    pub commit: Vec<u8>,
    pub welcome: Option<Vec<u8>>,
    pub group_info: Vec<u8>,
}

fn config() -> MlsGroupCreateConfig {
    MlsGroupCreateConfig::builder()
        .ciphersuite(CIPHERSUITE)
        .use_ratchet_tree_extension(true)
        .wire_format_policy(MIXED_CIPHERTEXT_WIRE_FORMAT_POLICY)
        .max_past_epochs(0) // client không giữ khóa epoch cũ
        .padding_size(256) // đệm plaintext lên bội số của 256 byte (giao-thuc.md 7.3)
        .build()
}

fn join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .wire_format_policy(MIXED_CIPHERTEXT_WIRE_FORMAT_POLICY)
        .max_past_epochs(0)
        .padding_size(256)
        .use_ratchet_tree_extension(true)
        .build()
}

impl Device {
    /// `identity` = byte của credential (spec 6.1: account_id, device_id...).
    pub fn new(identity: &[u8]) -> Result<Self> {
        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())?;
        signer.store(provider.storage())?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.to_vec()).into(),
            signature_key: signer.public().into(),
        };
        Ok(Self { provider, signer, credential, identity: identity.to_vec() })
    }

    /// Dựng thiết bị từ khóa ký có sẵn và byte identity (credential 136 byte theo spec 6.1).
    pub fn from_parts(signer: SignatureKeyPair, identity: Vec<u8>) -> Result<Self> {
        let provider = OpenMlsRustCrypto::default();
        signer.store(provider.storage())?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.clone()).into(),
            signature_key: signer.public().into(),
        };
        Ok(Self { provider, signer, credential, identity })
    }

    /// KeyPackage một lần (hạn 30 ngày) hoặc last resort (hạn 90 ngày), spec 6.1 bước 4.
    pub fn key_package_for_server(&self, last_resort: bool) -> Result<KeyPackage> {
        const DAY: u64 = 24 * 3600;
        let b = KeyPackage::builder();
        let b = if last_resort {
            // Gói last resort mang LastResortExtension: lá phải khai báo hỗ trợ extension này, nếu không
            // `add_members` báo UnsupportedExtension.
            let caps = Capabilities::builder().extensions(vec![ExtensionType::LastResort]).build();
            b.key_package_lifetime(Lifetime::new(90 * DAY)).leaf_node_capabilities(caps).mark_as_last_resort()
        } else {
            b.key_package_lifetime(Lifetime::new(30 * DAY))
        };
        Ok(b.build(CIPHERSUITE, &self.provider, &self.signer, self.credential.clone())?.key_package().clone())
    }

    pub fn key_package(&self) -> Result<KeyPackage> {
        Ok(KeyPackage::builder()
            .build(CIPHERSUITE, &self.provider, &self.signer, self.credential.clone())?
            .key_package()
            .clone())
    }

    pub fn create_group(&self) -> Result<MlsGroup> {
        Ok(MlsGroup::new(&self.provider, &self.signer, &config(), self.credential.clone())?)
    }

    /// Thêm các thiết bị bằng một Commit; áp dụng ngay cho chính mình.
    pub fn add(&self, g: &mut MlsGroup, kps: &[KeyPackage]) -> Result<CommitOut> {
        if kps.len() > MAX_DEVICES_PER_COMMIT {
            return Err(format!("quá {MAX_DEVICES_PER_COMMIT} thiết bị mỗi Commit").into());
        }
        if g.members().count() + kps.len() > MAX_DEVICES_PER_GROUP {
            return Err(format!("quá {MAX_DEVICES_PER_GROUP} thiết bị mỗi nhóm").into());
        }
        let out = self.stage_add(g, kps)?;
        g.merge_pending_commit(&self.provider)?;
        Ok(out)
    }

    /// Như `add` nhưng CHƯA áp dụng: chờ `merge_pending_commit` sau khi server nhận, hoặc `clear_pending_commit`
    /// nếu bị từ chối (EPOCH_MISMATCH) để không lệch trạng thái với server.
    pub fn stage_add(&self, g: &mut MlsGroup, kps: &[KeyPackage]) -> Result<CommitOut> {
        g.clear_pending_commit(self.provider.storage())?;
        let (commit, welcome, gi) = g.add_members(&self.provider, &self.signer, kps)?;
        Ok(CommitOut {
            commit: commit.tls_serialize_detached()?,
            welcome: Some(welcome.tls_serialize_detached()?),
            group_info: MlsMessageOut::from(gi.ok_or("no group info")?).tls_serialize_detached()?,
        })
    }

    pub fn group_info(&self, g: &MlsGroup) -> Result<Vec<u8>> {
        Ok(g.export_group_info(self.provider.crypto(), &self.signer, true)?.tls_serialize_detached()?)
    }

    pub fn join_welcome(&self, welcome: &[u8]) -> Result<MlsGroup> {
        let msg = MlsMessageIn::tls_deserialize_exact(welcome)?;
        let MlsMessageBodyIn::Welcome(w) = msg.extract() else { return Err("not a welcome".into()) };
        let staged = StagedWelcome::new_from_welcome(&self.provider, &join_config(), w, None)?;
        Ok(staged.into_group(&self.provider)?)
    }

    /// Áp dụng một Commit nhận về (theo `seq`).
    pub fn apply_commit(&self, g: &mut MlsGroup, bytes: &[u8]) -> Result<()> {
        let msg = MlsMessageIn::tls_deserialize_exact(bytes)?;
        let processed = g.process_message(&self.provider, msg.try_into_protocol_message()?)?;
        match processed.into_content() {
            ProcessedMessageContent::StagedCommitMessage(sc) => Ok(g.merge_staged_commit(&self.provider, *sc)?),
            _ => Err("not a commit".into()),
        }
    }

    /// External Commit để tự vào nhóm (spec 6.5, 6.7). `resync_old_leaf`: bỏ qua, xem các test.
    pub fn external_join(&self, group_info: &[u8]) -> Result<(MlsGroup, Vec<u8>)> {
        let MlsMessageBodyIn::GroupInfo(gi) = MlsMessageIn::tls_deserialize_exact(group_info)?.extract() else {
            return Err("not group info".into());
        };
        let (group, bundle) = MlsGroup::external_commit_builder()
            .with_config(join_config())
            .build_group(&self.provider, gi, self.credential.clone())?
            .load_psks(self.provider.storage())?
            .build(self.provider.rand(), self.provider.crypto(), &self.signer, |_| true)?
            .finalize(&self.provider)?;
        Ok((group, bundle.commit().tls_serialize_detached()?))
    }

    pub fn encrypt(&self, g: &mut MlsGroup, pt: &[u8]) -> Result<Vec<u8>> {
        Ok(g.create_message(&self.provider, &self.signer, pt)?.tls_serialize_detached()?)
    }

    pub fn decrypt(&self, g: &mut MlsGroup, ct: &[u8]) -> Result<Vec<u8>> {
        let msg = MlsMessageIn::tls_deserialize_exact(ct)?;
        match g.process_message(&self.provider, msg.try_into_protocol_message()?)?.into_content() {
            ProcessedMessageContent::ApplicationMessage(m) => Ok(m.into_bytes()),
            _ => Err("not application".into()),
        }
    }

    /// Khóa SFrame (CLAUDE.md): Exporter("call", call_id, 32).
    pub fn sframe_key(&self, g: &MlsGroup, call_id: &[u8]) -> Result<Vec<u8>> {
        Ok(g.export_secret(self.provider.crypto(), "call", call_id, 32)?)
    }

    /// Gỡ các lá theo chỉ số; Commit áp dụng ngay cho chính mình.
    pub fn remove(&self, g: &mut MlsGroup, leaves: &[LeafNodeIndex]) -> Result<CommitOut> {
        let out = self.stage_remove(g, leaves)?;
        g.merge_pending_commit(&self.provider)?;
        Ok(out)
    }

    /// Như `remove` nhưng chưa áp dụng (xem `stage_add`).
    pub fn stage_remove(&self, g: &mut MlsGroup, leaves: &[LeafNodeIndex]) -> Result<CommitOut> {
        g.clear_pending_commit(self.provider.storage())?;
        let (commit, welcome, gi) = g.remove_members(&self.provider, &self.signer, leaves)?;
        Ok(CommitOut {
            commit: commit.tls_serialize_detached()?,
            welcome: welcome.map(|w| w.tls_serialize_detached()).transpose()?,
            group_info: MlsMessageOut::from(gi.ok_or("no group info")?).tls_serialize_detached()?,
        })
    }

    /// Commit chỉ có path update (xoay khóa định kỳ, spec 6.8).
    pub fn update(&self, g: &mut MlsGroup) -> Result<CommitOut> {
        let b = g.self_update(&self.provider, &self.signer, LeafNodeParameters::default())?;
        g.merge_pending_commit(&self.provider)?;
        let (commit, welcome, gi) = b.into_contents();
        Ok(CommitOut {
            commit: commit.tls_serialize_detached()?,
            welcome: welcome.map(|w| w.tls_serialize_detached()).transpose()?,
            group_info: MlsMessageOut::from(gi.ok_or("no group info")?).tls_serialize_detached()?,
        })
    }

    /// Chỉ số lá của mọi thành viên có `identity` này (có thể nhiều hơn một sau khôi phục).
    pub fn leaves_of(g: &MlsGroup, identity: &[u8]) -> Vec<LeafNodeIndex> {
        g.members()
            .filter(|m| BasicCredential::try_from(m.credential.clone()).map(|c| c.identity() == identity).unwrap_or(false))
            .map(|m| m.index)
            .collect()
    }
}

/// Giới hạn bất biến (CLAUDE.md): tối đa 50 thiết bị mỗi Commit, 256 thiết bị mỗi nhóm (ADR 0011).
pub const MAX_DEVICES_PER_COMMIT: usize = 50;
pub const MAX_DEVICES_PER_GROUP: usize = 256;
