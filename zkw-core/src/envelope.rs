//! Fixed 512-byte memo envelope and chunking. Layout matches the Python reference:
//!
//! ```text
//! 0   2  magic "ZW"
//! 2   1  version (0x01)
//! 3   1  type
//! 4   8  conv_tag
//! 12  1  chunk_index (0-based)
//! 13  1  chunk_total (1..=15)
//! 14  8  msg_id
//! 22  2  body_len (big-endian)
//! 24  n  body
//! 24+n   random padding to 512
//! ```

use std::collections::HashMap;

use crate::error::{fail, Result};
use crate::primitives as p;

pub const MEMO_LEN: usize = 512;
pub const HEADER_LEN: usize = 24;
pub const MAX_BODY: usize = MEMO_LEN - HEADER_LEN; // 488
pub const MAGIC: &[u8; 2] = b"ZW";
pub const VERSION: u8 = 1;
pub const MAX_CHUNKS: usize = 15;

pub const T_HELLO: u8 = 0x01;
pub const T_BUNDLE: u8 = 0x02;
pub const T_INIT: u8 = 0x03;
pub const T_MSG: u8 = 0x10;
pub const T_RECEIPT: u8 = 0x11;
pub const T_REACTION: u8 = 0x12;
pub const T_KEY_UPDATE: u8 = 0x13;
pub const T_CLOSE: u8 = 0x7F;

fn known_type(t: u8) -> bool {
    matches!(
        t,
        T_HELLO | T_BUNDLE | T_INIT | T_MSG | T_RECEIPT | T_REACTION | T_KEY_UPDATE | T_CLOSE
    )
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Envelope {
    pub kind: u8,
    pub conv_tag: [u8; 8],
    pub chunk_index: u8,
    pub chunk_total: u8,
    pub msg_id: [u8; 8],
    pub body: Vec<u8>,
}

impl Envelope {
    /// `pad`: None = random padding (production). Some(bytes) = fixed padding (test vectors).
    pub fn encode(&self, pad: Option<&[u8]>) -> Result<[u8; MEMO_LEN]> {
        if !known_type(self.kind) {
            return fail("unknown type");
        }
        if self.chunk_total == 0 || self.chunk_total as usize > MAX_CHUNKS || self.chunk_index >= self.chunk_total {
            return fail("bad chunk numbering");
        }
        if self.body.len() > MAX_BODY {
            return fail("body too large");
        }
        let mut out = [0u8; MEMO_LEN];
        out[..2].copy_from_slice(MAGIC);
        out[2] = VERSION;
        out[3] = self.kind;
        out[4..12].copy_from_slice(&self.conv_tag);
        out[12] = self.chunk_index;
        out[13] = self.chunk_total;
        out[14..22].copy_from_slice(&self.msg_id);
        out[22..24].copy_from_slice(&(self.body.len() as u16).to_be_bytes());
        let end = HEADER_LEN + self.body.len();
        out[HEADER_LEN..end].copy_from_slice(&self.body);
        let fill = MEMO_LEN - end;
        match pad {
            Some(pd) => {
                let n = fill.min(pd.len());
                out[end..end + n].copy_from_slice(&pd[..n]);
            }
            None => out[end..].copy_from_slice(&p::rand_vec(fill)),
        }
        Ok(out)
    }

    /// Returns None for memos that are not ours (plain wallet memos, other apps).
    pub fn decode(memo: &[u8]) -> Option<Self> {
        if memo.len() != MEMO_LEN || &memo[..2] != MAGIC || memo[2] != VERSION {
            return None;
        }
        let kind = memo[3];
        let (idx, total) = (memo[12], memo[13]);
        let blen = u16::from_be_bytes([memo[22], memo[23]]) as usize;
        if !known_type(kind) || blen > MAX_BODY || total == 0 || total as usize > MAX_CHUNKS || idx >= total {
            return None;
        }
        let mut conv_tag = [0u8; 8];
        conv_tag.copy_from_slice(&memo[4..12]);
        let mut msg_id = [0u8; 8];
        msg_id.copy_from_slice(&memo[14..22]);
        Some(Self {
            kind,
            conv_tag,
            chunk_index: idx,
            chunk_total: total,
            msg_id,
            body: memo[HEADER_LEN..HEADER_LEN + blen].to_vec(),
        })
    }
}

/// Split a payload into memos. All memos go into ONE transaction (ZIP-321 multi-output).
pub fn split(kind: u8, conv_tag: [u8; 8], payload: &[u8]) -> Result<Vec<Vec<u8>>> {
    let msg_id: [u8; 8] = p::rand_array();
    let parts: Vec<&[u8]> = if payload.is_empty() {
        vec![&[][..]]
    } else {
        payload.chunks(MAX_BODY).collect()
    };
    if parts.len() > MAX_CHUNKS {
        return fail("payload needs too many memos");
    }
    let total = parts.len() as u8;
    parts
        .iter()
        .enumerate()
        .map(|(i, part)| {
            Envelope {
                kind,
                conv_tag,
                chunk_index: i as u8,
                chunk_total: total,
                msg_id,
                body: part.to_vec(),
            }
            .encode(None)
            .map(|m| m.to_vec())
        })
        .collect()
}

struct Pending {
    started: u64,
    kind: u8,
    total: u8,
    conv_tag: [u8; 8],
    parts: HashMap<u8, Vec<u8>>,
}

/// Collects chunks; the wallet may surface outputs of one transaction in any order.
pub struct Reassembler {
    pending: HashMap<[u8; 8], Pending>,
    ttl_s: u64,
}

impl Default for Reassembler {
    fn default() -> Self {
        Self {
            pending: HashMap::new(),
            ttl_s: 3600,
        }
    }
}

impl Reassembler {
    /// Returns (type, conv_tag, payload) once all chunks have arrived.
    pub fn add(&mut self, env: &Envelope, now: u64) -> Option<(u8, [u8; 8], Vec<u8>)> {
        let ttl = self.ttl_s;
        self.pending.retain(|_, v| now.saturating_sub(v.started) <= ttl);
        if env.chunk_total == 1 {
            return Some((env.kind, env.conv_tag, env.body.clone()));
        }
        let entry = self.pending.entry(env.msg_id).or_insert_with(|| Pending {
            started: now,
            kind: env.kind,
            total: env.chunk_total,
            conv_tag: env.conv_tag,
            parts: HashMap::new(),
        });
        if (entry.kind, entry.total, entry.conv_tag) != (env.kind, env.chunk_total, env.conv_tag) {
            return None; // inconsistent chunk; ignore
        }
        entry.parts.insert(env.chunk_index, env.body.clone());
        if entry.parts.len() == entry.total as usize {
            let done = self.pending.remove(&env.msg_id)?;
            let mut payload = Vec::new();
            for i in 0..done.total {
                payload.extend_from_slice(done.parts.get(&i)?);
            }
            return Some((done.kind, done.conv_tag, payload));
        }
        None
    }
}
