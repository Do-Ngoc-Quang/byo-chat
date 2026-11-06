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
        .build()
}

fn join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .wire_format_policy(MIXED_CIPHERTEXT_WIRE_FORMAT_POLICY)
        .max_past_epochs(0)
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
        let (commit, welcome, gi) = g.add_members(&self.provider, &self.signer, kps)?;
        g.merge_pending_commit(&self.provider)?;
        Ok(CommitOut {
            commit: commit.tls_serialize_detached()?,
            welcome: Some(welcome.tls_serialize_detached()?),
            group_info: gi.ok_or("no group info")?.tls_serialize_detached()?,
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
}
