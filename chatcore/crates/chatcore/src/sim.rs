//! Server giả (DS) và client mô phỏng để kiểm bất biến 1-5 (spec mục 8). Chỉ dùng cho test/bench.
use crate::mls::{Device, Result};
use crate::pb::EntryKind;
use openmls::prelude::*;
use std::collections::HashMap;

#[derive(Clone)]
pub struct Entry {
    pub seq: u64,
    pub kind: EntryKind,
    pub epoch: u64,
    pub sender: Vec<u8>,
    pub ct: Vec<u8>,
}

#[derive(Debug, PartialEq)]
pub enum ServerErr {
    EpochMismatch { current: u64 },
}

/// Một hội thoại ở server: conv_log, epoch hiện tại, GroupInfo, khử trùng theo client_msg_id.
#[derive(Default)]
pub struct FakeServer {
    pub log: Vec<Entry>,
    pub epoch: u64,
    pub group_info: Vec<u8>,
    dedupe: HashMap<Vec<u8>, u64>,
}

impl FakeServer {
    /// `CreateConversation`: Commit đầu ở seq 1, epoch 1.
    pub fn create(commit: Vec<u8>, group_info: Vec<u8>, sender: &[u8]) -> Self {
        let mut s = Self::default();
        s.append(EntryKind::Commit, 0, sender, commit);
        s.epoch = 1;
        s.group_info = group_info;
        s
    }
    fn append(&mut self, kind: EntryKind, epoch: u64, sender: &[u8], ct: Vec<u8>) -> u64 {
        let seq = self.log.len() as u64 + 1;
        self.log.push(Entry { seq, kind, epoch, sender: sender.to_vec(), ct });
        seq
    }
    /// `SubmitCommit`: chỉ một Commit thắng ở mỗi epoch.
    pub fn submit_commit(&mut self, expected: u64, commit: Vec<u8>, group_info: Vec<u8>, sender: &[u8]) -> std::result::Result<(u64, u64), ServerErr> {
        if expected != self.epoch {
            return Err(ServerErr::EpochMismatch { current: self.epoch });
        }
        let seq = self.append(EntryKind::Commit, expected, sender, commit);
        self.epoch += 1;
        self.group_info = group_info;
        Ok((seq, self.epoch))
    }
    /// `SendMessage`: từ chối sai epoch; cùng `client_msg_id` trả lại kết quả cũ (duplicate).
    pub fn send(&mut self, client_msg_id: &[u8], epoch: u64, ct: Vec<u8>, sender: &[u8]) -> std::result::Result<(u64, bool), ServerErr> {
        if let Some(&seq) = self.dedupe.get(client_msg_id) {
            return Ok((seq, true));
        }
        if epoch != self.epoch {
            return Err(ServerErr::EpochMismatch { current: self.epoch });
        }
        let seq = self.append(EntryKind::Application, epoch, sender, ct);
        self.dedupe.insert(client_msg_id.to_vec(), seq);
        Ok((seq, false))
    }
    pub fn fetch_log(&self, after: u64) -> &[Entry] {
        &self.log[after as usize..]
    }
}

/// Client: một thiết bị với trạng thái nhóm và con trỏ `applied` (seq đã áp dụng).
pub struct Client {
    pub dev: Device,
    pub group: Option<MlsGroup>,
    pub applied: u64,
    pub inbox: Vec<Vec<u8>>, // plaintext đã giải mã
}

impl Client {
    pub fn new(identity: &str) -> Self {
        Self { dev: Device::new(identity.as_bytes()).unwrap(), group: None, applied: 0, inbox: vec![] }
    }
    pub fn g(&mut self) -> &mut MlsGroup {
        self.group.as_mut().unwrap()
    }
    pub fn epoch(&self) -> u64 {
        self.group.as_ref().unwrap().epoch().as_u64()
    }
    /// Kéo log và áp dụng đúng thứ tự `seq`. Trả về số mục đã áp dụng. Lỗi giải mã dừng lại ngay.
    pub fn sync(&mut self, srv: &FakeServer) -> Result<usize> {
        let mut n = 0;
        for e in srv.fetch_log(self.applied).to_vec() {
            if e.sender == self.dev.identity && e.kind == EntryKind::Commit {
                // Commit do chính mình dựng đã được merge lúc gửi.
            } else if e.kind == EntryKind::Commit {
                let (dev, g) = (&self.dev, self.group.as_mut().unwrap());
                dev.apply_commit(g, &e.ct)?;
            } else if e.kind == EntryKind::Application && e.sender != self.dev.identity {
                let (dev, g) = (&self.dev, self.group.as_mut().unwrap());
                let pt = dev.decrypt(g, &e.ct)?;
                self.inbox.push(pt);
            }
            self.applied = e.seq;
            n += 1;
        }
        Ok(n)
    }

    pub fn update(&mut self) -> Result<crate::mls::CommitOut> {
        self.dev.update(self.group.as_mut().unwrap())
    }
    pub fn add(&mut self, kps: &[KeyPackage]) -> Result<crate::mls::CommitOut> {
        self.dev.add(self.group.as_mut().unwrap(), kps)
    }
    pub fn remove(&mut self, leaves: &[LeafNodeIndex]) -> Result<crate::mls::CommitOut> {
        self.dev.remove(self.group.as_mut().unwrap(), leaves)
    }
    pub fn encrypt(&mut self, pt: &[u8]) -> Result<Vec<u8>> {
        self.dev.encrypt(self.group.as_mut().unwrap(), pt)
    }
    pub fn decrypt(&mut self, ct: &[u8]) -> Result<Vec<u8>> {
        self.dev.decrypt(self.group.as_mut().unwrap(), ct)
    }
}
