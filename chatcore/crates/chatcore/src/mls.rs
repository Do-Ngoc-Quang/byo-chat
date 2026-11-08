//! Thiết bị MLS: khóa, credential, nhóm, Commit/Welcome/External Commit, exporter.
use openmls::prelude::{tls_codec::*, *};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

/// Cipher suite cố định (CLAUDE.md): MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519.
pub const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// Tiền tố lỗi của `apply_commit_checked`: client lấy statement thu hồi rồi thử lại (spec 6.6 bước 4).
pub const NEED_REVOCATION: &str = "NEED_REVOCATION:";

/// Loại group context extension `chat_policy` (spec 6.2, ADR 0013): `version(1)=1 ‖ tên nhóm UTF-8`.
pub const CHAT_POLICY_EXT: u16 = 0xF001;
pub const MAX_GROUP_NAME: usize = 100;

fn caps(extra: &[ExtensionType]) -> Capabilities {
    let mut e = vec![ExtensionType::Unknown(CHAT_POLICY_EXT)];
    e.extend_from_slice(extra);
    Capabilities::builder().extensions(e).build()
}

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
            b.key_package_lifetime(Lifetime::new(90 * DAY)).leaf_node_capabilities(caps(&[ExtensionType::LastResort])).mark_as_last_resort()
        } else {
            b.key_package_lifetime(Lifetime::new(30 * DAY)).leaf_node_capabilities(caps(&[]))
        };
        Ok(b.build(CIPHERSUITE, &self.provider, &self.signer, self.credential.clone())?.key_package().clone())
    }

    pub fn key_package(&self) -> Result<KeyPackage> {
        Ok(KeyPackage::builder()
            .leaf_node_capabilities(caps(&[]))
            .build(CIPHERSUITE, &self.provider, &self.signer, self.credential.clone())?
            .key_package()
            .clone())
    }

    pub fn create_group(&self) -> Result<MlsGroup> {
        Ok(MlsGroup::new(&self.provider, &self.signer, &config(), self.credential.clone())?)
    }

    /// Nhóm có tên trong extension `chat_policy` (ADR 0013).
    pub fn create_group_named(&self, name: &str) -> Result<MlsGroup> {
        if name.len() > MAX_GROUP_NAME {
            return Err(format!("tên nhóm tối đa {MAX_GROUP_NAME} byte").into());
        }
        let mut v = vec![1u8];
        v.extend_from_slice(name.as_bytes());
        let ext = Extensions::single(Extension::Unknown(CHAT_POLICY_EXT, UnknownExtension(v)))?;
        let cfg = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .use_ratchet_tree_extension(true)
            .wire_format_policy(MIXED_CIPHERTEXT_WIRE_FORMAT_POLICY)
            .max_past_epochs(0)
            .padding_size(256)
            .capabilities(caps(&[]))
            .with_group_context_extensions(ext)
            .build();
        Ok(MlsGroup::new(&self.provider, &self.signer, &cfg, self.credential.clone())?)
    }

    /// Tên nhóm từ `chat_policy`; None nếu nhóm không có (nhóm 1-1 hoặc cũ) hoặc version lạ.
    pub fn group_name(g: &MlsGroup) -> Option<String> {
        g.extensions().iter().find_map(|e| match e {
            Extension::Unknown(CHAT_POLICY_EXT, UnknownExtension(v)) if v.first() == Some(&1) => String::from_utf8(v[1..].to_vec()).ok(),
            _ => None,
        })
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

    /// Như `apply_commit` nhưng theo spec 6.6 bước 4: Commit gỡ MỘT PHẦN thiết bị của một tài khoản (tài khoản đó vẫn còn
    /// lá khác) chỉ được tin khi thiết bị bị gỡ có statement thu hồi hợp lệ trong `revoked` (device_id). Người tự xin rời
    /// (Remove do chính lá đó đề xuất) và gỡ cả tài khoản không cần statement. Thiếu statement thì trả lỗi
    /// `NEED_REVOCATION:<hex device_id>,...` và KHÔNG áp dụng Commit (trạng thái nhóm không đổi).
    /// `held`: Commit đã giải mã nhưng đang chờ statement (không giải mã lại được: khóa của tin đã dùng).
    pub fn apply_commit_checked(
        &self,
        g: &mut MlsGroup,
        bytes: &[u8],
        revoked: &std::collections::HashSet<[u8; 16]>,
        held: &mut Option<(Vec<u8>, Box<StagedCommit>)>,
    ) -> Result<()> {
        let sc = match held.take() {
            Some((b, sc)) if b == bytes => sc,
            _ => {
                let msg = MlsMessageIn::tls_deserialize_exact(bytes)?;
                let processed = g.process_message(&self.provider, msg.try_into_protocol_message()?)?;
                let ProcessedMessageContent::StagedCommitMessage(sc) = processed.into_content() else { return Err("not a commit".into()) };
                sc
            }
        };
        let acct_dev = |idx: LeafNodeIndex| {
            let m = g.members().find(|m| m.index == idx)?;
            let c = BasicCredential::try_from(m.credential).ok()?;
            let id = c.identity();
            (id.len() >= 32).then(|| (id[..16].to_vec(), <[u8; 16]>::try_from(&id[16..32]).unwrap()))
        };
        let removed: Vec<(LeafNodeIndex, bool)> = sc
            .remove_proposals()
            .map(|q| (q.remove_proposal().removed(), matches!(q.sender(), Sender::Member(s) if *s == q.remove_proposal().removed())))
            .collect();
        let gone: Vec<LeafNodeIndex> = removed.iter().map(|r| r.0).collect();
        let mut missing = Vec::new();
        let out_anyway = gone.contains(&g.own_leaf_index()); // chính mình bị gỡ: không còn gì để bảo vệ
        for (idx, self_leave) in removed.iter().filter(|_| !out_anyway) {
            let Some((acct, dev)) = acct_dev(*idx) else { continue };
            let stays = g.members().any(|m| !gone.contains(&m.index) && acct_dev(m.index).is_some_and(|(a, _)| a == acct));
            if stays && !self_leave && !revoked.contains(&dev) {
                missing.push(dev.iter().map(|b| format!("{b:02x}")).collect::<String>());
            }
        }
        if !missing.is_empty() {
            *held = Some((bytes.to_vec(), sc));
            return Err(format!("{NEED_REVOCATION}{}", missing.join(",")).into());
        }
        Ok(g.merge_staged_commit(&self.provider, *sc)?)
    }

    /// External Commit để tự vào nhóm (spec 6.5, 6.7). `resync_old_leaf`: bỏ qua, xem các test.
    pub fn external_join(&self, group_info: &[u8]) -> Result<(MlsGroup, Vec<u8>)> {
        let MlsMessageBodyIn::GroupInfo(gi) = MlsMessageIn::tls_deserialize_exact(group_info)?.extract() else {
            return Err("not group info".into());
        };
        let (group, bundle) = MlsGroup::external_commit_builder()
            .with_config(join_config())
            .build_group(&self.provider, gi, self.credential.clone())?
            .leaf_node_parameters(
                LeafNodeParameters::builder().with_credential_with_key(self.credential.clone()).with_capabilities(caps(&[])).build(),
            )
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

    /// Rời nhóm (spec 6.4): Remove proposal cho chính mình, gửi qua `SubmitProposal`. MLS không cho tự gỡ nên cần
    /// một thành viên khác commit; nhóm giữ nguyên (còn nhận Commit) cho tới khi bị gỡ.
    pub fn leave_proposal(&self, g: &mut MlsGroup) -> Result<Vec<u8>> {
        Ok(g.leave_group(&self.provider, &self.signer)?.tls_serialize_detached()?)
    }

    /// Nhận một Proposal từ log (theo `seq`): xếp vào hàng chờ để `stage_commit_pending` gom vào Commit.
    pub fn apply_proposal(&self, g: &mut MlsGroup, bytes: &[u8]) -> Result<()> {
        let msg = MlsMessageIn::tls_deserialize_exact(bytes)?;
        let processed = g.process_message(&self.provider, msg.try_into_protocol_message()?)?;
        match processed.into_content() {
            ProcessedMessageContent::ProposalMessage(p) => {
                // Chỉ nhận Remove tự gỡ (ADR 0015): proposal khác, hoặc gỡ người khác, sẽ bị admin commit nhầm theo hàng chờ.
                let self_remove = matches!(p.proposal(), Proposal::Remove(r) if matches!(p.sender(), Sender::Member(s) if *s == r.removed()));
                if !self_remove {
                    return Err("proposal không phải tự gỡ".into());
                }
                Ok(g.store_pending_proposal(self.provider.storage(), *p)?)
            }
            _ => Err("không phải proposal".into()),
        }
    }

    /// Commit gom mọi proposal đang chờ (vd. gỡ người xin rời), CHƯA áp dụng (như `stage_add`).
    pub fn stage_commit_pending(&self, g: &mut MlsGroup) -> Result<CommitOut> {
        g.clear_pending_commit(self.provider.storage())?;
        if g.pending_proposals().next().is_none() {
            return Err("không có proposal nào đang chờ".into());
        }
        let (commit, welcome, gi) = g.commit_to_pending_proposals(&self.provider, &self.signer)?;
        Ok(CommitOut {
            commit: commit.tls_serialize_detached()?,
            welcome: welcome.map(|w| w.tls_serialize_detached()).transpose()?,
            group_info: MlsMessageOut::from(gi.ok_or("no group info")?).tls_serialize_detached()?,
        })
    }

    /// Commit chỉ có path update (xoay khóa định kỳ, spec 6.8).
    pub fn update(&self, g: &mut MlsGroup) -> Result<CommitOut> {
        let out = self.stage_update(g)?;
        g.merge_pending_commit(&self.provider)?;
        Ok(out)
    }

    /// Như `update` nhưng chưa áp dụng (xem `stage_add`); dùng cho Commit đổi vai trò chỉ có path update.
    pub fn stage_update(&self, g: &mut MlsGroup) -> Result<CommitOut> {
        g.clear_pending_commit(self.provider.storage())?;
        let b = g.self_update(&self.provider, &self.signer, LeafNodeParameters::default())?;
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
