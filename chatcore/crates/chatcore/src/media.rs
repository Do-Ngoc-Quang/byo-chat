//! Mã hóa media theo khối (spec thiet-ke-chinh.md mục 11): AES-256-GCM, mỗi khối một nonce, khối cuối được đánh dấu.
//!
//! Cấu trúc kiểu STREAM: nonce 12 byte = `nonce_prefix` (7 byte) || chỉ số khối (u32 big-endian) || cờ khối cuối (1 byte, 0 hoặc 1).
//! Cờ khối cuối nằm trong nonce nên cắt bớt đuôi hay đổi thứ tự khối đều làm giải mã lỗi; từng khối giải mã độc lập
//! nên stream và resume theo chỉ số khối được. Tệp rỗng vẫn có đúng một khối cuối (chỉ có tag).
//! Không tự viết primitive: AES-GCM và SHA-256 từ RustCrypto.
use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use sha2::{Digest, Sha256};

/// Kích thước bản rõ mỗi khối (64 KiB). Khối mã hóa dài hơn 16 byte (tag).
pub const CHUNK: usize = 64 * 1024;
const TAG: usize = 16;
pub const KEY_LEN: usize = 32;
pub const PREFIX_LEN: usize = 7;

#[derive(Debug, PartialEq, Eq)]
pub enum MediaError {
    /// Khóa hoặc tiền tố nonce sai độ dài.
    BadParams,
    /// Hash SHA-256 của ciphertext không khớp `MediaContent.ciphertext_sha256`.
    HashMismatch,
    /// Một khối không xác thực được (sai khóa, bị sửa, mất/đổi thứ tự/cắt đuôi).
    Corrupt,
    /// Quá 2^32 khối.
    TooLarge,
}

/// Khóa ngẫu nhiên cho một tệp: đặt vào `MediaContent.key` và `nonce_prefix`.
pub struct MediaKey {
    pub key: [u8; KEY_LEN],
    pub nonce_prefix: [u8; PREFIX_LEN],
}

impl MediaKey {
    pub fn generate() -> MediaKey {
        let mut key = [0u8; KEY_LEN];
        let mut nonce_prefix = [0u8; PREFIX_LEN];
        getrandom::getrandom(&mut key).expect("RNG hệ điều hành");
        getrandom::getrandom(&mut nonce_prefix).expect("RNG hệ điều hành");
        MediaKey { key, nonce_prefix }
    }
}

fn cipher(key: &[u8]) -> Result<Aes256Gcm, MediaError> {
    Aes256Gcm::new_from_slice(key).map_err(|_| MediaError::BadParams)
}

fn nonce(prefix: &[u8], index: u32, last: bool) -> Result<[u8; 12], MediaError> {
    if prefix.len() != PREFIX_LEN {
        return Err(MediaError::BadParams);
    }
    let mut n = [0u8; 12];
    n[..PREFIX_LEN].copy_from_slice(prefix);
    n[PREFIX_LEN..PREFIX_LEN + 4].copy_from_slice(&index.to_be_bytes());
    n[11] = last as u8;
    Ok(n)
}

/// Mã hóa một khối (dùng cho stream/resume). `last` phải đúng cho khối cuối của tệp.
pub fn seal_chunk(key: &[u8], prefix: &[u8], index: u32, last: bool, plain: &[u8]) -> Result<Vec<u8>, MediaError> {
    let n = nonce(prefix, index, last)?;
    cipher(key)?.encrypt(Nonce::from_slice(&n), plain).map_err(|_| MediaError::Corrupt)
}

/// Giải mã một khối.
pub fn open_chunk(key: &[u8], prefix: &[u8], index: u32, last: bool, ct: &[u8]) -> Result<Vec<u8>, MediaError> {
    let n = nonce(prefix, index, last)?;
    cipher(key)?.decrypt(Nonce::from_slice(&n), ct).map_err(|_| MediaError::Corrupt)
}

/// Mã hóa cả tệp trong bộ nhớ. Trả (ciphertext, SHA-256 của ciphertext) để điền `ciphertext_sha256` và `size_bytes`.
pub fn encrypt(plain: &[u8], key: &[u8], prefix: &[u8]) -> Result<(Vec<u8>, [u8; 32]), MediaError> {
    let chunks: Vec<&[u8]> = if plain.is_empty() { vec![&[][..]] } else { plain.chunks(CHUNK).collect() };
    if chunks.len() as u64 > u32::MAX as u64 {
        return Err(MediaError::TooLarge);
    }
    let mut out = Vec::with_capacity(plain.len() + chunks.len() * TAG);
    for (i, c) in chunks.iter().enumerate() {
        out.extend(seal_chunk(key, prefix, i as u32, i + 1 == chunks.len(), c)?);
    }
    let hash = Sha256::digest(&out).into();
    Ok((out, hash))
}

/// Kiểm hash rồi giải mã cả tệp. Hash sai trả `HashMismatch` trước khi đụng tới khóa.
pub fn decrypt(ct: &[u8], key: &[u8], prefix: &[u8], sha256: &[u8]) -> Result<Vec<u8>, MediaError> {
    if Sha256::digest(ct).as_slice() != sha256 {
        return Err(MediaError::HashMismatch);
    }
    let full = CHUNK + TAG;
    let chunks: Vec<&[u8]> = if ct.is_empty() { vec![] } else { ct.chunks(full).collect() };
    if chunks.is_empty() {
        return Err(MediaError::Corrupt); // tệp rỗng vẫn có một khối cuối chỉ chứa tag
    }
    let mut out = Vec::with_capacity(ct.len());
    for (i, c) in chunks.iter().enumerate() {
        out.extend(open_chunk(key, prefix, i as u32, i + 1 == chunks.len(), c)?);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pattern(n: usize) -> Vec<u8> {
        (0..n).map(|i| (i * 31 % 251) as u8).collect()
    }

    #[test]
    fn round_trip_nhieu_kich_thuoc() {
        let k = MediaKey::generate();
        for n in [0, 1, CHUNK - 1, CHUNK, CHUNK + 1, 3 * CHUNK, 3 * CHUNK + 17] {
            let p = pattern(n);
            let (ct, h) = encrypt(&p, &k.key, &k.nonce_prefix).unwrap();
            assert_ne!(ct.get(..n.min(32)), p.get(..n.min(32)).filter(|s| !s.is_empty()), "ciphertext không được trùng bản rõ (n={n})");
            assert_eq!(decrypt(&ct, &k.key, &k.nonce_prefix, &h).unwrap(), p, "n={n}");
        }
    }

    #[test]
    fn kich_thuoc_ciphertext() {
        let k = MediaKey::generate();
        let (ct, _) = encrypt(&pattern(2 * CHUNK + 5), &k.key, &k.nonce_prefix).unwrap();
        assert_eq!(ct.len(), 2 * CHUNK + 5 + 3 * TAG);
        let (ct0, _) = encrypt(&[], &k.key, &k.nonce_prefix).unwrap();
        assert_eq!(ct0.len(), TAG);
    }

    #[test]
    fn sai_khoa_hoac_hash() {
        let k = MediaKey::generate();
        let p = pattern(CHUNK + 10);
        let (ct, h) = encrypt(&p, &k.key, &k.nonce_prefix).unwrap();
        let other = MediaKey::generate();
        assert_eq!(decrypt(&ct, &other.key, &k.nonce_prefix, &h), Err(MediaError::Corrupt));
        assert_eq!(decrypt(&ct, &k.key, &other.nonce_prefix, &h), Err(MediaError::Corrupt));
        let mut bad = h;
        bad[0] ^= 1;
        assert_eq!(decrypt(&ct, &k.key, &k.nonce_prefix, &bad), Err(MediaError::HashMismatch));
        assert_eq!(decrypt(&ct, &k.key[..16], &k.nonce_prefix, &h), Err(MediaError::BadParams));
        assert_eq!(decrypt(&ct, &k.key, &k.nonce_prefix[..3], &h), Err(MediaError::BadParams));
    }

    /// Hash khớp (kẻ tấn công tính lại) nhưng ciphertext bị sửa/cắt/đổi chỗ: GCM và cờ khối cuối phải bắt được.
    #[test]
    fn sua_cat_doi_cho_khoi() {
        let k = MediaKey::generate();
        let p = pattern(3 * CHUNK);
        let (ct, _) = encrypt(&p, &k.key, &k.nonce_prefix).unwrap();
        let full = CHUNK + TAG;
        let rehash = |b: &[u8]| -> [u8; 32] { Sha256::digest(b).into() };
        let try_dec = |b: &[u8]| decrypt(b, &k.key, &k.nonce_prefix, &rehash(b));

        let mut flipped = ct.clone();
        flipped[100] ^= 1;
        assert_eq!(try_dec(&flipped), Err(MediaError::Corrupt));

        // Cắt khối cuối: khối thứ 2 giờ bị coi là cuối nhưng nonce ghi "không cuối".
        assert_eq!(try_dec(&ct[..2 * full]), Err(MediaError::Corrupt));
        // Cắt giữa khối.
        assert_eq!(try_dec(&ct[..ct.len() - 5]), Err(MediaError::Corrupt));
        // Đổi chỗ hai khối.
        let mut swapped = ct.clone();
        swapped[..full].copy_from_slice(&ct[full..2 * full]);
        swapped[full..2 * full].copy_from_slice(&ct[..full]);
        assert_eq!(try_dec(&swapped), Err(MediaError::Corrupt));
        // Lặp khối.
        let mut dup = ct[..full].to_vec();
        dup.extend_from_slice(&ct);
        assert_eq!(try_dec(&dup), Err(MediaError::Corrupt));
        // Rỗng hoàn toàn (không có cả khối cuối).
        assert_eq!(try_dec(&[]), Err(MediaError::Corrupt));
    }

    /// Resume/stream: giải mã riêng từng khối theo chỉ số cho cùng kết quả.
    #[test]
    fn tung_khoi_doc_lap() {
        let k = MediaKey::generate();
        let p = pattern(2 * CHUNK + 9);
        let (ct, _) = encrypt(&p, &k.key, &k.nonce_prefix).unwrap();
        let full = CHUNK + TAG;
        assert_eq!(open_chunk(&k.key, &k.nonce_prefix, 1, false, &ct[full..2 * full]).unwrap(), &p[CHUNK..2 * CHUNK]);
        assert_eq!(open_chunk(&k.key, &k.nonce_prefix, 2, true, &ct[2 * full..]).unwrap(), &p[2 * CHUNK..]);
        assert!(open_chunk(&k.key, &k.nonce_prefix, 2, false, &ct[2 * full..]).is_err());
    }

    #[test]
    fn khoa_ngau_nhien_khac_nhau() {
        let (a, b) = (MediaKey::generate(), MediaKey::generate());
        assert_ne!(a.key, b.key);
        assert_ne!(a.nonce_prefix, b.nonce_prefix);
    }
}
