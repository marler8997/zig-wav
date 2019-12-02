const std = @import("std");

pub const Format = enum {
    U8,
    S16LSB,
    S24LSB,
    S32LSB,

    pub fn getNumBytes(self: Format) u16 {
        return switch (self) {
            .U8 => @as(u16, 1),
            .S16LSB => @as(u16, 2),
            .S24LSB => @as(u16, 3),
            .S32LSB => @as(u16, 4),
        };
    }
};

pub const PreloadedInfo = struct {
    num_channels: usize,
    sample_rate: usize,
    format: Format,
    num_samples: usize,

    pub fn getNumBytes(self: PreloadedInfo) usize {
        return self.num_samples * self.num_channels * self.format.getNumBytes();
    }
};

// verbose is comptime so we can avoid using std.debug.warn which doesn't
// exist on some targets (e.g. wasm)
pub fn Loader(comptime ReadError: type, comptime verbose: bool) type {
    return struct {
        fn readIdentifier(stream: *std.io.InStream(ReadError)) ![4]u8 {
            var quad: [4]u8 = undefined;
            try stream.readNoEof(quad[0..]);
            return quad;
        }

        fn preloadError(comptime message: []const u8) !PreloadedInfo {
            if (verbose) {
                std.debug.warn("{}\n", message);
            }
            return error.WavLoadFailed;
        }

        pub fn preload(stream: *std.io.InStream(ReadError)) !PreloadedInfo {
            // read RIFF chunk descriptor (12 bytes)
            const chunk_id = try readIdentifier(stream);
            if (!std.mem.eql(u8, &chunk_id, "RIFF")) {
                return preloadError("missing \"RIFF\" header");
            }
            try stream.skipBytes(4); // ignore chunk_size
            const format_id = try readIdentifier(stream);
            if (!std.mem.eql(u8, &format_id, "WAVE")) {
                return preloadError("missing \"WAVE\" identifier");
            }

            // read "fmt" sub-chunk
            const subchunk1_id = try readIdentifier(stream);
            if (!std.mem.eql(u8, &subchunk1_id, "fmt ")) {
                return preloadError("missing \"fmt \" header");
            }
            const subchunk1_size = try stream.readIntLittle(u32);
            if (subchunk1_size != 16) {
                return preloadError("not PCM (subchunk1_size != 16)");
            }
            const audio_format = try stream.readIntLittle(u16);
            if (audio_format != 1) {
                return preloadError("not integer PCM (audio_format != 1)");
            }
            const num_channels = try stream.readIntLittle(u16);
            const sample_rate = try stream.readIntLittle(u32);
            const byte_rate = try stream.readIntLittle(u32);
            const block_align = try stream.readIntLittle(u16);
            const bits_per_sample = try stream.readIntLittle(u16);

            if (num_channels < 1 or num_channels > 16) {
                return preloadError("invalid number of channels");
            }
            if (sample_rate < 1 or sample_rate > 192000) {
                return preloadError("invalid sample_rate");
            }
            const format = switch (bits_per_sample) {
                8 => Format.U8,
                16 => Format.S16LSB,
                24 => Format.S24LSB,
                32 => Format.S32LSB,
                else => return preloadError("invalid number of bits per sample"),
            };
            const bytes_per_sample = format.getNumBytes();
            if (byte_rate != sample_rate * num_channels * bytes_per_sample) {
                return preloadError("invalid byte_rate");
            }
            if (block_align != num_channels * bytes_per_sample) {
                return preloadError("invalid block_align");
            }

            // read "data" sub-chunk header
            const subchunk2_id = try readIdentifier(stream);
            if (!std.mem.eql(u8, &subchunk2_id, "data")) {
                return preloadError("missing \"data\" header");
            }
            const subchunk2_size = try stream.readIntLittle(u32);
            if ((subchunk2_size % (num_channels * bytes_per_sample)) != 0) {
                return preloadError("invalid subchunk2_size");
            }
            const num_samples = subchunk2_size / (num_channels * bytes_per_sample);

            return PreloadedInfo {
                .num_channels = num_channels,
                .sample_rate = sample_rate,
                .format = format,
                .num_samples = num_samples,
            };
        }

        pub fn load(stream: *std.io.InStream(ReadError), preloaded: PreloadedInfo, out_buffer: []u8) !void {
            const num_bytes = preloaded.getNumBytes();
            std.debug.assert(out_buffer.len >= num_bytes);
            try stream.readNoEof(out_buffer[0..num_bytes]);
        }
    };
}

pub const SaveInfo = struct {
    num_channels: usize,
    sample_rate: usize,
    format: Format,
    data: []const u8,
};

pub fn Saver(comptime WriteError: type) type {
    return struct {
        pub fn save(stream: *std.io.OutStream(WriteError), info: SaveInfo) !void {
            const data_len = @intCast(u32, info.data.len);
            const bytes_per_sample = info.format.getNumBytes();

            // location of "data" header
            const data_chunk_pos: u32 = 36;

            // length of file
            const file_length = data_chunk_pos + 8 + data_len;

            try stream.write("RIFF");
            try stream.writeIntLittle(u32, file_length - 8);
            try stream.write("WAVE");

            try stream.write("fmt ");
            try stream.writeIntLittle(u32, 16); // PCM
            try stream.writeIntLittle(u16, 1); // uncompressed
            try stream.writeIntLittle(u16, @intCast(u16, info.num_channels));
            try stream.writeIntLittle(u32, @intCast(u32, info.sample_rate));
            try stream.writeIntLittle(u32, @intCast(u32, info.sample_rate * info.num_channels) * bytes_per_sample);
            try stream.writeIntLittle(u16, @intCast(u16, info.num_channels) * bytes_per_sample);
            try stream.writeIntLittle(u16, bytes_per_sample * 8);

            try stream.write("data");
            try stream.writeIntLittle(u32, data_len);
            try stream.write(info.data);
        }
    };
}

test "basic coverage (loading)" {
    const null_wav = [_]u8 {
        0x52, 0x49, 0x46, 0x46, 0x7C, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56,
        0x45, 0x66, 0x6D, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x01, 0x00, 0x44, 0xAC, 0x00, 0x00, 0x88, 0x58, 0x01, 0x00, 0x02,
        0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61, 0x58, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xFF, 0xFF, 0x02, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00,
        0x00, 0xFF, 0xFF, 0x02, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0xFE, 0xFF, 0x01, 0x00, 0x01,
        0x00, 0xFE, 0xFF, 0x03, 0x00, 0xFD, 0xFF, 0x02, 0x00, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0x01, 0x00, 0xFE,
        0xFF, 0x02, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF,
        0x00, 0x00, 0x01, 0x00, 0xFE, 0xFF, 0x02, 0x00, 0xFF, 0xFF, 0x00,
        0x00, 0x00, 0x00, 0xFF, 0xFF, 0x03, 0x00, 0xFC, 0xFF, 0x03, 0x00,
    };

    var sis = std.io.SliceInStream.init(null_wav[0..]);
    const MyLoader = Loader(std.io.SliceInStream.Error, true);
    const preloaded = try MyLoader.preload(&sis.stream);

    std.testing.expectEqual(@as(usize, 1), preloaded.num_channels);
    std.testing.expectEqual(@as(usize, 44100), preloaded.sample_rate);
    std.testing.expectEqual(Format.S16LSB, preloaded.format);
    std.testing.expectEqual(@as(usize, 44), preloaded.num_samples);

    var buffer: [88]u8 = undefined;
    try MyLoader.load(&sis.stream, preloaded, buffer[0..]);
}

test "basic coverage (saving)" {
    var buffer: [1000]u8 = undefined;
    var sos = std.io.SliceOutStream.init(buffer[0..]);
    const MySaver = Saver(std.io.SliceOutStream.Error);
    try MySaver.save(&sos.stream, SaveInfo {
        .num_channels = 1,
        .sample_rate = 44100,
        .format = .S16LSB,
        .data = &[_]u8{0, 0, 0, 0, 0, 0, 0, 0},
    });

    std.testing.expectEqualSlices(u8, "RIFF", buffer[0..4]);
}
