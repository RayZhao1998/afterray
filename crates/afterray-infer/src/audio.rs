use afterray_models::AdapterError;
use rubato::{FastFixedIn, PolynomialDegree, Resampler};
use std::{fs::File, path::Path};
use symphonia::core::{
    audio::{Channels, SampleBuffer},
    codecs::DecoderOptions,
    formats::FormatOptions,
    io::{MediaSourceStream, MediaSourceStreamOptions},
    meta::MetadataOptions,
    probe::Hint,
};

/// Decode any container Symphonia understands (m4a/AAC from capture, wav, mp3)
/// into mono f32 at 16 kHz.
pub fn load_mono_16k(path: &Path) -> Result<Vec<f32>, AdapterError> {
    let file = File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(file), MediaSourceStreamOptions::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|ext| ext.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|error| AdapterError::InvalidOutput(format!("could not probe audio: {error}")))?;
    let mut format = probed.format;
    let track = format
        .default_track()
        .ok_or_else(|| AdapterError::InvalidOutput("audio file has no default track".into()))?;
    let track_id = track.id;
    let sample_rate = track
        .codec_params
        .sample_rate
        .ok_or_else(|| AdapterError::InvalidOutput("audio track has no sample rate".into()))?;
    let channel_count = track.codec_params.channels.map_or(1, Channels::count);
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|error| AdapterError::InvalidOutput(format!("could not decode audio: {error}")))?;

    let mut interleaved = Vec::new();
    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(symphonia::core::errors::Error::IoError(error))
                if error.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(symphonia::core::errors::Error::ResetRequired) => break,
            Err(error) => {
                return Err(AdapterError::InvalidOutput(format!(
                    "audio decode failed: {error}"
                )));
            }
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded_packet = decoder.decode(&packet).map_err(|error| {
            AdapterError::InvalidOutput(format!("audio decode failed: {error}"))
        })?;
        let spec = *decoded_packet.spec();
        let mut buffer = SampleBuffer::<f32>::new(decoded_packet.capacity() as u64, spec);
        buffer.copy_interleaved_ref(decoded_packet);
        interleaved.extend_from_slice(buffer.samples());
    }

    let mono = downmix_mono(&interleaved, channel_count.max(1));
    resample_to_16k(&mono, sample_rate)
}

fn downmix_mono(samples: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return samples.to_vec();
    }
    samples
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / channels as f32)
        .collect()
}

fn resample_to_16k(samples: &[f32], sample_rate: u32) -> Result<Vec<f32>, AdapterError> {
    if sample_rate == 16_000 {
        return Ok(samples.to_vec());
    }
    let mut resampler = FastFixedIn::<f32>::new(
        f64::from(16_000) / f64::from(sample_rate),
        1.0,
        PolynomialDegree::Septic,
        1024,
        1,
    )
    .map_err(|error| AdapterError::InvalidOutput(format!("resampler failed: {error}")))?;
    let mut output = Vec::new();
    let mut offset = 0;
    while offset + 1024 <= samples.len() {
        let chunk = &samples[offset..offset + 1024];
        let chunk_out = resampler
            .process(&[chunk], None)
            .map_err(|error| AdapterError::InvalidOutput(format!("resample failed: {error}")))?;
        output.extend_from_slice(&chunk_out[0]);
        offset += 1024;
    }
    if offset < samples.len() {
        let mut tail = samples[offset..].to_vec();
        tail.resize(1024, 0.0);
        let tail_out = resampler
            .process(&[&tail], None)
            .map_err(|error| AdapterError::InvalidOutput(format!("resample failed: {error}")))?;
        let keep = tail_out[0].len() * (samples.len() - offset) / 1024;
        output.extend_from_slice(&tail_out[0][..keep.min(tail_out[0].len())]);
    }
    Ok(output)
}
