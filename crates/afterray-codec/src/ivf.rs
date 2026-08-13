//! On2 IVF container used by rav1e / libaom for raw AV1 access units.
//!
//! File header is 32 bytes:
//!
//! ```text
//!  0..3   magic        "DKIF"
//!  4..5   version      u16le = 0
//!  6..7   header size  u16le = 32
//!  8..11  fourcc       "AV01"
//! 12..13  width        u16le
//! 14..15  height       u16le
//! 16..19  timebase den u32le   (frame rate numerator)
//! 20..23  timebase num u32le   (frame rate denominator)
//! 24..27  frame count  u32le
//! 28..31  unused       u32le = 0
//! ```
//!
//! Each frame is a 12-byte header (`size` u32le + `pts` u64le) followed by
//! one AV1 temporal unit (OBUs).
//!
//! Documented 3456×2234 header hex (6-frame GOP, 1/10 s timebase — not a
//! checked-in fixture; PR 3 only ships a tiny 64×64 GOP):
//!
//! ```text
//! 44 4b 49 46 00 00 20 00 41 56 30 31 80 0d ba 08
//! 01 00 00 00 0a 00 00 00 06 00 00 00 00 00 00 00
//! ```

/// IVF file magic (`DKIF`, little-endian "FIVD" fourcc spelled backwards).
pub const IVF_MAGIC: &[u8; 4] = b"DKIF";

/// Codec fourcc written into the IVF header for AV1.
pub const IVF_FOURCC_AV01: &[u8; 4] = b"AV01";

/// Size of the IVF file header in bytes.
pub const IVF_HEADER_LEN: usize = 32;

/// Size of each IVF frame header in bytes.
pub const IVF_FRAME_HEADER_LEN: usize = 12;

/// One compressed temporal unit inside an IVF file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IvfFrame {
    /// Byte offset of this frame's 12-byte IVF header inside the file.
    pub header_offset: u32,
    /// Presentation timestamp from the IVF frame header.
    pub pts: u64,
    /// Compressed AV1 temporal unit (OBUs).
    pub data: Vec<u8>,
}

/// Parsed IVF bitstream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ivf {
    pub width: u16,
    pub height: u16,
    pub timebase_den: u32,
    pub timebase_num: u32,
    pub header_frame_count: u32,
    pub fourcc: [u8; 4],
    pub frames: Vec<IvfFrame>,
}

/// Errors from IVF mux / demux.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum IvfError {
    #[error("buffer too small for IVF header")]
    TruncatedHeader,
    #[error("IVF magic is not DKIF")]
    BadMagic,
    #[error("IVF fourcc is {:?}, expected AV01", String::from_utf8_lossy(.0))]
    BadFourcc([u8; 4]),
    #[error("IVF frame {0} is truncated")]
    TruncatedFrame(usize),
    #[error("width/height do not fit in IVF u16")]
    DimensionOverflow,
}

/// True when `bytes` starts with the IVF magic `DKIF`.
#[must_use]
pub fn is_ivf(bytes: &[u8]) -> bool {
    bytes.starts_with(IVF_MAGIC)
}

/// Mux an IVF file from already-encoded AV1 temporal units.
///
/// `timebase_num` / `timebase_den` follow the IVF convention used by rav1e:
/// frame rate = `timebase_den / timebase_num`.
pub fn mux_ivf(
    width: u32,
    height: u32,
    timebase_num: u32,
    timebase_den: u32,
    frames: &[&[u8]],
) -> Result<Vec<u8>, IvfError> {
    let width = u16::try_from(width).map_err(|_| IvfError::DimensionOverflow)?;
    let height = u16::try_from(height).map_err(|_| IvfError::DimensionOverflow)?;
    let frame_count = u32::try_from(frames.len()).unwrap_or(u32::MAX);

    let mut out = Vec::with_capacity(
        IVF_HEADER_LEN
            + frames
                .iter()
                .map(|frame| IVF_FRAME_HEADER_LEN + frame.len())
                .sum::<usize>(),
    );
    out.extend_from_slice(IVF_MAGIC);
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&u16::try_from(IVF_HEADER_LEN).unwrap_or(32).to_le_bytes());
    out.extend_from_slice(IVF_FOURCC_AV01);
    out.extend_from_slice(&width.to_le_bytes());
    out.extend_from_slice(&height.to_le_bytes());
    out.extend_from_slice(&timebase_den.to_le_bytes());
    out.extend_from_slice(&timebase_num.to_le_bytes());
    out.extend_from_slice(&frame_count.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());

    for (pts, data) in frames.iter().enumerate() {
        let size = u32::try_from(data.len()).unwrap_or(u32::MAX);
        out.extend_from_slice(&size.to_le_bytes());
        out.extend_from_slice(&(pts as u64).to_le_bytes());
        out.extend_from_slice(data);
    }
    Ok(out)
}

/// Demux an IVF bitstream. Frame count in the header may be 0 (rav1e CLI).
pub fn parse_ivf(bytes: &[u8]) -> Result<Ivf, IvfError> {
    if bytes.len() < IVF_HEADER_LEN {
        return Err(IvfError::TruncatedHeader);
    }
    if !bytes.starts_with(IVF_MAGIC) {
        return Err(IvfError::BadMagic);
    }
    let mut fourcc = [0u8; 4];
    fourcc.copy_from_slice(&bytes[8..12]);
    if &fourcc != IVF_FOURCC_AV01 {
        return Err(IvfError::BadFourcc(fourcc));
    }

    let width = u16::from_le_bytes([bytes[12], bytes[13]]);
    let height = u16::from_le_bytes([bytes[14], bytes[15]]);
    let timebase_den = u32::from_le_bytes(bytes[16..20].try_into().unwrap());
    let timebase_num = u32::from_le_bytes(bytes[20..24].try_into().unwrap());
    let header_frame_count = u32::from_le_bytes(bytes[24..28].try_into().unwrap());

    let mut frames = Vec::new();
    let mut offset = IVF_HEADER_LEN;
    while offset + IVF_FRAME_HEADER_LEN <= bytes.len() {
        let size = u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize;
        let pts = u64::from_le_bytes(bytes[offset + 4..offset + 12].try_into().unwrap());
        let data_start = offset + IVF_FRAME_HEADER_LEN;
        let data_end = data_start
            .checked_add(size)
            .ok_or(IvfError::TruncatedFrame(frames.len()))?;
        if data_end > bytes.len() {
            return Err(IvfError::TruncatedFrame(frames.len()));
        }
        frames.push(IvfFrame {
            header_offset: u32::try_from(offset).unwrap_or(u32::MAX),
            pts,
            data: bytes[data_start..data_end].to_vec(),
        });
        offset = data_end;
    }
    if offset != bytes.len() {
        return Err(IvfError::TruncatedFrame(frames.len()));
    }

    Ok(Ivf {
        width,
        height,
        timebase_den,
        timebase_num,
        header_frame_count,
        fourcc,
        frames,
    })
}

/// Rebuild an IVF that contains physical frames `0..=last_index` (inclusive).
pub fn slice_ivf(bytes: &[u8], last_index: usize) -> Result<Vec<u8>, IvfError> {
    let parsed = parse_ivf(bytes)?;
    if parsed.frames.is_empty() {
        return Err(IvfError::TruncatedFrame(0));
    }
    let end = last_index.min(parsed.frames.len().saturating_sub(1));
    let payloads: Vec<&[u8]> = parsed.frames[..=end]
        .iter()
        .map(|frame| frame.data.as_slice())
        .collect();
    mux_ivf(
        u32::from(parsed.width),
        u32::from(parsed.height),
        parsed.timebase_num,
        parsed.timebase_den,
        &payloads,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mux_parse_round_trip() {
        let a = [1u8, 2, 3];
        let b = [9u8, 8, 7, 6];
        let bytes = mux_ivf(64, 48, 1, 1, &[&a, &b]).unwrap();
        assert!(bytes.starts_with(IVF_MAGIC));
        assert_eq!(&bytes[8..12], b"AV01");
        let parsed = parse_ivf(&bytes).unwrap();
        assert_eq!(parsed.width, 64);
        assert_eq!(parsed.height, 48);
        assert_eq!(parsed.header_frame_count, 2);
        assert_eq!(parsed.frames.len(), 2);
        assert_eq!(parsed.frames[0].data, a);
        assert_eq!(parsed.frames[1].data, b);
        assert_eq!(parsed.frames[0].header_offset, IVF_HEADER_LEN as u32);
        assert_eq!(
            parsed.frames[1].header_offset,
            (IVF_HEADER_LEN + IVF_FRAME_HEADER_LEN + a.len()) as u32
        );
    }

    #[test]
    fn reject_non_ivf() {
        assert!(!is_ivf(b"\xff\xd8\xff"));
        assert!(parse_ivf(b"not ivf").is_err());
    }
}
