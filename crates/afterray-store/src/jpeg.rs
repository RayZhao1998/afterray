/// Reads width/height from a JPEG SOF marker without decoding pixels.
#[must_use]
pub fn jpeg_pixel_size(bytes: &[u8]) -> Option<(i64, i64)> {
    if bytes.len() < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8 {
        return None;
    }
    let mut index = 2;
    while index + 8 < bytes.len() {
        if bytes[index] != 0xFF {
            index += 1;
            continue;
        }
        let marker = bytes[index + 1];
        if marker == 0x00 || marker == 0xFF {
            index += 1;
            continue;
        }
        if marker == 0xD8 || marker == 0xD9 || (0xD0..=0xD7).contains(&marker) {
            index += 2;
            continue;
        }
        if index + 3 >= bytes.len() {
            return None;
        }
        let length = u16::from_be_bytes([bytes[index + 2], bytes[index + 3]]) as usize;
        if length < 2 {
            return None;
        }
        if matches!(
            marker,
            0xC0..=0xC3 | 0xC5..=0xC7 | 0xC9..=0xCB | 0xCD..=0xCF
        ) {
            let height = i64::from(u16::from_be_bytes([bytes[index + 5], bytes[index + 6]]));
            let width = i64::from(u16::from_be_bytes([bytes[index + 7], bytes[index + 8]]));
            // Match jpeg_to_i420: odd SOF edges are cropped before encode.
            let width = width & !1;
            let height = height & !1;
            if width >= 16 && height >= 16 {
                return Some((width, height));
            }
            return None;
        }
        index = index.saturating_add(2).saturating_add(length);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::jpeg_pixel_size;

    #[test]
    fn reads_sof0_dimensions() {
        // Minimal SOI + SOF0 (8-bit, 16x32, 1 component) + EOI.
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x20, 0x01, 0x01, 0x11,
            0x00, 0xFF, 0xD9,
        ];
        assert_eq!(jpeg_pixel_size(&jpeg), Some((32, 16)));
    }

    #[test]
    fn crops_odd_sof_to_even_i420_size() {
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x04, 0x5D, 0x06, 0xC0, 0x01, 0x01, 0x11,
            0x00, 0xFF, 0xD9,
        ];
        // 1728x1117 → 1728x1116
        assert_eq!(jpeg_pixel_size(&jpeg), Some((1728, 1116)));
    }

    #[test]
    fn rejects_non_jpeg() {
        assert_eq!(jpeg_pixel_size(b"not-a-jpeg"), None);
    }
}
