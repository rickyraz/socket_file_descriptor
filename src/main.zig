const std = @import("std");
const linux = std.os.linux;
const websocket_demo = @import("websocket_demo.zig");

const DemoError = error{SyscallFailed};

pub fn main(init: std.process.Init) !void {
    _ = init;

    std.debug.print(
        \\Belajar socket sebagai file descriptor di Linux, pakai Zig.
        \\
        \\Catatan awal:
        \\- File descriptor atau fd adalah angka kecil milik process.
        \\- Angka itu menunjuk ke object kernel: file, socket, pipe, terminal, dll.
        \\- Di contoh ini kita sengaja pakai syscall Linux supaya mental model-nya kelihatan.
        \\
    , .{});

    try showInitialFdTable();
    try simulateRegularFileAndSocketFd();
    try simulateSocketpairReadWrite();
    try simulateTcpAcceptCreatesNewFd();
    try simulateSocketIsNotSeekable();
    try simulateNonBlockingRead();
    try simulateEpollReadiness();
    try simulateOnePersistentUpstreamTo100kConsumers();
    try websocket_demo.run();

    std.debug.print(
        \\
        \\Selesai.
        \\Coba juga dari shell:
        \\  ulimit -n
        \\  ls -l /proc/$$/fd
        \\
        \\Di program server sungguhan:
        \\  1 TCP/WebSocket connection aktif biasanya berarti 1 connected socket fd.
        \\  Banyak fd bisa dimonitor oleh epoll tanpa membuat 1 thread per koneksi.
        \\
    , .{});
}

fn showInitialFdTable() !void {
    // Official docs:
    // - /proc/<pid>/fd: https://man7.org/linux/man-pages/man5/proc_pid_fd.5.html
    // - readlink(2): https://man7.org/linux/man-pages/man2/readlink.2.html
    //
    // Simulasi ini membaca symlink /proc/self/fd/<n>.
    // "self" artinya process program ini sendiri.
    std.debug.print("\n== 1. Fd table process ini lewat /proc/self/fd ==\n", .{});
    std.debug.print("Ini bukan semua kernel object di mesin, hanya fd milik process program ini.\n", .{});
    try printKnownFdLinks(0, 10);

    // printKnownFdLinks(0, 10) berarti kita cek:
    // /proc/self/fd/0, /proc/self/fd/1, ..., /proc/self/fd/9.
    //
    // Saat program baru mulai, biasanya hanya ada 3 fd standar:
    // - fd 0 = stdin
    // - fd 1 = stdout
    // - fd 2 = stderr
    //
    // Kalau dijalankan dari terminal, ketiganya sering menunjuk ke terminal
    // yang sama, misalnya /dev/pts/5.
}

fn simulateRegularFileAndSocketFd() !void {
    // Official docs:
    // - open(2): https://man7.org/linux/man-pages/man2/open.2.html
    // - socket(2): https://man7.org/linux/man-pages/man2/socket.2.html
    //
    // Simulasi ini membandingkan fd untuk file biasa dan fd untuk socket.
    // Dua-duanya cuma angka kecil di process, tapi object kernel di belakangnya beda.
    std.debug.print("\n== 2. File biasa dan socket sama-sama dapat angka fd ==\n", .{});

    const file_fd = try sysOpenReadOnly("/dev/null");
    defer sysClose(file_fd);
    std.debug.print("open(\"/dev/null\") -> fd {d}\n", .{file_fd});

    const socket_fd = try sysSocket(linux.AF.INET, linux.SOCK.STREAM, 0);
    defer sysClose(socket_fd);
    std.debug.print("socket(AF_INET, SOCK_STREAM, 0) -> fd {d}\n", .{socket_fd});

    std.debug.print(
        \\Perhatikan: file fd dan socket fd sama-sama integer.
        \\Bedanya ada di object kernel yang ditunjuk oleh integer itu.
        \\
    , .{});
    try printKnownFdLinks(0, @as(i32, @max(file_fd, socket_fd)) + 2);
}

fn simulateSocketpairReadWrite() !void {
    // Official docs:
    // - socketpair(2): https://man7.org/linux/man-pages/man2/socketpair.2.html
    // - read(2): https://man7.org/linux/man-pages/man2/read.2.html
    // - write(2): https://man7.org/linux/man-pages/man2/write.2.html
    // - unix(7): https://man7.org/linux/man-pages/man7/unix.7.html
    //
    // socketpair membuat dua socket endpoint yang langsung tersambung:
    //
    //   fd 3 <---- stream data ----> fd 4
    //
    // Kalau kita write ke satu sisi, sisi lain bisa read data itu.
    std.debug.print("\n== 3. socketpair: dua socket fd yang saling tersambung ==\n", .{});

    var pair: [2]i32 = undefined;
    try checkNoValue(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair), "socketpair");
    defer sysClose(pair[0]);
    defer sysClose(pair[1]);

    std.debug.print("socketpair() -> fd {d} dan fd {d}\n", .{ pair[0], pair[1] });
    std.debug.print("Kita write ke fd {d}, lalu read dari fd {d}.\n", .{ pair[0], pair[1] });

    const msg = "halo dari socket fd";
    _ = try sysWrite(pair[0], msg);

    var buf: [128]u8 = undefined;
    const n = try sysRead(pair[1], &buf);
    std.debug.print("read(fd {d}) -> \"{s}\"\n", .{ pair[1], buf[0..n] });

    std.debug.print(
        \\Poinnya: read/write tidak peduli ini file disk atau socket.
        \\Kernel melihat fd, mencari object di fd table process, lalu menjalankan operasi yang cocok.
        \\
    , .{});
}

fn simulateTcpAcceptCreatesNewFd() !void {
    // Official docs:
    // - socket(2): https://man7.org/linux/man-pages/man2/socket.2.html
    // - bind(2): https://man7.org/linux/man-pages/man2/bind.2.html
    // - listen(2): https://man7.org/linux/man-pages/man2/listen.2.html
    // - connect(2): https://man7.org/linux/man-pages/man2/connect.2.html
    // - accept(2): https://man7.org/linux/man-pages/man2/accept.2.html
    // - getsockname(2): https://man7.org/linux/man-pages/man2/getsockname.2.html
    // - tcp(7): https://man7.org/linux/man-pages/man7/tcp.7.html
    // - ip(7): https://man7.org/linux/man-pages/man7/ip.7.html
    //
    // Di simulasi ini:
    //
    //   client fd 4 <---- TCP stream ----> accepted fd 5
    //
    // client_fd adalah endpoint sisi client.
    // accepted_fd adalah endpoint sisi server untuk koneksi client itu.
    // listen_fd beda lagi: tugasnya hanya menunggu koneksi baru.
    std.debug.print("\n== 4. TCP server: listen fd beda dari accepted client fd ==\n", .{});

    const listen_fd = try sysSocket(linux.AF.INET, linux.SOCK.STREAM, 0);
    defer sysClose(listen_fd);

    var bind_addr = ipv4Address(127, 0, 0, 1, 0);
    try sysBind(listen_fd, &bind_addr);
    try sysListen(listen_fd, 16);

    const actual_addr = try sysGetSockName(listen_fd);
    const port = std.mem.bigToNative(u16, actual_addr.port);
    std.debug.print("listen fd {d} bind ke 127.0.0.1:{d}\n", .{ listen_fd, port });

    const client_fd = try sysSocket(linux.AF.INET, linux.SOCK.STREAM, 0);
    defer sysClose(client_fd);

    var connect_addr = ipv4Address(127, 0, 0, 1, port);
    try sysConnect(client_fd, &connect_addr);
    std.debug.print("client socket connect() -> fd {d}\n", .{client_fd});

    const accepted_fd = try sysAccept(listen_fd);
    defer sysClose(accepted_fd);
    std.debug.print("accept(listen_fd {d}) -> accepted fd {d}\n", .{ listen_fd, accepted_fd });

    _ = try sysWrite(client_fd, "ping via TCP");
    var buf: [128]u8 = undefined;
    const n = try sysRead(accepted_fd, &buf);
    std.debug.print("server read dari accepted fd {d} -> \"{s}\"\n", .{ accepted_fd, buf[0..n] });

    std.debug.print(
        \\Mental model:
        \\- listen_fd hanya menunggu koneksi baru.
        \\- accepted_fd adalah socket baru untuk satu koneksi TCP tertentu.
        \\- Di server besar, proses ini berulang ribuan sampai ratusan ribu kali.
        \\
    , .{});
}

fn simulateSocketIsNotSeekable() !void {
    // Official docs:
    // - lseek(2): https://man7.org/linux/man-pages/man2/lseek.2.html
    // - socket(7): https://man7.org/linux/man-pages/man7/socket.7.html
    //
    // Socket adalah stream/network endpoint.
    // Dia tidak punya "posisi byte saat ini" seperti file di disk,
    // jadi lseek(fd, 0, SEEK_SET) tidak masuk akal untuk socket.
    std.debug.print("\n== 5. Socket bukan file biasa: lseek gagal ==\n", .{});

    var pair: [2]i32 = undefined;
    try checkNoValue(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair), "socketpair");
    defer sysClose(pair[0]);
    defer sysClose(pair[1]);

    const rc = linux.lseek(pair[0], 0, linux.SEEK.SET);
    const err = linux.errno(rc);
    if (err == .SUCCESS) {
        std.debug.print("lseek di socket ternyata sukses, ini tidak umum dan tidak diharapkan.\n", .{});
    } else {
        std.debug.print("lseek(fd {d}, 0, SEEK_SET) gagal dengan errno {s}\n", .{ pair[0], @tagName(err) });
        std.debug.print("Alasannya: socket adalah stream endpoint, bukan file disk yang punya posisi byte.\n", .{});
    }
}

fn simulateNonBlockingRead() !void {
    // Official docs:
    // - fcntl(2): https://man7.org/linux/man-pages/man2/fcntl.2.html
    // - socket(7): https://man7.org/linux/man-pages/man7/socket.7.html
    // - read(2): https://man7.org/linux/man-pages/man2/read.2.html
    // - errno(3): https://man7.org/linux/man-pages/man3/errno.3.html
    //
    // O_NONBLOCK membuat operasi seperti read tidak menggantung thread.
    // Kalau belum ada data, read mengembalikan errno EAGAIN.
    std.debug.print("\n== 6. O_NONBLOCK: read tidak menggantung kalau belum ada data ==\n", .{});

    var pair: [2]i32 = undefined;
    try checkNoValue(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair), "socketpair");
    defer sysClose(pair[0]);
    defer sysClose(pair[1]);

    try setNonBlocking(pair[1]);
    std.debug.print("fd {d} diberi flag O_NONBLOCK memakai fcntl(F_GETFL/F_SETFL)\n", .{pair[1]});

    var buf: [16]u8 = undefined;
    const rc = linux.read(pair[1], &buf, buf.len);
    const err = linux.errno(rc);
    if (err == .AGAIN) {
        std.debug.print("read(fd {d}) saat belum ada data -> EAGAIN, thread tidak macet.\n", .{pair[1]});
    } else if (err == .SUCCESS) {
        std.debug.print("read(fd {d}) sukses tak terduga, bytes: {d}\n", .{ pair[1], rc });
    } else {
        std.debug.print("read(fd {d}) gagal dengan errno {s}\n", .{ pair[1], @tagName(err) });
    }

    _ = try sysWrite(pair[0], "ok");
    const n = try sysRead(pair[1], &buf);
    std.debug.print("setelah fd lain write, read(fd {d}) -> \"{s}\"\n", .{ pair[1], buf[0..n] });
}

fn simulateEpollReadiness() !void {
    // Official docs:
    // - epoll(7): https://man7.org/linux/man-pages/man7/epoll.7.html
    // - epoll_create(2): https://man7.org/linux/man-pages/man2/epoll_create.2.html
    // - epoll_ctl(2): https://man7.org/linux/man-pages/man2/epoll_ctl.2.html
    // - epoll_wait(2): https://man7.org/linux/man-pages/man2/epoll_wait.2.html
    //
    // epoll adalah mekanisme kernel untuk memonitor banyak fd.
    // Aplikasi tidur di epoll_wait(), lalu kernel membangunkan ketika
    // ada fd yang siap dibaca/ditulis.
    std.debug.print("\n== 7. epoll: kernel memberi tahu fd mana yang siap dibaca ==\n", .{});

    var pair: [2]i32 = undefined;
    try checkNoValue(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair), "socketpair");
    defer sysClose(pair[0]);
    defer sysClose(pair[1]);

    const epoll_fd = try checkFd(linux.epoll_create1(linux.EPOLL.CLOEXEC), "epoll_create1");
    defer sysClose(epoll_fd);

    var event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = pair[1] },
    };
    try checkNoValue(linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, pair[1], &event), "epoll_ctl ADD");

    std.debug.print("epoll fd {d} memonitor socket fd {d}\n", .{ epoll_fd, pair[1] });
    _ = try sysWrite(pair[0], "event!");

    var events: [4]linux.epoll_event = undefined;
    const ready_count = try checkCount(linux.epoll_wait(epoll_fd, &events, events.len, 1000), "epoll_wait");
    std.debug.print("epoll_wait() -> {d} event siap\n", .{ready_count});

    for (events[0..ready_count]) |ready| {
        std.debug.print("event: fd {d} siap dibaca, flags=0x{x}\n", .{ ready.data.fd, ready.events });
    }
}

fn simulateOnePersistentUpstreamTo100kConsumers() !void {
    // Official docs:
    // - getrlimit(2): https://man7.org/linux/man-pages/man2/getrlimit.2.html
    // - /proc/<pid>/limits: https://man7.org/linux/man-pages/man5/proc_pid_limits.5.html
    // - epoll(7): https://man7.org/linux/man-pages/man7/epoll.7.html
    // - socket(7): https://man7.org/linux/man-pages/man7/socket.7.html
    //
    // Simulasi ini menjawab pertanyaan:
    // "Kalau ada 1 koneksi persistent ke upstream, bisa tidak melayani 100k consumer?"
    //
    // Jawaban pendek:
    // - Bisa secara arsitektur event loop.
    // - Tapi 100k consumer tetap berarti kira-kira 100k connected socket fd.
    // - Jadi kita cek dulu RLIMIT_NOFILE, lalu buat miniatur epoll dengan 8 consumer.
    std.debug.print("\n== 8. Simulasi 1 koneksi persistent -> 100k consumer ==\n", .{});

    const target_consumers: u64 = 100_000;
    const upstream_connection: u64 = 1;
    const listen_socket: u64 = 1;
    const epoll_instance: u64 = 1;
    const stdio_fds: u64 = 3;
    const safety_margin: u64 = 32;

    // Ini model gateway/pubsub:
    // - 1 koneksi persistent ke upstream/source data.
    // - 100k consumer/client yang masing-masing punya koneksi TCP/WebSocket sendiri.
    // Jadi "1 persistent connection menghidupi 100k consumer" mungkin secara aplikasi,
    // tapi di level Linux tetap ada 100k connected socket fd untuk consumer.
    const fd_needed =
        upstream_connection +
        target_consumers +
        listen_socket +
        epoll_instance +
        stdio_fds +
        safety_margin;

    const limit = try sysGetNoFileLimit();
    std.debug.print(
        \\Target consumer persistent : {d}
        \\Perkiraan fd minimal       : {d}
        \\RLIMIT_NOFILE soft/hard    : {d}/{d}
        \\
    , .{ target_consumers, fd_needed, limit.cur, limit.max });

    if (limit.cur >= fd_needed) {
        std.debug.print("Secara limit fd process: mungkin, karena soft limit cukup.\n", .{});
    } else {
        std.debug.print(
            \\Secara limit fd process: belum mungkin di setting sekarang.
            \\Naikkan limit dulu, misalnya konsepnya:
            \\  ulimit -n 200000
            \\atau konfigurasi systemd LimitNOFILE=200000 untuk service.
            \\
        , .{});
    }

    std.debug.print(
        \\Tapi fd bukan satu-satunya biaya.
        \\100k koneksi juga butuh memory kernel untuk socket object, TCP state,
        \\send buffer, receive buffer, plus memory aplikasi untuk state tiap consumer.
        \\
    , .{});

    // Kita tidak membuka 100k koneksi sungguhan di demo default karena bisa menghabiskan
    // fd/memory laptop. Sebagai gantinya, ini miniatur 8 consumer:
    // setiap "consumer" punya satu fd sisi server yang didaftarkan ke epoll.
    const sample_consumers = 8;
    var pairs: [sample_consumers][2]i32 = undefined;
    var opened: usize = 0;
    defer {
        var i: usize = 0;
        while (i < opened) : (i += 1) {
            sysClose(pairs[i][0]);
            sysClose(pairs[i][1]);
        }
    }

    const epoll_fd = try checkFd(linux.epoll_create1(linux.EPOLL.CLOEXEC), "epoll_create1");
    defer sysClose(epoll_fd);

    for (&pairs, 0..) |*pair, i| {
        try checkNoValue(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, pair), "socketpair");
        opened += 1;

        // Anggap pair[0] adalah sisi client/consumer, pair[1] adalah sisi server.
        // Server mendaftarkan fd consumer ke epoll supaya tidak perlu 1 thread per consumer.
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = pair[1] },
        };
        try checkNoValue(linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, pair[1], &event), "epoll_ctl ADD consumer");

        if (i == 1 or i == 5) {
            _ = try sysWrite(pair[0], "consumer punya data");
        }
    }

    var events: [sample_consumers]linux.epoll_event = undefined;
    const ready_count = try checkCount(linux.epoll_wait(epoll_fd, &events, events.len, 100), "epoll_wait consumers");

    std.debug.print(
        \\Miniatur: {d} consumer fd didaftarkan ke epoll.
        \\Hanya 2 consumer mengirim data, epoll melaporkan {d} fd siap.
        \\
    , .{ sample_consumers, ready_count });

    for (events[0..ready_count]) |ready| {
        std.debug.print("consumer server-fd {d} siap dibaca\n", .{ready.data.fd});
    }

    std.debug.print(
        \\Kesimpulan:
        \\- 100k persistent consumer memungkinkan secara arsitektur event loop.
        \\- Syaratnya fd limit, memory, kernel/network tuning, dan backpressure benar.
        \\- Yang tidak benar: 1 TCP socket fd langsung mewakili 100k client independen.
        \\
    , .{});
}

fn printKnownFdLinks(start: i32, end_exclusive: i32) !void {
    var fd = start;
    while (fd < end_exclusive) : (fd += 1) {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "/proc/self/fd/{d}", .{fd});

        // Siapkan buffer kosong ukuran 64 byte.
        // Tulis teks "/proc/self/fd/<angka fd>" ke buffer itu.
        // Pastikan hasil akhirnya null-terminated.

        // Kenapa harus begitu?

        // > Karena syscall Linux ini:
        // linux.readlink(path.ptr, &link_buf, link_buf.len);
        // butuh path gaya C, yaitu string yang diakhiri byte 0, alias null-terminated string.

        // > bufPrintZ huruf Z-nya penting: dia menghasilkan string dengan penutup \0.
        // Kalau fd = 4, kira-kira hasilnya begini:
        //      path_buf = "/proc/self/fd/4\0..."
        //      path = "/proc/self/fd/4"

        // Lalu readlink() membaca symlink itu:
        //      /proc/self/fd/4 -> socket:[98437]

        var link_buf: [256]u8 = undefined;
        const rc = linux.readlink(path.ptr, &link_buf, link_buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => std.debug.print("fd {d} -> {s}\n", .{ fd, link_buf[0..rc] }),
            .NOENT, .BADF => {},
            else => |err| std.debug.print("fd {d} -> readlink gagal: {s}\n", .{ fd, @tagName(err) }),
        }
    }
}

fn ipv4Address(a: u8, b: u8, c: u8, d: u8, port: u16) linux.sockaddr.in {
    const addr_native: u32 =
        (@as(u32, a) << 24) |
        (@as(u32, b) << 16) |
        (@as(u32, c) << 8) |
        @as(u32, d);

    return .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, addr_native),
    };
}

fn sysOpenReadOnly(path: [*:0]const u8) !i32 {
    return checkFd(linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0), "openat");
}

fn sysSocket(domain: u32, socket_type: u32, protocol: u32) !i32 {
    return checkFd(linux.socket(domain, socket_type | linux.SOCK.CLOEXEC, protocol), "socket");
}

fn sysBind(fd: i32, addr: *const linux.sockaddr.in) !void {
    const generic: *const linux.sockaddr = @ptrCast(addr);
    try checkNoValue(linux.bind(fd, generic, @sizeOf(linux.sockaddr.in)), "bind");
}

fn sysListen(fd: i32, backlog: u32) !void {
    try checkNoValue(linux.listen(fd, backlog), "listen");
}

fn sysConnect(fd: i32, addr: *const linux.sockaddr.in) !void {
    try checkNoValue(linux.connect(fd, addr, @sizeOf(linux.sockaddr.in)), "connect");
}

fn sysAccept(fd: i32) !i32 {
    return checkFd(linux.accept4(fd, null, null, linux.SOCK.CLOEXEC), "accept4");
}

fn sysGetSockName(fd: i32) !linux.sockaddr.in {
    var addr: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const generic: *linux.sockaddr = @ptrCast(&addr);
    try checkNoValue(linux.getsockname(fd, generic, &len), "getsockname");
    return addr;
}

fn sysRead(fd: i32, buf: []u8) !usize {
    return checkCount(linux.read(fd, buf.ptr, buf.len), "read");
}

fn sysWrite(fd: i32, bytes: []const u8) !usize {
    return checkCount(linux.write(fd, bytes.ptr, bytes.len), "write");
}

fn sysClose(fd: i32) void {
    _ = linux.close(fd);
}

fn setNonBlocking(fd: i32) !void {
    const flags_rc = linux.fcntl(fd, linux.F.GETFL, 0);
    const flags = try checkCount(flags_rc, "fcntl F_GETFL");
    const nonblock = @as(usize, 1) << @bitOffsetOf(linux.O, "NONBLOCK");
    try checkNoValue(linux.fcntl(fd, linux.F.SETFL, flags | nonblock), "fcntl F_SETFL O_NONBLOCK");
}

fn sysGetNoFileLimit() !linux.rlimit {
    var limit: linux.rlimit = undefined;
    try checkNoValue(linux.getrlimit(.NOFILE, &limit), "getrlimit RLIMIT_NOFILE");
    return limit;
}

fn checkFd(rc: usize, op: []const u8) !i32 {
    const err = linux.errno(rc);
    if (err != .SUCCESS) {
        std.debug.print("{s} gagal: errno {s}\n", .{ op, @tagName(err) });
        return DemoError.SyscallFailed;
    }
    return @intCast(rc);
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
