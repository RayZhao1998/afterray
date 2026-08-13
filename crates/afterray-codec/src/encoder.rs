//! rav1e backend for [`crate::Av1Encoder`].

use crate::{
    CodecError, EncodedGop, EncodedGopFrame, GopFrameInput, IVF_FOURCC_AV01, IVF_FRAME_HEADER_LEN,
    IVF_HEADER_LEN, mux_ivf,
};
use rav1e::prelude::*;

/// rav1e encoder: speed 8, quantizer 100, 4 tiles, closed GOP.
#[derive(Debug, Clone)]
pub struct Rav1eEncoder {
    /// rav1e speed preset (0 = slowest / best, 10 = fastest). Default 8.
    pub speed: u8,
    /// Constant quantizer (0–255). Default 100, matching the design proof.
    pub quantizer: usize,
    /// Desired tile count. rav1e may use fewer tiles on tiny resolutions.
    pub tiles: usize,
}

impl Default for Rav1eEncoder {
    fn default() -> Self {
        Self {
            speed: 8,
            quantizer: 100,
            tiles: 4,
        }
    }
}

impl crate::Av1Encoder for Rav1eEncoder {
    fn encode_closed_gop(&self, frames: &[GopFrameInput<'_>]) -> Result<EncodedGop, CodecError> {
        encode_closed_gop(self, frames)
    }
}

#[allow(clippy::too_many_lines)]
fn encode_closed_gop(
    encoder: &Rav1eEncoder,
    frames: &[GopFrameInput<'_>],
) -> Result<EncodedGop, CodecError> {
    if frames.is_empty() {
        return Err(CodecError::EmptyGop);
    }
    let width = frames[0].width;
    let height = frames[0].height;
    if width < 16 || height < 16 || width % 2 != 0 || height % 2 != 0 {
        return Err(CodecError::InvalidDimensions { width, height });
    }
    for (index, frame) in frames.iter().enumerate() {
        if frame.width != width || frame.height != height {
            return Err(CodecError::MismatchedDimensions {
                index,
                expected_width: width,
                expected_height: height,
                width: frame.width,
                height: frame.height,
            });
        }
        let expected = i420_len(width, height);
        if frame.yuv.len() != expected {
            return Err(CodecError::InvalidI420 {
                index,
                expected,
                actual: frame.yuv.len(),
            });
        }
    }

    let keyint = u16::try_from(frames.len()).map_err(|_| CodecError::GopTooLong(frames.len()))?;

    let mut enc = EncoderConfig::with_speed_preset(encoder.speed);
    enc.width = width as usize;
    enc.height = height as usize;
    enc.bit_depth = 8;
    enc.chroma_sampling = ChromaSampling::Cs420;
    enc.quantizer = encoder.quantizer;
    enc.tiles = encoder.tiles;
    enc.still_picture = frames.len() == 1;
    enc.low_latency = true;
    enc.time_base = Rational { num: 1, den: 1 };
    enc.set_key_frame_interval(u64::from(keyint), u64::from(keyint));

    let cfg = Config::new().with_encoder_config(enc).with_threads(1);
    let mut ctx: Context<u8> = cfg
        .new_context()
        .map_err(|err| CodecError::Encode(err.to_string()))?;

    for (index, input) in frames.iter().enumerate() {
        let mut frame = ctx.new_frame();
        fill_i420(&mut frame, width, height, input.yuv);
        let params = FrameParameters {
            frame_type_override: if index == 0 {
                FrameTypeOverride::Key
            } else {
                FrameTypeOverride::No
            },
            ..FrameParameters::default()
        };
        ctx.send_frame((frame, params))
            .map_err(|err| CodecError::Encode(err.to_string()))?;
    }
    ctx.flush();

    let mut packets: Vec<Packet<u8>> = Vec::with_capacity(frames.len());
    loop {
        match ctx.receive_packet() {
            Ok(packet) => packets.push(packet),
            Err(EncoderStatus::Encoded | EncoderStatus::NeedMoreData) => {}
            Err(EncoderStatus::LimitReached) => break,
            Err(err) => return Err(CodecError::Encode(err.to_string())),
        }
    }
    packets.sort_by_key(|packet| packet.input_frameno);

    if packets.len() != frames.len() {
        return Err(CodecError::Encode(format!(
            "expected {} packets, got {}",
            frames.len(),
            packets.len()
        )));
    }
    if packets[0].frame_type != FrameType::KEY {
        return Err(CodecError::Encode(format!(
            "closed GOP first frame must be a keyframe, got {:?}",
            packets[0].frame_type
        )));
    }

    let payloads: Vec<&[u8]> = packets
        .iter()
        .map(|packet| packet.data.as_slice())
        .collect();
    let ivf = mux_ivf(width, height, 1, 1, &payloads)?;

    let mut encoded_frames = Vec::with_capacity(packets.len());
    let mut offset = IVF_HEADER_LEN;
    for (index, packet) in packets.iter().enumerate() {
        let byte_length = u32::try_from(packet.data.len()).unwrap_or(u32::MAX);
        encoded_frames.push(EncodedGopFrame {
            index: u16::try_from(index).unwrap_or(u16::MAX),
            is_keyframe: packet.frame_type == FrameType::KEY,
            byte_offset: u32::try_from(offset).unwrap_or(u32::MAX),
            byte_length,
            content_hash: *blake3::hash(&packet.data).as_bytes(),
        });
        offset += IVF_FRAME_HEADER_LEN + packet.data.len();
    }

    debug_assert_eq!(&ivf[8..12], IVF_FOURCC_AV01);

    Ok(EncodedGop {
        codec: crate::CODEC_AV01,
        encoder: crate::ENCODER_RAV1E.to_owned(),
        encoder_version: rav1e::version::full(),
        width,
        height,
        keyint,
        ivf,
        frames: encoded_frames,
    })
}

fn i420_len(width: u32, height: u32) -> usize {
    let y = width as usize * height as usize;
    y + y / 2
}

fn fill_i420(frame: &mut Frame<u8>, width: u32, height: u32, yuv: &[u8]) {
    let width = width as usize;
    let height = height as usize;
    let y_size = width * height;
    let uv_w = width / 2;
    let uv_size = uv_w * (height / 2);
    frame.planes[0].copy_from_raw_u8(&yuv[..y_size], width, 1);
    frame.planes[1].copy_from_raw_u8(&yuv[y_size..y_size + uv_size], uv_w, 1);
    frame.planes[2].copy_from_raw_u8(&yuv[y_size + uv_size..], uv_w, 1);
    for plane in &mut frame.planes {
        plane.pad(width, height);
    }
}
