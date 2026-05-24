const std = @import("std");
const linux = std.os.linux;

const DemoError = error{
    SyscallFailed,
    MissingWebSocketKey,
    FrameTooLargeForThisDemo,
    InvalidFrame,
};

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub fn run() !void {
    // Official protocol docs:
    // - RFC 6455 WebSocket Protocol: https://www.rfc-editor.org/rfc/rfc6455
    // - Opening handshake: https://www.rfc-editor.org/rfc/rfc6455#section-1.3
    // - Sec-WebSocket-Accept: https://www.rfc-editor.org/rfc/rfc6455#section-4.2.2
    // - Data framing: https://www.rfc-editor.org/rfc/rfc6455#section-5
    //
    // Official Linux docs yang tetap relevan:
    // - socketpair(2): https://man7.org/linux/man-pages/man2/socketpair.2.html
    // - read(2): https://man7.org/linux/man-pages/man2/read.2.html
    // - write(2): https://man7.org/linux/man-pages/man2/write.2.html
    //
    // Di network asli, browser dan server memakai TCP socket dari socket/connect/accept.
    // Di demo ini kita pakai socketpair supaya client dan server bisa disimulasikan
    // dalam satu process:
    //
    //   client_fd <---- byte stream ----> server_fd
    //
    // Setelah handshake HTTP Upgrade sukses, fd yang sama tetap dipakai.
    // Yang berubah hanya cara kita menafsirkan bytes-nya: dari HTTP text menjadi
    // WebSocket frame.
    std.debug.print("\n== 9. WebSocket mini: HTTP Upgrade lalu frame di atas socket fd ==\n", .{});

    var pair: [2]i32 = undefined;
    try checkNoValue(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair), "socketpair websocket");
    defer sysClose(pair[0]);
    defer sysClose(pair[1]);

    const client_fd = pair[0];
    const server_fd = pair[1];
    std.debug.print("socketpair untuk demo WebSocket -> client fd {d}, server fd {d}\n", .{ client_fd, server_fd });

    try clientSendHandshake(client_fd);
    const accept_value = try serverReadHandshakeAndReply(server_fd);
    try clientReadHandshakeResponse(client_fd, accept_value);

    try clientSendMaskedTextFrame(client_fd, "halo websocket");
    try serverReadClientTextFrame(server_fd);

    try serverSendTextFrame(server_fd, "halo balik dari server");
    try clientReadServerTextFrame(client_fd);

    std.debug.print(
        \\Ringkasnya:
        \\- WebSocket mulai sebagai HTTP request biasa dengan header Upgrade.
        \\- Server membalas 101 Switching Protocols.
        \\- Setelah itu fd TCP yang sama membawa WebSocket frames.
        \\- Client-to-server frame wajib masked; server-to-client frame tidak masked.
        \\
    , .{});
}

fn clientSendHandshake(client_fd: i32) !void {
    // Sec-WebSocket-Key ini contoh dari RFC 6455.
    // Server nanti menghitung:
    //
    //   base64(sha1(key ++ GUID))
    //
    // Hasil untuk key ini adalah:
    //
    //   s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
    const request =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    _ = try sysWrite(client_fd, request);
    std.debug.print("client write HTTP Upgrade request ke fd {d}\n", .{client_fd});
}

fn serverReadHandshakeAndReply(server_fd: i32) ![28]u8 {
    var request_buf: [1024]u8 = undefined;
    const request_len = try sysRead(server_fd, &request_buf);
    const request = request_buf[0..request_len];

    const key = try findHeaderValue(request, "Sec-WebSocket-Key");
    var accept_value = computeAcceptValue(key);

    var response_buf: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &response_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n",
        .{&accept_value},
    );

    _ = try sysWrite(server_fd, response);
    std.debug.print("server read handshake dari fd {d}, lalu balas 101 Switching Protocols\n", .{server_fd});
    std.debug.print("server hitung Sec-WebSocket-Accept: {s}\n", .{&accept_value});
    return accept_value;
}

fn clientReadHandshakeResponse(client_fd: i32, expected_accept: [28]u8) !void {
    var response_buf: [1024]u8 = undefined;
    const response_len = try sysRead(client_fd, &response_buf);
    const response = response_buf[0..response_len];

    if (std.mem.indexOf(u8, response, "101 Switching Protocols") == null) {
        return DemoError.InvalidFrame;
    }
    if (std.mem.indexOf(u8, response, &expected_accept) == null) {
        return DemoError.InvalidFrame;
    }

    std.debug.print("client read response 101; koneksi sekarang resmi jadi WebSocket\n", .{});
}

fn clientSendMaskedTextFrame(client_fd: i32, text: []const u8) !void {
    var frame_buf: [256]u8 = undefined;
    const frame = try buildTextFrame(&frame_buf, text, true);
    _ = try sysWrite(client_fd, frame);

    std.debug.print("client kirim masked text frame: \"{s}\"\n", .{text});
}

fn serverReadClientTextFrame(server_fd: i32) !void {
    var frame_buf: [256]u8 = undefined;
    const frame_len = try sysRead(server_fd, &frame_buf);
    const payload = try decodeTextFrame(frame_buf[0..frame_len], true);

    std.debug.print("server decode frame dari client -> \"{s}\"\n", .{payload});
}

fn serverSendTextFrame(server_fd: i32, text: []const u8) !void {
    var frame_buf: [256]u8 = undefined;
    const frame = try buildTextFrame(&frame_buf, text, false);
    _ = try sysWrite(server_fd, frame);

    std.debug.print("server kirim unmasked text frame: \"{s}\"\n", .{text});
}

fn clientReadServerTextFrame(client_fd: i32) !void {
    var frame_buf: [256]u8 = undefined;
    const frame_len = try sysRead(client_fd, &frame_buf);
    const payload = try decodeTextFrame(frame_buf[0..frame_len], false);

    std.debug.print("client decode frame dari server -> \"{s}\"\n", .{payload});
}

fn findHeaderValue(headers: []const u8, comptime name: []const u8) ![]const u8 {
    const prefix = name ++ ":";
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, prefix)) {
            return std.mem.trim(u8, line[prefix.len..], " \t");
        }
    }
    return DemoError.MissingWebSocketKey;
}

fn computeAcceptValue(key: []const u8) [28]u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(websocket_guid);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);

    var out: [28]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&out, &digest);
    std.debug.assert(encoded.len == out.len );
    return out;
}

fn buildTextFrame(out: []u8, text: []const u8, masked: bool) ![]const u8 {
    // Demo ini hanya mendukung payload kecil <= 125 byte supaya format frame-nya
    // terlihat jelas:
    //
    // byte 0: FIN + opcode text = 0x81
    // byte 1: MASK bit + payload length
    // byte 2..5: masking key, hanya ada untuk client-to-server
    // sisanya: payload bytes
    if (text.len > 125) return DemoError.FrameTooLargeForThisDemo;

    out[0] = 0x81;
    out[1] = @intCast(text.len);

    var cursor: usize = 2;
    if (masked) {
        out[1] |= 0x80;
        const mask = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
        @memcpy(out[cursor .. cursor + 4], &mask);
        cursor += 4;

        for (text, 0..) |byte, i| {
            out[cursor + i] = byte ^ mask[i % 4];
        }
    } else {
        @memcpy(out[cursor .. cursor + text.len], text);
    }

    return out[0 .. cursor + text.len];
}

fn decodeTextFrame(frame: []u8, expect_masked: bool) ![]const u8 {
    if (frame.len < 2) return DemoError.InvalidFrame;

    const fin = (frame[0] & 0x80) != 0;
    const opcode = frame[0] & 0x0f;
    const masked = (frame[1] & 0x80) != 0;
    const len = frame[1] & 0x7f;

    if (!fin or opcode != 0x1) return DemoError.InvalidFrame;
    if (masked != expect_masked) return DemoError.InvalidFrame;
    if (len > 125) return DemoError.FrameTooLargeForThisDemo;

    var cursor: usize = 2;
    if (masked) {
        if (frame.len < cursor + 4 + len) return DemoError.InvalidFrame;
        const mask = frame[cursor .. cursor + 4];
        cursor += 4;

        const payload = frame[cursor .. cursor + len];
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask[i % 4];
        }
        return payload;
    }

    if (frame.len < cursor + len) return DemoError.InvalidFrame;
    return frame[cursor .. cursor + len];
}

fn sysRead(fd: i32, buf: []u8) !usize {
    return checkCount(linux.read(fd, buf.ptr, buf.len), "read websocket");
}

fn sysWrite(fd: i32, bytes: []const u8) !usize {
    return checkCount(linux.write(fd, bytes.ptr, bytes.len), "write websocket");
}

fn sysClose(fd: i32) void {
    _ = linux.close(fd);
}

fn checkCount(rc: usize, op: []const u8) !usize {
    const err = linux.errno(rc);
    if (err != .SUCCESS) {
        std.debug.print("{s} gagal: errno {s}\n", .{ op, @tagName(err) });
        return DemoError.SyscallFailed;
    }
    return rc;
}

fn checkNoValue(rc: usize, op: []const u8) !void {
    _ = try checkCount(rc, op);
}
