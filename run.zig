//! run — a small Linux/KVM monitor.
//!
//!   zig build -Doptimize=ReleaseSmall
//!   ./zig-out/bin/run --disk root.img bzImage
//!
//! SMP · virtio-mmio blk/net · private COW disks · disk checkpoints
//! in-kernel irqchip · UART · ACPI MADT · vCPU seccomp · local HTTP
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const IOCTL = linux.IOCTL;

comptime {
    if (builtin.os.tag != .linux) @compileError("run: Linux/KVM only");
    if (builtin.cpu.arch != .x86_64) @compileError("run: x86_64 only");
}

const KVMIO = 0xAE;
const MAX_VM = 8;
const MAX_CPU = 8;
const RAM_MAX = 3 << 30;
const BLK_BASE: u64 = 0xd0000000;
const NET_BASE: u64 = 0xd0001000;
const PAGE = 4096;

fn io(fd: i32, req: u32, arg: usize) !void {
    _ = try ior(fd, req, arg);
}
fn ior(fd: i32, req: u32, arg: usize) !usize {
    const rc = linux.ioctl(fd, req, arg);
    if (linux.errno(rc) != .SUCCESS) return error.Ioctl;
    return rc;
}
fn sys(rc: usize) !usize {
    if (linux.errno(rc) != .SUCCESS) return error.Sys;
    return rc;
}
fn fdopen(path: [*:0]const u8, flags: linux.O) !i32 {
    return @intCast(try sys(linux.open(path, flags, 0o644)));
}
fn wr(fd: i32, b: []const u8) void {
    writeAll(fd, b) catch {};
}
fn writeAll(fd: i32, b: []const u8) !void {
    var rest = b;
    while (rest.len != 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        if (linux.errno(rc) == .INTR) continue;
        const n = try sys(rc);
        if (n == 0) return error.ShortWrite;
        rest = rest[n..];
    }
}
fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    wr(2, std.fmt.bufPrint(&buf, fmt, args) catch return);
}
fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.NoKvm => "Linux x86-64 with /dev/kvm access is required",
        error.Ioctl => "KVM ioctl failed",
        error.Sys => "system call failed",
        error.NotKernel, error.OldKernel => "expected a 64-bit bzImage, boot protocol >= 2.12",
        error.Ram, error.BootConfig, error.VmConfig => "invalid CPU, memory or kernel configuration",
        error.OutOfMemory => "out of memory",
        error.Down => "VM is stopped",
        error.Policy => "invalid network grant; use tcp|udp|icmp:IPv4/prefix:port (0 means any port)",
        else => "operation failed",
    };
}
fn rd(fd: i32, b: []u8) !usize {
    const rc = linux.read(fd, b.ptr, b.len);
    if (linux.errno(rc) == .AGAIN) return 0;
    return sys(rc);
}
fn mmapAnon(n: usize) ![]align(PAGE) u8 {
    const rc = linux.mmap(null, n, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Mmap;
    return @as([*]align(PAGE) u8, @ptrFromInt(rc))[0..n];
}
fn mmapFile(path: [*:0]const u8) ![]align(PAGE) u8 {
    const f = try fdopen(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer _ = linux.close(f);
    var st: linux.Statx = undefined;
    _ = try sys(linux.statx(f, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st));
    const n: usize = @intCast(st.size);
    const rc = linux.mmap(null, n, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE }, f, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Mmap;
    return @as([*]align(PAGE) u8, @ptrFromInt(rc))[0..n];
}
fn le(comptime T: type, p: []const u8) T {
    return std.mem.readInt(T, p[0..@sizeOf(T)], .little);
}
fn wle(comptime T: type, p: []u8, v: T) void {
    std.mem.writeInt(T, p[0..@sizeOf(T)], v, .little);
}

// Device exits are serialized per VM; vCPUs execute guest code concurrently.
const Spin = struct {
    v: std.atomic.Value(bool) = .init(false),
    fn lock(s: *Spin) void {
        while (s.v.swap(true, .acquire)) _ = linux.sched_yield();
    }
    fn unlock(s: *Spin) void {
        s.v.store(false, .release);
    }
};

// ── KVM ABI ────────────────────────────────────────────────────────────────
const MemSlot = extern struct { slot: u32, flags: u32, gpa: u64, len: u64, hva: u64 };
const IrqLevel = extern struct { irq: u32, level: u32 };
const PitCfg = extern struct { flags: u32, pad: [15]u32 = @splat(0) };
const MpState = extern struct { state: u32 };
const EnableCap = extern struct { cap: u32, flags: u32 = 0, args: [4]u64 = @splat(0), pad: [64]u8 = @splat(0) };
const Cpuid = extern struct { nent: u32, pad: u32 = 0 };
const CpuidEnt = extern struct { func: u32, idx: u32, flags: u32, eax: u32, ebx: u32, ecx: u32, edx: u32, pad: [3]u32 = @splat(0) };
const Seg = extern struct { base: u64, limit: u32, selector: u16, type: u8, present: u8, dpl: u8, db: u8, s: u8, l: u8, g: u8, avl: u8, unusable: u8, pad: u8 };
const Dtable = extern struct { base: u64, limit: u16, pad: [3]u16 = @splat(0) };
const Sregs = extern struct {
    cs: Seg,
    ds: Seg,
    es: Seg,
    fs: Seg,
    gs: Seg,
    ss: Seg,
    tr: Seg,
    ldt: Seg,
    gdt: Dtable,
    idt: Dtable,
    cr0: u64,
    cr2: u64,
    cr3: u64,
    cr4: u64,
    cr8: u64,
    efer: u64,
    apic_base: u64,
    irq_bitmap: [4]u64 = @splat(0),
};
const Regs = extern struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    rsp: u64 = 0,
    rbp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    rflags: u64 = 2,
};
const Run = extern struct {
    req_irq_win: u8 = 0,
    immediate_exit: u8 = 0,
    pad1: [6]u8 = @splat(0),
    exit_reason: u32 = 0,
    ready_irq: u8 = 0,
    if_flag: u8 = 0,
    flags: u16 = 0,
    cr8: u64 = 0,
    apic_base: u64 = 0,
    un: extern union {
        io: extern struct { dir: u8, size: u8, port: u16, count: u32, data_off: u64 },
        mmio: extern struct { phys: u64, data: [8]u8, len: u32, is_write: u8 },
        sys: extern struct { type: u32, ndata: u32, data: [16]u64 },
        pad: [256]u8,
    } = undefined,
};

comptime {
    if (@offsetOf(Run, "exit_reason") != 8) @compileError("kvm_run.exit_reason");
    if (@offsetOf(Run, "un") != 32) @compileError("kvm_run.union");
    if (@sizeOf(Regs) != 18 * 8) @compileError("kvm_regs");
    if (@sizeOf(MemSlot) != 32) @compileError("kvm_userspace_memory_region");
}

const KVM_GET_API_VERSION = IOCTL.IO(KVMIO, 0x00);
const KVM_CREATE_VM = IOCTL.IO(KVMIO, 0x01);
const KVM_CHECK_EXTENSION = IOCTL.IO(KVMIO, 0x03);
const KVM_GET_VCPU_MMAP_SIZE = IOCTL.IO(KVMIO, 0x04);
const KVM_GET_SUPPORTED_CPUID = IOCTL.IOWR(KVMIO, 0x05, Cpuid);
const KVM_SET_USER_MEMORY_REGION = IOCTL.IOW(KVMIO, 0x46, MemSlot);
const KVM_SET_TSS_ADDR = IOCTL.IO(KVMIO, 0x47);
const KVM_SET_IDENTITY_MAP_ADDR = IOCTL.IOW(KVMIO, 0x48, u64);
const KVM_CREATE_VCPU = IOCTL.IO(KVMIO, 0x41);
const KVM_CREATE_IRQCHIP = IOCTL.IO(KVMIO, 0x60);
const KVM_IRQ_LINE = IOCTL.IOW(KVMIO, 0x61, IrqLevel);
const KVM_CREATE_PIT2 = IOCTL.IOW(KVMIO, 0x77, PitCfg);
const KVM_RUN = IOCTL.IO(KVMIO, 0x80);
const KVM_SET_REGS = IOCTL.IOW(KVMIO, 0x82, Regs);
const KVM_GET_SREGS = IOCTL.IOR(KVMIO, 0x83, Sregs);
const KVM_SET_SREGS = IOCTL.IOW(KVMIO, 0x84, Sregs);
const KVM_SET_CPUID2 = IOCTL.IOW(KVMIO, 0x90, Cpuid);
const KVM_SET_MP_STATE = IOCTL.IOW(KVMIO, 0x99, MpState);
const KVM_ENABLE_CAP = IOCTL.IOW(KVMIO, 0xa3, EnableCap);
const KVM_CAP_IRQCHIP = 0;
const KVM_CAP_X86_DISABLE_EXITS = 180;
const KVM_CAP_IMMEDIATE_EXIT = 136;
const EXIT_IO = 2;
const EXIT_HLT = 5;
const EXIT_MMIO = 6;
const EXIT_SHUTDOWN = 8;
const EXIT_INTR = 10;
const EXIT_INTERNAL = 17;
const EXIT_SYSTEM = 24;

// ── COW disk ───────────────────────────────────────────────────────────────
const Cow = struct {
    gpa: std.mem.Allocator,
    base: []u8 = &.{},
    dirty: []u8 = &.{},
    gen: u32 = 0,

    fn init(gpa: std.mem.Allocator, path: ?[:0]const u8) !Cow {
        var c: Cow = .{ .gpa = gpa };
        if (path) |p| c.base = try mmapFile(p);
        errdefer if (c.base.len != 0) {
            _ = linux.munmap(c.base.ptr, c.base.len);
        };
        if (c.base.len % 512 != 0 or c.base.len > @as(u64, 1) << 44) return error.DiskSize;
        c.dirty = try gpa.alloc(u8, (std.mem.alignForward(usize, c.base.len, PAGE) / PAGE + 7) / 8);
        @memset(c.dirty, 0);
        return c;
    }
    fn deinit(c: *Cow) void {
        if (c.base.len != 0) _ = linux.munmap(c.base.ptr, c.base.len);
        c.gpa.free(c.dirty);
        c.base = &.{};
        c.dirty = &.{};
    }
    fn size(c: Cow) u64 {
        return c.base.len;
    }
    fn rw(c: *Cow, off: u64, buf: []u8, write: bool) !void {
        if (off > c.base.len or buf.len > c.base.len - off) return error.DiskRange;
        const dst = c.base[@intCast(off)..][0..buf.len];
        if (!write) {
            @memcpy(buf, dst);
            return;
        }
        @memcpy(dst, buf); // MAP_PRIVATE: the kernel owns the copy-on-write pages.
        if (buf.len == 0) return;
        for (off / PAGE..(off + buf.len - 1) / PAGE + 1) |p| c.dirty[p / 8] |= @as(u8, 1) << @intCast(p % 8);
    }
    fn snap(c: *Cow, path: [*:0]const u8) !void {
        const f = try fdopen(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true });
        defer _ = linux.close(f);
        errdefer _ = linux.unlink(path);
        var hdr: [16]u8 = @splat(0);
        @memcpy(hdr[0..8], "RUNCOW\x00\x00");
        var count: u32 = 0;
        for (c.dirty) |byte| count += @popCount(byte);
        wle(u32, hdr[8..12], count);
        wle(u32, hdr[12..16], c.gen);
        try writeAll(f, &hdr);
        for (0..std.mem.alignForward(usize, c.base.len, PAGE) / PAGE) |p| {
            if (c.dirty[p / 8] & (@as(u8, 1) << @intCast(p % 8)) == 0) continue;
            var record: [4 + PAGE]u8 = @splat(0);
            wle(u32, &record, @intCast(p));
            const n = @min(PAGE, c.base.len - p * PAGE);
            @memcpy(record[4..][0..n], c.base[p * PAGE ..][0..n]);
            try writeAll(f, &record);
        }
        _ = try sys(linux.fsync(f));
        c.gen +%= 1;
    }
    fn restore(c: *Cow, data: []const u8) !void {
        if (data.len < 16 or !std.mem.eql(u8, data[0..8], "RUNCOW\x00\x00")) return error.Checkpoint;
        const count = le(u32, data[8..12]);
        if (data.len != 16 + @as(u64, count) * (4 + PAGE)) return error.Checkpoint;
        for (0..count) |i| {
            const p = le(u32, data[16 + i * (4 + PAGE) ..]);
            if (@as(u64, p) * PAGE >= c.base.len) return error.Checkpoint;
        }
        for (0..count) |i| {
            const record = data[16 + i * (4 + PAGE) ..][0 .. 4 + PAGE];
            const p = le(u32, record);
            const off = @as(usize, p) * PAGE;
            const n = @min(PAGE, c.base.len - off);
            @memcpy(c.base[off..][0..n], record[4..][0..n]);
            c.dirty[p / 8] |= @as(u8, 1) << @intCast(p % 8);
        }
        c.gen = le(u32, data[12..16]) +% 1;
    }
};

// ── virtio ─────────────────────────────────────────────────────────────────
const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };
const Vq = struct { num: u16 = 0, ready: u32 = 0, desc: u64 = 0, avail: u64 = 0, used: u64 = 0, last: u16 = 0 };
const Kind = enum { blk, net };
const Vdev = struct {
    kind: Kind,
    base: u64,
    irq: u32,
    feat_sel: u32 = 0,
    drv_sel: u32 = 0,
    drv_feat: u64 = 0,
    qsel: u32 = 0,
    status: u32 = 0,
    isr: u32 = 0,
    q: [2]Vq = .{ .{}, .{} },
};

fn hostFeat(k: Kind) u64 {
    const v1: u64 = 1 << 32;
    return v1 | switch (k) {
        .blk => @as(u64, (1 << 1) | (1 << 2)),
        .net => @as(u64, 1 << 5),
    };
}

fn gp(vm: *Vm, addr: u64, n: usize) ![]u8 {
    if (n == 0) return &.{};
    if (addr > vm.ram.len or vm.ram.len - addr < n) return error.Gpa;
    return vm.ram[@intCast(addr)..][0..n];
}

fn walk(vm: *Vm, q: *Vq, head: u16, iov: *[64][]u8, writable: *u64) !usize {
    writable.* = 0;
    var n: usize = 0;
    var idx = head;
    const table = try gp(vm, q.desc, @as(usize, q.num) * @sizeOf(Desc));
    while (true) {
        if (idx >= q.num or n >= iov.len) return error.Vq;
        const raw = table[@as(usize, idx) * 16 ..][0..16];
        const d = std.mem.bytesAsValue(Desc, raw).*;
        if (d.flags & ~@as(u16, 3) != 0) return error.Vq;
        iov[n] = try gp(vm, d.addr, d.len);
        if (d.flags & 2 != 0) writable.* |= @as(u64, 1) << @intCast(n);
        n += 1;
        if (d.flags & 1 == 0) break;
        idx = d.next;
    }
    return n;
}

fn used(vm: *Vm, q: *Vq, id: u16, len: u32) !void {
    const used_mem = try gp(vm, q.used, 4 + @as(usize, q.num) * 8);
    const uidx = le(u16, used_mem[2..4]);
    const slot = 4 + @as(usize, uidx % q.num) * 8;
    wle(u32, used_mem[slot..][0..4], id);
    wle(u32, used_mem[slot + 4 ..][0..4], len);
    @atomicStore(u16, @as(*u16, @ptrCast(@alignCast(used_mem[2..4].ptr))), uidx +% 1, .release);
    q.last +%= 1;
}

fn kick(vm: *Vm, d: *Vdev, qn: u32) !void {
    if (qn >= (if (d.kind == .blk) @as(u32, 1) else 2) or d.status & 0x8c != 0x0c) return error.Vq;
    const q = &d.q[qn];
    if (q.ready == 0 or q.num == 0) return;
    const avail = try gp(vm, q.avail, 4 + @as(usize, q.num) * 2);
    const aidx = @atomicLoad(u16, @as(*u16, @ptrCast(@alignCast(avail[2..4].ptr))), .acquire);
    if (aidx -% q.last > q.num) return error.Vq;
    while (q.last != aidx) {
        const head = le(u16, avail[4 + @as(usize, q.last % q.num) * 2 ..][0..2]);
        var iov_buf: [64][]u8 = undefined;
        var writable: u64 = 0;
        const ni = try walk(vm, q, head, &iov_buf, &writable);
        const iov = iov_buf[0..ni];
        var wrote: u32 = 0;
        switch (d.kind) {
            .blk => wrote = try doBlk(vm, iov, writable),
            .net => if (qn == 1) {
                if (writable != 0) return error.Vq;
                wrote = try doTx(vm, iov);
            } else break,
        }
        try used(vm, q, head, wrote);
    }
    d.isr |= 1;
    line(vm, d.irq, true);
}

fn gather(iov: []const []u8, dst: []u8) usize {
    var n: usize = 0;
    for (iov) |s| {
        if (n >= dst.len) break;
        const m = @min(s.len, dst.len - n);
        @memcpy(dst[n..][0..m], s[0..m]);
        n += m;
    }
    return n;
}
fn scatter(iov: []const []u8, src: []const u8) usize {
    var n: usize = 0;
    for (iov) |s| {
        if (n >= src.len) break;
        const m = @min(s.len, src.len - n);
        @memcpy(s[0..m], src[n..][0..m]);
        n += m;
    }
    return n;
}

fn doBlk(vm: *Vm, iov: [][]u8, writable: u64) !u32 {
    if (iov.len < 2 or iov[0].len != 16 or iov[iov.len - 1].len != 1) return error.Vq;
    const hdr = iov[0];
    const typ = le(u32, hdr[0..4]);
    const sector = le(u64, hdr[8..16]);
    const status_bit = @as(u64, 1) << @intCast(iov.len - 1);
    const expected = (if (typ == 0) (status_bit - 1) & ~@as(u64, 1) else @as(u64, 0)) | status_bit;
    if (writable != expected) return error.Vq;
    const status = iov[iov.len - 1];
    const data = iov[1 .. iov.len - 1];
    var total: usize = 0;
    for (data) |s| total += s.len;
    status[0] = 2; // UNSUPP
    if (typ > 1) return 1;
    status[0] = 1; // IOERR
    if (sector > vm.cow.size() / 512 or total % 512 != 0) return 1;
    for (data) |s| if (s.len > 65536) return 1;
    var off = sector * 512;
    if (total > vm.cow.size() - off) return 1;
    for (data) |s| {
        vm.cow.rw(off, s, typ == 1) catch return 1;
        off += s.len;
    }
    status[0] = 0;
    return @intCast(1 + if (typ == 0) total else 0);
}

fn doTx(vm: *Vm, iov: [][]u8) !u32 {
    var pkt: [2048]u8 = undefined;
    var total: usize = 0;
    for (iov) |s| total += s.len;
    if (total < 12 or total > pkt.len) return error.Vq;
    const n = gather(iov, &pkt);
    if (n > 12 and vm.tap >= 0) {
        if (vm.policy.permits(pkt[12..n], vm.id, vm.mac)) wr(vm.tap, pkt[12..n]) else vm.denied +%= 1;
    }
    return 0;
}

fn rx(vm: *Vm, pkt: []const u8) void {
    const d = &vm.net;
    const q = &d.q[0];
    if (q.ready == 0 or q.num == 0) return;
    const avail = gp(vm, q.avail, 4 + @as(usize, q.num) * 2) catch return;
    const aidx = @atomicLoad(u16, @as(*u16, @ptrCast(@alignCast(avail[2..4].ptr))), .acquire);
    if (q.last == aidx or aidx -% q.last > q.num or d.status & 4 == 0) return;
    const head = le(u16, avail[4 + @as(usize, q.last % q.num) * 2 ..][0..2]);
    var iov_buf: [64][]u8 = undefined;
    var writable: u64 = 0;
    const ni = walk(vm, q, head, &iov_buf, &writable) catch return;
    if (writable != @as(u64, std.math.maxInt(u64)) >> @intCast(64 - ni)) return;
    var frame: [2060]u8 = @splat(0);
    @memcpy(frame[12..][0..@min(pkt.len, frame.len - 12)], pkt[0..@min(pkt.len, frame.len - 12)]);
    const n = 12 + @min(pkt.len, frame.len - 12);
    var capacity: usize = 0;
    for (iov_buf[0..ni]) |s| capacity += s.len;
    if (capacity < n) return;
    const copied = scatter(iov_buf[0..ni], frame[0..n]);
    used(vm, q, head, @intCast(copied)) catch return;
    d.isr |= 1;
    line(vm, d.irq, true);
}

fn mmio(vm: *Vm, d: *Vdev, off: u64, data: []u8, write: bool) void {
    if (data.len != 1 and data.len != 2 and data.len != 4 and data.len != 8) return;
    const valid = d.qsel < (if (d.kind == .blk) @as(u32, 1) else 2);
    var unused: Vq = .{};
    const q = if (valid) &d.q[d.qsel] else &unused;
    if (write and q.ready != 0 and off >= 0x80 and off <= 0xa4) return;
    if (!write) {
        const v: u64 = switch (off) {
            0x00 => 0x74726976,
            0x04 => 2,
            0x08 => if (d.kind == .blk) (if (vm.cow.size() != 0) @as(u32, 2) else 0) else (if (vm.tap >= 0) @as(u32, 1) else 0),
            0x0c => 0x4d434c44,
            0x10 => if (d.feat_sel < 2) @as(u32, @truncate(hostFeat(d.kind) >> @as(u6, @intCast(d.feat_sel * 32)))) else 0,
            0x34 => if (valid) 256 else 0,
            0x44 => q.ready,
            0x60 => d.isr,
            0x70 => d.status,
            0xfc => 0,
            else => blk: {
                if (off >= 0x100) break :blk cfg(vm, d, off - 0x100);
                break :blk 0;
            },
        };
        const n = @min(data.len, 8);
        @memcpy(data[0..n], std.mem.asBytes(&v)[0..n]);
        return;
    }
    const val: u64 = switch (data.len) {
        1 => data[0],
        2 => le(u16, data[0..2]),
        4 => le(u32, data[0..4]),
        else => le(u64, data[0..@min(8, data.len)]),
    };
    switch (off) {
        0x14 => d.feat_sel = @truncate(val),
        0x20 => {
            if (d.drv_sel == 0) d.drv_feat = (d.drv_feat & ~@as(u64, 0xffffffff)) | val else if (d.drv_sel == 1) d.drv_feat = (d.drv_feat & 0xffffffff) | (val << 32);
        },
        0x24 => d.drv_sel = @truncate(val),
        0x30 => d.qsel = @truncate(val),
        0x38 => if (q.ready == 0) {
            q.num = if (val > 0 and val <= 256 and std.math.isPowerOfTwo(val)) @intCast(val) else 0;
        },
        0x44 => q.ready = if (val == 1 and q.num != 0 and q.desc % 16 == 0 and q.avail % 2 == 0 and q.used % 4 == 0) 1 else 0,
        0x50 => kick(vm, d, @truncate(val)) catch {
            d.status |= 128;
        },
        0x64 => {
            d.isr &= ~@as(u32, @truncate(val));
            if (d.isr == 0) line(vm, d.irq, false);
        },
        0x70 => {
            d.status = @truncate(val);
            if (d.status & 8 != 0 and (d.drv_feat & ~hostFeat(d.kind) != 0 or d.drv_feat & (@as(u64, 1) << 32) == 0)) d.status &= ~@as(u32, 8);
            if (d.status == 0) {
                line(vm, d.irq, false);
                d.* = .{ .kind = d.kind, .base = d.base, .irq = d.irq };
            }
        },
        0x80 => q.desc = (q.desc & ~@as(u64, 0xffffffff)) | val,
        0x84 => q.desc = (q.desc & 0xffffffff) | (val << 32),
        0x90 => q.avail = (q.avail & ~@as(u64, 0xffffffff)) | val,
        0x94 => q.avail = (q.avail & 0xffffffff) | (val << 32),
        0xa0 => q.used = (q.used & ~@as(u64, 0xffffffff)) | val,
        0xa4 => q.used = (q.used & 0xffffffff) | (val << 32),
        else => {},
    }
}

fn cfg(vm: *Vm, d: *Vdev, off: u64) u64 {
    return switch (d.kind) {
        .blk => blk: {
            var bytes: [24]u8 = @splat(0);
            wle(u64, &bytes, vm.cow.size() / 512);
            wle(u32, bytes[8..], 65536);
            wle(u32, bytes[12..], 62);
            break :blk if (off < 16) le(u64, bytes[@intCast(off)..]) else 0;
        },
        .net => if (off < 6) le(u64, &(vm.mac ++ [_]u8{ 0, 0 })) >> @as(u6, @intCast(off * 8)) else 0,
    };
}

// ── UART ───────────────────────────────────────────────────────────────────
const Uart = struct {
    ier: u8 = 0,
    lcr: u8 = 0,
    mcr: u8 = 0,
    dll: u8 = 1,
    dlm: u8 = 0,
    rx: [256]u8 = undefined,
    r: u8 = 0,
    w: u8 = 0,
    cons: []u8 = &.{},
    clen: usize = 0,
    tx_pending: bool = false,
    scratch: u8 = 0,

    fn irq(u: *Uart) u8 {
        return if (u.ier & 1 != 0 and u.r != u.w) 4 else if (u.ier & 2 != 0 and u.tx_pending) 2 else 1;
    }

    fn put(u: *Uart, c: u8) void {
        u.rx[u.w] = c;
        u.w +%= 1;
    }
    fn pop(u: *Uart) u8 {
        if (u.r == u.w) return 0;
        const c = u.rx[u.r];
        u.r +%= 1;
        return c;
    }
    fn io(u: *Uart, port: u16, data: []u8, write: bool, out: i32) void {
        const p = port - 0x3f8;
        if (write) {
            const v = data[0];
            switch (p) {
                0 => if (u.lcr & 0x80 != 0) {
                    u.dll = v;
                } else {
                    wr(out, data[0..1]);
                    u.tx_pending = true;
                    if (u.cons.len != 0) {
                        u.cons[u.clen % u.cons.len] = v;
                        u.clen += 1;
                    }
                },
                1 => {
                    if (u.lcr & 0x80 != 0) u.dlm = v else {
                        u.ier = v & 15;
                        u.tx_pending = true;
                    }
                },
                3 => u.lcr = v,
                4 => u.mcr = v,
                7 => u.scratch = v,
                else => {},
            }
        } else {
            data[0] = switch (p) {
                0 => if (u.lcr & 0x80 != 0) u.dll else u.pop(),
                1 => if (u.lcr & 0x80 != 0) u.dlm else u.ier,
                2 => u.irq(),
                3 => u.lcr,
                4 => u.mcr,
                5 => 0x60 | @as(u8, if (u.r != u.w) 1 else 0),
                6 => if (u.mcr & 16 != 0) ((u.mcr & 1) << 5) | ((u.mcr & 2) << 3) | ((u.mcr & 12) << 4) else 0xb0,
                7 => u.scratch,
                else => 0,
            };
            if (p == 2 and data[0] == 2) u.tx_pending = false;
        }
    }
};

fn line(vm: *Vm, gsi: u32, on: bool) void {
    var l = IrqLevel{ .irq = gsi, .level = @intFromBool(on) };
    _ = linux.ioctl(vm.fd, KVM_IRQ_LINE, @intFromPtr(&l));
}

// ── ACPI + Linux boot ──────────────────────────────────────────────────────
fn csum(b: []u8, off: usize) void {
    b[off] = 0;
    var s: u8 = 0;
    for (b) |x| s -%= x;
    b[off] = s;
}

fn acpiHdr(dst: []u8, sig: *const [4]u8, len: u32, rev: u8) void {
    @memcpy(dst[0..4], sig);
    wle(u32, dst[4..8], len);
    dst[8] = rev;
    @memcpy(dst[10..16], "RUN   ");
    @memcpy(dst[16..24], "RUN     ");
    wle(u32, dst[24..28], 1);
    @memcpy(dst[28..32], "RUN ");
    wle(u32, dst[32..36], 1);
}

fn plantAcpi(ram: []u8, ncpu: u32) u64 {
    const base: usize = 0x80000;
    var p = ram[base .. base + 0x4000];
    @memset(p, 0);
    const xsdt_off = 64;
    const fadt_off = 128;
    const madt_off = 128 + 276;
    const madt_len: u32 = 44 + ncpu * 8 + 12 + 10;
    const dsdt_off = madt_off + madt_len;

    const fadt = p[fadt_off..][0..276];
    acpiHdr(fadt, "FACP", 276, 6);
    wle(u32, fadt[40..44], @intCast(base + dsdt_off));
    wle(u16, fadt[109..111], 4 | 8 | 32);
    wle(u32, fadt[112..116], (1 << 10) | (1 << 20));
    wle(u64, fadt[140..148], base + dsdt_off);
    csum(fadt, 9);

    const madt = p[madt_off..][0..madt_len];
    acpiHdr(madt, "APIC", madt_len, 4);
    wle(u32, madt[36..40], 0xfee00000);
    wle(u32, madt[40..44], 1);
    var o: usize = 44;
    var cpu: u32 = 0;
    while (cpu < ncpu) : (cpu += 1) {
        madt[o] = 0;
        madt[o + 1] = 8;
        madt[o + 2] = @truncate(cpu);
        madt[o + 3] = @truncate(cpu);
        wle(u32, madt[o + 4 ..][0..4], 1);
        o += 8;
    }
    madt[o] = 1;
    madt[o + 1] = 12;
    wle(u32, madt[o + 4 ..][0..4], 0xfec00000);
    o += 12;
    madt[o] = 2;
    madt[o + 1] = 10;
    madt[o + 3] = 0;
    wle(u32, madt[o + 4 ..][0..4], 2);
    csum(madt, 9);

    const dsdt = p[dsdt_off..][0..166];
    acpiHdr(dsdt, "DSDT", 166, 2);
    // Scope (\\_SB): two LNRO0005 devices, fixed MMIO and level-high GSI resources.
    @memcpy(dsdt[36..44], "\x10\x41\x08\\_SB_");
    const device = "\x5b\x82\x3bVBLK\x08_HID\x0dLNRO0005\x00\x08_UID\x0a\x00" ++
        "\x08_CRS\x11\x1a\x0a\x17\x86\x09\x00\x01" ++
        "\x00\x00\x00\x00\x00\x10\x00\x00\x89\x06\x00\x01\x01\x00\x00\x00\x00\x79\x00";
    for (0..2) |i| {
        const node = dsdt[44 + i * 61 ..][0..61];
        @memcpy(node, device);
        if (i == 1) @memcpy(node[3..7], "VNET");
        node[28] = @intCast(i);
        wle(u32, node[42..46], @intCast(BLK_BASE + i * PAGE));
        wle(u32, node[55..59], @intCast(5 + i));
    }
    csum(dsdt, 9);

    const xsdt = p[xsdt_off..][0..52];
    acpiHdr(xsdt, "XSDT", 52, 1);
    wle(u64, xsdt[36..44], base + fadt_off);
    wle(u64, xsdt[44..52], base + madt_off);
    csum(xsdt, 9);

    const rsdp = p[0..36];
    @memcpy(rsdp[0..8], "RSD PTR ");
    @memcpy(rsdp[9..15], "RUN   ");
    rsdp[15] = 2;
    wle(u32, rsdp[20..24], 36);
    wle(u64, rsdp[24..32], base + xsdt_off);
    csum(rsdp[0..20], 8);
    csum(rsdp, 32);
    @memcpy(ram[0xe0000..][0..36], rsdp);
    return base;
}

fn e820(bp: []u8, ram: u64, n: *u8, addr: u64, sz: u64, typ: u32) void {
    const e = bp[0x2d0 + @as(usize, n.*) * 20 ..];
    wle(u64, e[0..8], addr);
    wle(u64, e[8..16], sz);
    wle(u32, e[16..20], typ);
    n.* += 1;
    _ = ram;
}

fn loadKernel(ram: []u8, bz: []const u8, initrd: []const u8, cmd: []const u8, ncpu: u32) !u64 {
    if (bz.len < 0x264 or !std.mem.eql(u8, bz[0x202..0x206], "HdrS")) return error.NotKernel;
    const proto = le(u16, bz[0x206..0x208]);
    if (proto < 0x20c or le(u16, bz[0x236..]) & 1 == 0) return error.OldKernel;
    if (ram.len < 16 << 20 or ncpu == 0 or ncpu > MAX_CPU or cmd.len >= 4096 or cmd.len > le(u32, bz[0x238..])) return error.BootConfig;
    const sects: usize = if (bz[0x1F1] == 0) 4 else bz[0x1F1];
    const koff = (sects + 1) * 512;
    if (koff >= bz.len) return error.NotKernel;
    const kern = bz[koff..];
    const load: usize = 0x100000;
    const footprint = @max(kern.len, le(u32, bz[0x260..]));
    if (footprint > ram.len - load) return error.Ram;
    @memcpy(ram[load..][0..kern.len], kern);

    var ird_addr: usize = 0;
    if (initrd.len != 0) {
        const top = @min(ram.len, @as(u64, le(u32, bz[0x22c..])) + 1);
        if (initrd.len > top) return error.Ram;
        ird_addr = std.mem.alignBackward(usize, top - initrd.len, PAGE);
        if (ird_addr < load + footprint) return error.Ram;
        @memcpy(ram[ird_addr..][0..initrd.len], initrd);
    }

    const rsdp = plantAcpi(ram, ncpu);
    const bp = ram[0x20000..][0..0x1000];
    @memset(bp, 0);
    const hend = @min(bz.len, 0x202 + @as(usize, bz[0x201]));
    @memcpy(bp[0x1F1..hend], bz[0x1F1..hend]);
    bp[0x210] = 0xff; // type_of_loader
    bp[0x211] |= 0x80; // CAN_USE_HEAP
    wle(u16, bp[0x224..0x226], 0xfe00);
    wle(u32, bp[0x228..0x22c], 0x21000);
    wle(u64, bp[0x70..0x78], rsdp);
    if (ird_addr != 0) {
        wle(u32, bp[0x218..0x21c], @intCast(ird_addr));
        wle(u32, bp[0x21c..0x220], @intCast(initrd.len));
    }
    @memcpy(ram[0x21000..][0..cmd.len], cmd);
    ram[0x21000 + cmd.len] = 0;

    var nent: u8 = 0;
    e820(bp, ram.len, &nent, 0, 0x80000, 1);
    e820(bp, ram.len, &nent, 0x80000, 0x10000, 3);
    e820(bp, ram.len, &nent, 0x100000, ram.len - 0x100000, 1);
    bp[0x1e8] = nent;
    wle(u32, bp[0x1e0..0x1e4], @intCast((ram.len - (1 << 20)) / 1024));

    // page tables: 2MiB identity of all RAM
    const pml4: usize = 0x1000;
    const pdpt: usize = 0x2000;
    const pd0: usize = 0x3000;
    @memset(ram[0x1000 .. 0x3000 + 16 * PAGE], 0);
    wle(u64, ram[pml4..][0..8], pdpt | 3);
    const gigs = (ram.len + (1 << 30) - 1) / (1 << 30);
    var g: usize = 0;
    while (g < gigs) : (g += 1) {
        const pd = pd0 + g * PAGE;
        wle(u64, ram[pdpt + g * 8 ..][0..8], pd | 3);
        var i: usize = 0;
        while (i < 512) : (i += 1) {
            const pa = g * (1 << 30) + i * (2 << 20);
            if (pa >= ram.len) break;
            wle(u64, ram[pd + i * 8 ..][0..8], pa | 0x83);
        }
    }
    const gdt: usize = 0x10000;
    wle(u64, ram[gdt..][0..8], 0);
    wle(u64, ram[gdt + 8 ..][0..8], 0);
    wle(u64, ram[gdt + 16 ..][0..8], 0x00af9a000000ffff);
    wle(u64, ram[gdt + 24 ..][0..8], 0x00cf92000000ffff);
    return load + 0x200;
}

fn seg(sel: u16, typ: u8, l: u8, db: u8) Seg {
    return .{ .base = 0, .limit = 0xfffff, .selector = sel, .type = typ, .present = 1, .dpl = 0, .db = db, .s = 1, .l = l, .g = 1, .avl = 0, .unusable = 0, .pad = 0 };
}

// Outbound IPv4 grants. No VLAN, IPv6, fragments or spoofed sources cross TAP.
const Policy = struct {
    const Rule = struct { address: u32, mask: u32, port: u16, protocol: u8 };
    rules: [16]Rule = undefined,
    count: usize = 0,

    fn ipv4(text: []const u8) !u32 {
        var parts = std.mem.splitScalar(u8, text, '.');
        var address: u32 = 0;
        for (0..4) |_| address = (address << 8) | try std.fmt.parseInt(u8, parts.next() orelse return error.Policy, 10);
        if (parts.next() != null) return error.Policy;
        return address;
    }
    fn parse(text: []const u8) !Policy {
        var p: Policy = .{};
        if (text.len == 0) return p;
        var entries = std.mem.splitScalar(u8, text, ',');
        while (entries.next()) |entry| {
            if (p.count == p.rules.len) return error.Policy;
            var fields = std.mem.splitScalar(u8, entry, ':');
            const proto = fields.next() orelse return error.Policy;
            var cidr = std.mem.splitScalar(u8, fields.next() orelse return error.Policy, '/');
            const address = try ipv4(cidr.next() orelse return error.Policy);
            const bits = try std.fmt.parseInt(u6, cidr.next() orelse "32", 10);
            const port = try std.fmt.parseInt(u16, fields.next() orelse return error.Policy, 10);
            if (bits > 32 or fields.next() != null or cidr.next() != null) return error.Policy;
            const protocol: u8 = if (std.mem.eql(u8, proto, "tcp")) 6 else if (std.mem.eql(u8, proto, "udp")) 17 else if (std.mem.eql(u8, proto, "icmp") and port == 0) 1 else return error.Policy;
            p.rules[p.count] = .{ .address = address, .mask = if (bits == 0) 0 else @as(u32, std.math.maxInt(u32)) << @as(u5, @intCast(32 - bits)), .port = port, .protocol = protocol };
            p.count += 1;
        }
        return p;
    }
    fn permits(p: *const Policy, frame: []const u8, id: u32, mac: [6]u8) bool {
        if (frame.len < 14 or !std.mem.eql(u8, frame[6..12], &mac)) return false;
        const guest = 0x0a000002 | (id << 8);
        const ether = std.mem.readInt(u16, frame[12..14], .big);
        if (ether == 0x0806) {
            return frame.len >= 42 and std.mem.eql(u8, frame[14..20], &.{ 0, 1, 8, 0, 6, 4 }) and
                (frame[20] == 0 and (frame[21] == 1 or frame[21] == 2)) and std.mem.eql(u8, frame[22..28], &mac) and
                std.mem.readInt(u32, frame[28..32], .big) == guest and std.mem.readInt(u32, frame[38..42], .big) == guest - 1;
        }
        if (ether != 0x0800 or frame.len < 34) return false;
        const ip = frame[14..];
        const hlen = @as(usize, ip[0] & 15) * 4;
        const length = std.mem.readInt(u16, ip[2..4], .big);
        if (ip[0] >> 4 != 4 or hlen < 20 or length < hlen or length > ip.len or
            std.mem.readInt(u16, ip[6..8], .big) & 0x3fff != 0 or std.mem.readInt(u32, ip[12..16], .big) != guest) return false;
        const protocol = ip[9];
        if (length - hlen < (if (protocol == 6) @as(usize, 20) else 8)) return false;
        if (protocol != 1 and protocol != 6 and protocol != 17) return false;
        const port = if (protocol == 1) 0 else std.mem.readInt(u16, ip[hlen + 2 ..][0..2], .big);
        const destination = std.mem.readInt(u32, ip[16..20], .big);
        for (p.rules[0..p.count]) |r| if (r.protocol == protocol and destination & r.mask == r.address & r.mask and (r.port == 0 or r.port == port)) return true;
        return false;
    }
};

// ── VM ─────────────────────────────────────────────────────────────────────
const Vcpu = struct { vm: *Vm, id: u32, fd: i32 = -1, run: *Run = undefined, mapped: usize = 0 };
const Vm = struct {
    gpa: std.mem.Allocator,
    id: u32,
    fd: i32 = -1,
    ram: []align(PAGE) u8 = &.{},
    lock: Spin = .{},
    halt: std.atomic.Value(bool) = .init(false),
    ncpu: u32 = 1,
    mem: u64 = 512 << 20,
    vcpu: [MAX_CPU]Vcpu = undefined,
    threads: [MAX_CPU]?std.Thread = @splat(null),
    blk: Vdev = .{ .kind = .blk, .base = BLK_BASE, .irq = 5 },
    net: Vdev = .{ .kind = .net, .base = NET_BASE, .irq = 6 },
    cow: Cow = undefined,
    tap: i32 = -1,
    uart: Uart = .{},
    mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x00 },
    state: enum { off, on } = .off,
    kernel: [:0]const u8 = "",
    disk: [:0]const u8 = "",
    initrd: [:0]const u8 = "",
    extra: [:0]const u8 = "",
    overlay: [:0]const u8 = "",
    strings: ?std.heap.ArenaAllocator = null,
    want_net: bool = false,
    policy: Policy = .{},
    denied: u64 = 0,
};

fn sandbox() !void {
    const F = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
    const P = extern struct { len: u16, filter: [*]const F };
    const allow = [_]linux.SYS{
        .ioctl, .read,       .write,   .pread64,     .pwrite64,     .mmap,            .munmap, .close,
        .exit,  .exit_group, .futex,   .sched_yield, .rt_sigreturn, .clock_nanosleep, .gettid, .restart_syscall,
        .poll,  .ppoll,      .madvise, .brk,         .mremap,       .writev,
    };
    var f: [allow.len + 6]F = undefined;
    f[0] = .{ .code = 0x20, .jt = 0, .jf = 0, .k = 4 }; // load arch
    f[1] = .{ .code = 0x15, .jt = 1, .jf = 0, .k = 0xc000003e }; // x86-64
    f[2] = .{ .code = 0x06, .jt = 0, .jf = 0, .k = linux.SECCOMP.RET.KILL_PROCESS };
    f[3] = .{ .code = 0x20, .jt = 0, .jf = 0, .k = 0 }; // load syscall
    for (allow, 0..) |sc, i| f[4 + i] = .{ .code = 0x15, .jt = @intCast(allow.len - i), .jf = 0, .k = @intCast(@intFromEnum(sc)) };
    f[allow.len + 4] = f[2];
    f[allow.len + 5] = .{ .code = 0x06, .jt = 0, .jf = 0, .k = linux.SECCOMP.RET.ALLOW };
    const p = P{ .len = f.len, .filter = &f };
    _ = try sys(linux.prctl(38, 1, 0, 0, 0)); // PR_SET_NO_NEW_PRIVS
    _ = try sys(linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, &p));
}

fn tapdev(id: u32, mac: *[6]u8) !i32 {
    mac[5] = @truncate(id);
    const tap = try fdopen("/dev/net/tun", .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NONBLOCK = true });
    errdefer _ = linux.close(tap);
    var ifr: [40]u8 = @splat(0);
    _ = try std.fmt.bufPrint(ifr[0..16], "run{d}", .{id});
    wle(u16, ifr[16..18], 0x0002 | 0x1000 | 0x8000); // TAP | NO_PI | TUN_EXCL
    try io(tap, IOCTL.IOW('T', 202, i32), @intFromPtr(&ifr));
    const sk: i32 = @intCast(try sys(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)));
    defer _ = linux.close(sk);
    wle(u16, ifr[16..18], 1); // UP
    try io(sk, 0x8914, @intFromPtr(&ifr));
    @memset(ifr[16..], 0);
    wle(u16, ifr[16..18], linux.AF.INET);
    wle(u32, ifr[20..24], 0x0100000a | (id << 16));
    try io(sk, 0x8916, @intFromPtr(&ifr)); // address
    wle(u32, ifr[20..24], 0x00ffffff);
    try io(sk, 0x891c, @intFromPtr(&ifr)); // netmask
    return tap;
}

fn topology(entries: []CpuidEnt, id: u32, count: u32) void {
    for (entries) |*e| switch (e.func) {
        1 => e.ebx = (e.ebx & 0xffff) | (count << 16) | (id << 24),
        4 => e.eax = (e.eax & 0x3ff) | ((count - 1) << 26),
        0xb, 0x1f => {
            e.eax = if (e.idx == 1) std.math.log2_int_ceil(u32, count) else 0;
            e.ebx = if (e.idx == 0) 1 else if (e.idx == 1) count else 0;
            e.ecx = e.idx | (if (e.idx < 2) (e.idx + 1) << 8 else 0);
            e.edx = id;
        },
        else => {},
    };
}

fn setupCpu(vm: *Vm, cpu: *Vcpu, rip: u64, cpuid: []u8) !void {
    cpu.fd = @intCast(try ior(vm.fd, KVM_CREATE_VCPU, cpu.id));
    const msz = try ior(cloud_kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
    const rc = linux.mmap(null, msz, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, cpu.fd, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Mmap;
    cpu.run = @ptrFromInt(rc);
    cpu.mapped = msz;
    topology(std.mem.bytesAsSlice(CpuidEnt, @as([]align(4) u8, @alignCast(cpuid[@sizeOf(Cpuid)..]))), cpu.id, vm.ncpu);
    try io(cpu.fd, KVM_SET_CPUID2, @intFromPtr(cpuid.ptr));
    if (cpu.id != 0) {
        var mp = MpState{ .state = 1 }; // UNINITIALIZED
        try io(cpu.fd, KVM_SET_MP_STATE, @intFromPtr(&mp));
        return;
    }
    var sr: Sregs = std.mem.zeroes(Sregs);
    try io(cpu.fd, KVM_GET_SREGS, @intFromPtr(&sr));
    sr.cs = seg(0x10, 11, 1, 0);
    sr.ds = seg(0x18, 3, 0, 1);
    sr.es = sr.ds;
    sr.fs = sr.ds;
    sr.gs = sr.ds;
    sr.ss = sr.ds;
    sr.tr = .{ .base = 0, .limit = 0, .selector = 0, .type = 11, .present = 0, .dpl = 0, .db = 0, .s = 0, .l = 0, .g = 0, .avl = 0, .unusable = 1, .pad = 0 };
    sr.gdt = .{ .base = 0x10000, .limit = 31 };
    sr.idt = .{ .base = 0, .limit = 0 };
    sr.cr0 = 0x80050033;
    sr.cr3 = 0x1000;
    sr.cr4 = 0x20 | 0x200 | 0x400;
    sr.efer = 0x500;
    sr.apic_base = 0xfee00000 | (1 << 11) | (1 << 8);
    try io(cpu.fd, KVM_SET_SREGS, @intFromPtr(&sr));
    var r = Regs{ .rip = rip, .rsi = 0x20000, .rflags = 2 };
    try io(cpu.fd, KVM_SET_REGS, @intFromPtr(&r));
}

var cloud_kvm: i32 = -1;

fn handle(cpu: *Vcpu) !void {
    const vm = cpu.vm;
    const run = cpu.run;
    switch (run.exit_reason) {
        EXIT_HLT, EXIT_INTR => {},
        EXIT_SHUTDOWN, EXIT_SYSTEM => vm.halt.store(true, .release),
        EXIT_INTERNAL => {
            log("vm{d}: KVM internal error {d}\n", .{ vm.id, le(u32, &run.un.pad) });
            vm.halt.store(true, .release);
        },
        EXIT_IO => {
            const io_ = run.un.io;
            const ptr = @as([*]u8, @ptrCast(run)) + io_.data_off;
            const slice = ptr[0 .. @as(usize, io_.size) * io_.count];
            if (io_.dir == 0) @memset(slice, 0xff);
            if (io_.port >= 0x3f8 and io_.port < 0x400) {
                for (0..io_.count) |i| vm.uart.io(io_.port, slice[i * io_.size ..][0..io_.size], io_.dir == 1, 1);
                line(vm, 4, vm.uart.irq() != 1);
            } else if (io_.port == 0xcf8 or io_.port == 0xcfc) {
                if (io_.dir == 0) @memset(slice, 0xff);
            } else if (io_.port == 0xcf9 and io_.dir == 1) {
                vm.halt.store(true, .release);
            }
        },
        EXIT_MMIO => {
            const m = run.un.mmio;
            const n: usize = m.len;
            if (m.is_write != 0) {
                var buf = m.data;
                if (m.phys >= BLK_BASE and m.phys < BLK_BASE + 0x200) mmio(vm, &vm.blk, m.phys - BLK_BASE, buf[0..n], true);
                if (m.phys >= NET_BASE and m.phys < NET_BASE + 0x200) mmio(vm, &vm.net, m.phys - NET_BASE, buf[0..n], true);
            } else {
                var buf: [8]u8 = @splat(0);
                if (m.phys >= BLK_BASE and m.phys < BLK_BASE + 0x200) mmio(vm, &vm.blk, m.phys - BLK_BASE, buf[0..n], false);
                if (m.phys >= NET_BASE and m.phys < NET_BASE + 0x200) mmio(vm, &vm.net, m.phys - NET_BASE, buf[0..n], false);
                @memcpy(cpu.run.un.mmio.data[0..n], buf[0..n]);
            }
        },
        else => {
            log("vm{d}: unexpected KVM exit {d}, detail 0x{x}\n", .{ vm.id, run.exit_reason, le(u64, &run.un.pad) });
            vm.halt.store(true, .release);
        },
    }
}

var idle_run: Run = .{};
threadlocal var active_run: *Run = &idle_run;
fn interrupt(_: linux.SIG) callconv(.c) void {
    @as(*volatile u8, &active_run.immediate_exit).* = 1;
}

fn runCpu(cpu: *Vcpu) void {
    active_run = cpu.run;
    defer cpu.vm.halt.store(true, .release);
    sandbox() catch {
        log("vm{d}: vCPU sandbox failed\n", .{cpu.vm.id});
        return;
    };
    while (true) {
        @as(*volatile u8, &cpu.run.immediate_exit).* = 0;
        if (cpu.vm.halt.load(.acquire)) break;
        const rc = linux.ioctl(cpu.fd, KVM_RUN, 0);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e == .AGAIN) { // An AP can still be waiting for INIT/SIPI.
            _ = linux.sched_yield();
            continue;
        }
        if (e != .SUCCESS) {
            log("vm{d}: KVM_RUN errno {d}\n", .{ cpu.vm.id, @intFromEnum(e) });
            break;
        }
        cpu.vm.lock.lock();
        handle(cpu) catch {};
        cpu.vm.lock.unlock();
    }
}

fn startVm(vm: *Vm) !void {
    if (vm.state == .on) return;
    if (vm.ncpu == 0 or vm.ncpu > MAX_CPU or vm.mem < 16 << 20 or vm.mem > RAM_MAX) return error.VmConfig;
    vm.halt.store(false, .release);
    vm.gpa.free(vm.uart.cons);
    vm.uart = .{};
    vm.blk = .{ .kind = .blk, .base = BLK_BASE, .irq = 5 };
    vm.net = .{ .kind = .net, .base = NET_BASE, .irq = 6 };
    for (&vm.vcpu, 0..) |*cpu, id| cpu.* = .{ .vm = vm, .id = @intCast(id) };
    vm.cow = try Cow.init(vm.gpa, if (vm.disk.len == 0) null else vm.disk);
    vm.state = .on;
    errdefer stopVm(vm);
    if (vm.overlay.len != 0) {
        const saved = try mmapFile(vm.overlay);
        defer _ = linux.munmap(saved.ptr, saved.len);
        try vm.cow.restore(saved);
    }
    vm.uart.cons = try vm.gpa.alloc(u8, 1 << 16);
    vm.mac[5] = @truncate(vm.id);
    if (vm.want_net) vm.tap = try tapdev(vm.id, &vm.mac);
    vm.ram = try mmapAnon(@intCast(vm.mem));
    const bz = try mmapFile(vm.kernel);
    defer _ = linux.munmap(bz.ptr, bz.len);
    const ird: []const u8 = if (vm.initrd.len == 0) &.{} else try mmapFile(vm.initrd);
    defer {
        if (ird.len != 0) _ = linux.munmap(ird.ptr, ird.len);
    }

    var cmd_buf: [512]u8 = undefined;
    var net_buf: [128]u8 = undefined;
    const net_cmd = if (vm.tap >= 0) try std.fmt.bufPrint(&net_buf, " ip=10.0.{d}.2::10.0.{d}.1:255.255.255.0::eth0:off", .{ vm.id, vm.id }) else "";
    const cmd = try std.fmt.bufPrint(&cmd_buf, "console=ttyS0 earlyprintk=serial,ttyS0,115200 reboot=t panic=1 pci=off tsc=reliable{s}{s} {s}", .{
        net_cmd,
        if (vm.ncpu > 1) " acpi=force" else "",
        vm.extra,
    });
    const rip = try loadKernel(vm.ram, bz, ird, cmd, vm.ncpu);

    vm.fd = @intCast(try ior(cloud_kvm, KVM_CREATE_VM, 0));
    try io(vm.fd, KVM_SET_TSS_ADDR, 0xfffbd000);
    var ident: u64 = 0xfffbc000;
    try io(vm.fd, KVM_SET_IDENTITY_MAP_ADDR, @intFromPtr(&ident));
    try io(vm.fd, KVM_CREATE_IRQCHIP, 0);
    var pit = PitCfg{ .flags = 0 };
    _ = linux.ioctl(vm.fd, KVM_CREATE_PIT2, @intFromPtr(&pit));
    if (try ior(cloud_kvm, KVM_CHECK_EXTENSION, KVM_CAP_X86_DISABLE_EXITS) != 0) {
        var cap = EnableCap{ .cap = KVM_CAP_X86_DISABLE_EXITS, .args = .{ 2 | 4, 0, 0, 0 } }; // HLT|PAUSE
        _ = linux.ioctl(vm.fd, KVM_ENABLE_CAP, @intFromPtr(&cap));
    }
    var slot = MemSlot{ .slot = 0, .flags = 0, .gpa = 0, .len = vm.mem, .hva = @intFromPtr(vm.ram.ptr) };
    try io(vm.fd, KVM_SET_USER_MEMORY_REGION, @intFromPtr(&slot));

    var cpuid_buf: [@sizeOf(Cpuid) + 128 * @sizeOf(CpuidEnt)]u8 align(8) = @splat(0);
    const cp = @as(*Cpuid, @ptrCast(&cpuid_buf));
    cp.nent = 128;
    try io(cloud_kvm, KVM_GET_SUPPORTED_CPUID, @intFromPtr(cp));

    var i: u32 = 0;
    while (i < vm.ncpu) : (i += 1) {
        vm.vcpu[i] = .{ .vm = vm, .id = i };
        try setupCpu(vm, &vm.vcpu[i], rip, cpuid_buf[0 .. @sizeOf(Cpuid) + @as(usize, cp.nent) * @sizeOf(CpuidEnt)]);
        vm.threads[i] = try std.Thread.spawn(.{}, runCpu, .{&vm.vcpu[i]});
    }
    log("vm{d} up  {d} vCPU  {d} MiB  kernel={s}\n", .{ vm.id, vm.ncpu, vm.mem >> 20, vm.kernel });
}

fn stopVm(vm: *Vm) void {
    if (vm.state != .on) return;
    vm.halt.store(true, .release);
    for (vm.threads[0..vm.ncpu]) |t| if (t) |th| {
        _ = linux.tgkill(linux.getpid(), th.getHandle(), .USR1);
    };
    for (vm.threads[0..vm.ncpu]) |t| if (t) |th| th.join();
    vm.threads = @splat(null);
    for (vm.vcpu[0..vm.ncpu]) |*c| {
        if (c.mapped != 0) _ = linux.munmap(@as([*]u8, @ptrCast(c.run)), c.mapped);
        if (c.fd >= 0) _ = linux.close(c.fd);
        c.mapped = 0;
        c.fd = -1;
    }
    if (vm.fd >= 0) _ = linux.close(vm.fd);
    if (vm.tap >= 0) _ = linux.close(vm.tap);
    if (vm.ram.len != 0) _ = linux.munmap(vm.ram.ptr, vm.ram.len);
    vm.cow.deinit();
    vm.ram = &.{};
    vm.fd = -1;
    vm.tap = -1;
    vm.state = .off;
}

// A disk checkpoint, serialized with device writes; not a machine snapshot.
fn snapVm(vm: *Vm) !void {
    if (vm.state != .on) return error.Down;
    vm.lock.lock();
    defer vm.lock.unlock();
    var path: [64]u8 = undefined;
    try vm.cow.snap(try std.fmt.bufPrintZ(&path, "vm{d}.disk.{d}.snap", .{ vm.id, vm.cow.gen }));
}

// ── HTTP ───────────────────────────────────────────────────────────────────
const Cloud = struct {
    gpa: std.mem.Allocator,
    vms: [MAX_VM]Vm = undefined,
    used: [MAX_VM]bool = @splat(false),
};

fn kv(b: []const u8, key: []const u8) ?[]const u8 {
    var rest = b;
    while (rest.len != 0) {
        const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
        const pair = rest[0..amp];
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
        }
        if (amp == rest.len) break;
        rest = rest[amp + 1 ..];
    }
    return null;
}
fn kvz(a: std.mem.Allocator, b: []const u8, key: []const u8, dflt: [:0]const u8) ![:0]const u8 {
    const v = kv(b, key) orelse return dflt;
    if (v.len == 0) return dflt;
    var buf: [4096]u8 = undefined;
    if (v.len > buf.len) return error.VmConfig;
    @memcpy(buf[0..v.len], v);
    for (buf[0..v.len]) |*c| if (c.* == '+') {
        c.* = ' ';
    };
    const decoded = std.Uri.percentDecodeInPlace(buf[0..v.len]);
    if (std.mem.indexOfScalar(u8, decoded, 0) != null) return error.VmConfig;
    return try a.dupeZ(u8, decoded);
}
fn kvu(b: []const u8, key: []const u8, dflt: u32) u32 {
    const v = kv(b, key) orelse return dflt;
    return std.fmt.parseInt(u32, v, 10) catch std.math.maxInt(u32);
}

fn reply(cfd: i32, code: []const u8, body: []const u8) void {
    var h: [160]u8 = undefined;
    const hdr = std.fmt.bufPrint(&h, "HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ code, body.len }) catch return;
    wr(cfd, hdr);
    wr(cfd, body);
}

fn requestLength(req: []const u8) !?usize {
    const end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return null;
    var headers = std.mem.splitSequence(u8, req[0..end], "\r\n");
    _ = headers.next();
    var length: ?usize = null;
    while (headers.next()) |header| {
        const colon = std.mem.indexOfScalar(u8, header, ':') orelse return error.Http;
        const key = header[0..colon];
        if (std.ascii.eqlIgnoreCase(key, "Transfer-Encoding")) return error.Http;
        if (std.ascii.eqlIgnoreCase(key, "Content-Length")) {
            if (length != null) return error.Http;
            length = try std.fmt.parseInt(usize, std.mem.trim(u8, header[colon + 1 ..], " \t"), 10);
        }
    }
    if ((length orelse 0) > 4096 - @min(end + 4, 4096)) return error.Http;
    return end + 4 + (length orelse 0);
}

fn vmJson(vm: *Vm, buf: []u8) []const u8 {
    vm.lock.lock();
    defer vm.lock.unlock();
    return std.fmt.bufPrint(buf, "{{\"id\":{d},\"state\":\"{s}\",\"cpus\":{d},\"mem_mb\":{d},\"snap\":{d},\"net\":{s},\"grants\":{d},\"denied\":{d},\"console_cursor\":{d}}}\n", .{
        vm.id,
        @tagName(vm.state),
        vm.ncpu,
        vm.mem >> 20,
        vm.cow.gen,
        if (vm.want_net) "true" else "false",
        vm.policy.count,
        vm.denied,
        vm.uart.clen,
    }) catch "";
}

fn route(cl: *Cloud, cfd: i32, req: []const u8) !void {
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return reply(cfd, "400 Bad Request", "bad\n");
    const first = req[0..line_end];
    var it = std.mem.tokenizeScalar(u8, first, ' ');
    const method = it.next() orelse return;
    var path = it.next() orelse return;
    const qpos = std.mem.indexOfScalar(u8, path, '?');
    var qs: []const u8 = "";
    if (qpos) |q| {
        qs = path[q + 1 ..];
        path = path[0..q];
    }
    const body = if (std.mem.indexOf(u8, req, "\r\n\r\n")) |b| req[b + 4 ..] else "";
    const args = if (body.len != 0) body else qs;

    if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/health"))) {
        return reply(cfd, "200 OK", "run\nGET /vms  POST /vms  POST /vms/:id/start|stop|snap  GET /vms/:id/console\nsnap saves disk changes only; restore with overlay=PATH\n");
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/vms")) {
        var out: [2048]u8 = undefined;
        var n: usize = 0;
        for (&cl.vms, 0..) |*vm, i| {
            if (!cl.used[i]) continue;
            const j = vmJson(vm, out[n..]);
            n += j.len;
        }
        return reply(cfd, "200 OK", out[0..n]);
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/vms")) {
        const grants = try kvz(cl.gpa, args, "allow", "");
        defer cl.gpa.free(grants);
        const policy = try Policy.parse(grants);
        if (kvu(args, "net", 0) > 1) return error.VmConfig;
        if (kvu(args, "cpus", 1) == 0 or kvu(args, "cpus", 1) > MAX_CPU or kvu(args, "mem", 512) < 16 or kvu(args, "mem", 512) > RAM_MAX >> 20) return error.VmConfig;
        const slot = for (cl.used, 0..) |u, i| {
            if (!u) break i;
        } else {
            return reply(cfd, "507 Insufficient Storage", "full\n");
        };
        const vm = &cl.vms[slot];
        var arena = std.heap.ArenaAllocator.init(cl.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        vm.* = .{
            .gpa = cl.gpa,
            .id = @intCast(slot),
            .ncpu = @min(kvu(args, "cpus", 1), MAX_CPU),
            .mem = @min(@as(u64, kvu(args, "mem", 512)) << 20, RAM_MAX),
            .kernel = try kvz(a, args, "kernel", ""),
            .disk = try kvz(a, args, "disk", ""),
            .initrd = try kvz(a, args, "initrd", ""),
            .extra = try kvz(a, args, "cmdline", ""),
            .overlay = try kvz(a, args, "overlay", ""),
            .want_net = kvu(args, "net", 0) != 0 or policy.count != 0,
            .policy = policy,
            .cow = .{ .gpa = cl.gpa },
        };
        vm.strings = arena;
        cl.used[slot] = true;
        var buf: [256]u8 = undefined;
        return reply(cfd, "201 Created", vmJson(vm, &buf));
    }

    var rest = path;
    if (!std.mem.startsWith(u8, rest, "/vms/")) return reply(cfd, "404 Not Found", "no\n");
    rest = rest["/vms/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const id_s = if (slash) |s| rest[0..s] else rest;
    const tail = if (slash) |s| rest[s + 1 ..] else "";
    const id = std.fmt.parseInt(u32, id_s, 10) catch return reply(cfd, "404 Not Found", "no\n");
    if (id >= MAX_VM or !cl.used[id]) return reply(cfd, "404 Not Found", "no\n");
    const vm = &cl.vms[id];

    if (std.mem.eql(u8, method, "GET") and tail.len == 0) {
        var buf: [256]u8 = undefined;
        return reply(cfd, "200 OK", vmJson(vm, &buf));
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, tail, "console")) {
        vm.lock.lock();
        defer vm.lock.unlock();
        const oldest = vm.uart.clen - @min(vm.uart.clen, vm.uart.cons.len);
        const since = if (kv(qs, "since")) |s| try std.fmt.parseInt(usize, s, 10) else oldest;
        if (since < oldest) return reply(cfd, "410 Gone", "console cursor expired\n");
        if (since > vm.uart.clen) return error.Http;
        var h: [192]u8 = undefined;
        wr(cfd, try std.fmt.bufPrint(&h, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nX-Run-Cursor: {d}\r\nConnection: close\r\n\r\n", .{ vm.uart.clen - since, vm.uart.clen }));
        if (since == vm.uart.clen) return;
        const at = since % vm.uart.cons.len;
        const chunk = @min(vm.uart.clen - since, vm.uart.cons.len - at);
        wr(cfd, vm.uart.cons[at..][0..chunk]);
        wr(cfd, vm.uart.cons[0 .. vm.uart.clen - since - chunk]);
        return;
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, tail, "console")) {
        if (vm.state != .on) return reply(cfd, "409 Conflict", "VM is stopped\n");
        vm.lock.lock();
        defer vm.lock.unlock();
        if (body.len > @as(usize, 255 - (vm.uart.w -% vm.uart.r))) return reply(cfd, "409 Conflict", "input queue full\n");
        for (body) |c| vm.uart.put(c);
        line(vm, 4, vm.uart.irq() != 1);
        return reply(cfd, "200 OK", "accepted\n");
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, tail, "permissions")) {
        const policy = try Policy.parse(body);
        vm.lock.lock();
        vm.policy = policy;
        vm.lock.unlock();
        return reply(cfd, "200 OK", "updated\n");
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, tail, "start")) {
        startVm(vm) catch |e| return reply(cfd, "500 Internal Server Error", errorText(e));
        var buf: [256]u8 = undefined;
        return reply(cfd, "200 OK", vmJson(vm, &buf));
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, tail, "stop")) {
        stopVm(vm);
        return reply(cfd, "200 OK", "stopped\n");
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, tail, "snap")) {
        snapVm(vm) catch |e| return reply(cfd, "500 Internal Server Error", errorText(e));
        return reply(cfd, "200 OK", "snap\n");
    }
    if (std.mem.eql(u8, method, "DELETE") and tail.len == 0) {
        stopVm(vm);
        vm.gpa.free(vm.uart.cons);
        if (vm.strings) |*arena| arena.deinit();
        cl.used[id] = false;
        return reply(cfd, "200 OK", "gone\n");
    }
    reply(cfd, "404 Not Found", "no\n");
}

fn listenHttp(port: u16) !i32 {
    const s: i32 = @intCast(try sys(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer _ = linux.close(s);
    const one: i32 = 1;
    _ = linux.setsockopt(s, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    var a = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    _ = try sys(linux.bind(s, @ptrCast(&a), @sizeOf(linux.sockaddr.in)));
    _ = try sys(linux.listen(s, 32));
    return s;
}

fn usage() void {
    log(
        \\run — a small Linux/KVM monitor.
        \\
        \\  run [opts] [bzImage]
        \\    --disk PATH     virtio-blk image (COW)
        \\    --initrd PATH
        \\    --overlay PATH  restore disk checkpoint against the same base image
        \\    --cpus N        (default 2)
        \\    --mem MB        (default 512, max 3072)
        \\    --cmdline STR
        \\    --api PORT      (default 8080)
        \\    --no-net
        \\    --allow RULES   comma-separated tcp|udp|icmp:IPv4/prefix:port grants
        \\
        \\  curl :8080/vms
        \\  curl -d 'kernel=bzImage&disk=root.img&cpus=2' localhost:8080/vms
        \\  curl -X POST :8080/vms/0/start
        \\
    , .{});
}

pub fn main(init: std.process.Init.Minimal) u8 {
    serve(init) catch |err| {
        log("run: {s}\n", .{errorText(err)});
        return 1;
    };
    return 0;
}

fn serve(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var args = init.args.iterate();
    _ = args.next();
    const action = linux.Sigaction{ .handler = .{ .handler = interrupt }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = try sys(linux.sigaction(.USR1, &action, null));
    const ignore = linux.Sigaction{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = try sys(linux.sigaction(.PIPE, &ignore, null));
    var config: Vm = .{ .gpa = gpa, .id = 0, .ncpu = 2, .cow = .{ .gpa = gpa } };
    var port: u16 = 8080;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return usage();
        if (std.mem.eql(u8, a, "--no-net")) {
            config.want_net = false;
            continue;
        }
        if (!std.mem.startsWith(u8, a, "--")) {
            config.kernel = a;
            continue;
        }
        const option = std.meta.stringToEnum(enum { disk, initrd, overlay, cpus, mem, cmdline, api, allow }, a[2..]) orelse return error.VmConfig;
        const value = args.next() orelse return error.VmConfig;
        switch (option) {
            .disk => config.disk = value,
            .initrd => config.initrd = value,
            .overlay => config.overlay = value,
            .cmdline => config.extra = value,
            .cpus => config.ncpu = try std.fmt.parseInt(u32, value, 10),
            .mem => config.mem = @as(u64, try std.fmt.parseInt(u32, value, 10)) << 20,
            .api => port = try std.fmt.parseInt(u16, value, 10),
            .allow => {
                config.policy = try Policy.parse(value);
                config.want_net = true;
            },
        }
    }

    cloud_kvm = fdopen("/dev/kvm", .{ .ACCMODE = .RDWR, .CLOEXEC = true }) catch {
        log("open /dev/kvm failed (need Linux + kvm + permissions)\n", .{});
        return error.NoKvm;
    };
    {
        const as = linux.rlimit{ .cur = RAM_MAX * 4, .max = RAM_MAX * 4 };
        _ = linux.setrlimit(.AS, &as);
    }
    if (try ior(cloud_kvm, KVM_GET_API_VERSION, 0) != 12) return error.KvmVer;
    if (try ior(cloud_kvm, KVM_CHECK_EXTENSION, KVM_CAP_IRQCHIP) == 0) return error.NoIrqchip;

    var cl: Cloud = .{ .gpa = gpa };
    const http = try listenHttp(port);
    log("run http://127.0.0.1:{d}\n", .{port});

    if (config.kernel.len != 0) {
        cl.used[0] = true;
        cl.vms[0] = config;
        try startVm(&cl.vms[0]);
    }

    var fds: [1 + MAX_VM]linux.pollfd = undefined;
    while (true) {
        fds[0] = .{ .fd = http, .events = linux.POLL.IN, .revents = 0 };
        var n: usize = 1;
        for (&cl.vms, 0..) |*vm, vi| {
            if (cl.used[vi] and vm.state == .on and vm.halt.load(.acquire)) stopVm(vm);
            if (!cl.used[vi] or vm.tap < 0) continue;
            fds[n] = .{ .fd = vm.tap, .events = linux.POLL.IN, .revents = 0 };
            n += 1;
        }
        _ = linux.poll(&fds, n, 200);
        if (fds[0].revents & linux.POLL.IN != 0) {
            const cfd: i32 = @bitCast(@as(u32, @truncate(linux.accept4(http, null, null, linux.SOCK.CLOEXEC))));
            if (cfd >= 0) {
                const timeout = linux.timeval{ .sec = 1, .usec = 0 };
                _ = linux.setsockopt(cfd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));
                _ = linux.setsockopt(cfd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));
                var buf: [4096]u8 = undefined;
                var nr: usize = 0;
                while (nr < buf.len) {
                    const nread = rd(cfd, buf[nr..]) catch break;
                    if (nread == 0) break;
                    nr += nread;
                    const length = requestLength(buf[0..nr]) catch break;
                    if (length) |nreq| if (nr >= nreq) {
                        route(&cl, cfd, buf[0..nreq]) catch {
                            reply(cfd, "400 Bad Request", "invalid request\n");
                        };
                        break;
                    };
                }
                _ = linux.close(cfd);
            }
        }
        var pi: usize = 1;
        for (&cl.vms, 0..) |*vm, vi| {
            if (!cl.used[vi] or vm.tap < 0) continue;
            if (pi < n and fds[pi].revents & linux.POLL.IN != 0) {
                var pkt: [2048]u8 = undefined;
                const nr = rd(vm.tap, &pkt) catch 0;
                if (nr != 0) {
                    vm.lock.lock();
                    rx(vm, pkt[0..nr]);
                    vm.lock.unlock();
                }
            }
            pi += 1;
        }
    }
}

test "acpi checksum folds to zero" {
    var b = [_]u8{ 1, 2, 3, 0 };
    csum(&b, 3);
    var s: u8 = 0;
    for (b) |x| s +%= x;
    try std.testing.expectEqual(@as(u8, 0), s);
}

test "e820 packs 20-byte entries" {
    var bp: [0x400]u8 = @splat(0);
    var n: u8 = 0;
    e820(&bp, 0, &n, 0x100000, 0x200000, 1);
    try std.testing.expectEqual(@as(u8, 1), n);
    try std.testing.expectEqual(@as(u64, 0x100000), le(u64, bp[0x2d0..][0..8]));
    try std.testing.expectEqual(@as(u32, 1), le(u32, bp[0x2d0 + 16 ..][0..4]));
}

test "private disk mapping, page crossings, bounds and checkpoint restore" {
    const a = std.testing.allocator;
    const fd: i32 = @intCast(try sys(linux.memfd_create("cow-test", 1)));
    defer _ = linux.close(fd);
    _ = try sys(linux.ftruncate(fd, PAGE * 2));
    var path: [64]u8 = undefined;
    var c = try Cow.init(a, try std.fmt.bufPrintZ(&path, "/proc/self/fd/{d}", .{fd}));
    defer c.deinit();
    var data = [_]u8{ 7, 8 };
    try c.rw(PAGE - 1, &data, true);
    try std.testing.expectEqual(@as(u8, 3), c.dirty[0]);
    var original: [2]u8 = undefined;
    _ = try sys(linux.pread(fd, &original, original.len, PAGE - 1));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, &original);
    try c.rw(PAGE - 1, &original, false);
    try std.testing.expectEqualSlices(u8, &data, &original);
    try std.testing.expectError(error.DiskRange, c.rw(PAGE * 2 - 1, &data, true));
    try std.testing.expectError(error.DiskRange, c.rw(std.math.maxInt(u64), &data, false));
    var checkpoint: [16 + 4 + PAGE]u8 = @splat(0);
    @memcpy(checkpoint[0..8], "RUNCOW\x00\x00");
    wle(u32, checkpoint[8..], 1);
    wle(u32, checkpoint[16..], 1);
    checkpoint[20] = 42;
    try c.restore(&checkpoint);
    try std.testing.expectEqual(@as(u8, 42), c.base[PAGE]);
    wle(u32, checkpoint[16..], 2);
    try std.testing.expectError(error.Checkpoint, c.restore(&checkpoint));
    try std.testing.expectError(error.Checkpoint, c.restore(checkpoint[0..21]));
}

test "virtqueues reject cycles, indirect chains, invalid queues and wrong permissions" {
    const a = std.testing.allocator;
    var vm: Vm = .{ .gpa = a, .id = 0, .ram = try mmapAnon(PAGE), .cow = .{ .gpa = a } };
    defer _ = linux.munmap(vm.ram.ptr, vm.ram.len);
    var q: Vq = .{ .num = 8, .desc = 128 };
    const desc = vm.ram[128..144];
    wle(u64, desc, 512);
    wle(u32, desc[8..], 16);
    wle(u16, desc[12..], 1); // self-cycle
    var iov: [64][]u8 = undefined;
    var writable: u64 = 0;
    try std.testing.expectError(error.Vq, walk(&vm, &q, 0, &iov, &writable));
    wle(u16, desc[12..], 4);
    try std.testing.expectError(error.Vq, walk(&vm, &q, 0, &iov, &writable));
    wle(u16, desc[12..], 2);
    try std.testing.expectEqual(@as(usize, 1), try walk(&vm, &q, 0, &iov, &writable));
    try std.testing.expectEqual(@as(u64, 1), writable);
    wle(u64, desc, PAGE - 1);
    try std.testing.expectError(error.Gpa, walk(&vm, &q, 0, &iov, &writable));
    try std.testing.expectError(error.Vq, kick(&vm, &vm.blk, std.math.maxInt(u32)));
    var value: [4]u8 = undefined;
    wle(u32, &value, 257);
    mmio(&vm, &vm.blk, 0x38, &value, true);
    try std.testing.expectEqual(@as(u16, 0), vm.blk.q[0].num);
    var hdr: [16]u8 = @splat(0);
    var status = [_]u8{255};
    var request = [_][]u8{ &hdr, &status };
    try std.testing.expectError(error.Vq, doBlk(&vm, &request, 0));
    wle(u64, hdr[8..], std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u32, 1), try doBlk(&vm, &request, 2));
    try std.testing.expectEqual(@as(u8, 1), status[0]);
    wle(u32, &hdr, 99);
    try std.testing.expectEqual(@as(u32, 1), try doBlk(&vm, &request, 2));
    try std.testing.expectEqual(@as(u8, 2), status[0]);
    vm.cow.base = try mmapAnon(131072);
    defer vm.cow.deinit();
    vm.cow.dirty = try a.alloc(u8, 4);
    @memset(vm.cow.dirty, 0);
    var payload: [131072]u8 = undefined;
    hdr = @splat(0);
    var large = [_][]u8{ &hdr, payload[0..65536], payload[65536..], &status };
    try std.testing.expectEqual(@as(u32, 131073), try doBlk(&vm, &large, 14));
    try std.testing.expectEqual(@as(u8, 0), status[0]);
}

test "boot rejects truncated kernels and reserves decompression space" {
    const ram = try mmapAnon(16 << 20);
    defer _ = linux.munmap(ram.ptr, ram.len);
    var bz: [4096]u8 = @splat(0);
    for (0..0x264) |n| try std.testing.expectError(error.NotKernel, loadKernel(ram, bz[0..n], &.{}, "", 1));
    @memcpy(bz[0x202..0x206], "HdrS");
    wle(u16, bz[0x206..], 0x20c);
    wle(u16, bz[0x236..], 1);
    wle(u32, bz[0x238..], 4095);
    wle(u32, bz[0x260..], 4 << 20);
    wle(u32, bz[0x22c..], 0x37ffffff);
    try std.testing.expectEqual(@as(u64, 0x100200), try loadKernel(ram, &bz, &.{1}, "console=ttyS0", 2));
    try std.testing.expect(le(u32, ram[0x20218..]) >= (5 << 20));
    bz[0x1f1] = 255;
    try std.testing.expectError(error.NotKernel, loadKernel(ram, &bz, &.{}, "", 1));
}

test "HTTP framing, form decoding and response headers" {
    try std.testing.expectEqual(@as(?usize, null), try requestLength("GET / HTTP/1.1\r\n"));
    const req = "POST /vms HTTP/1.1\r\nContent-Length: 4\r\n\r\n";
    try std.testing.expectEqual(@as(?usize, req.len + 4), try requestLength(req));
    try std.testing.expectError(error.Http, requestLength("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n"));
    try std.testing.expectError(error.Http, requestLength("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"));
    const value = try kvz(std.testing.allocator, "cmdline=a+b%26c", "cmdline", "");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("a b&c", value);
    try std.testing.expectError(error.VmConfig, kvz(std.testing.allocator, "k=%00", "k", ""));
    var pair: [2]i32 = undefined;
    _ = try sys(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair));
    defer {
        _ = linux.close(pair[0]);
        _ = linux.close(pair[1]);
    }
    reply(pair[0], "507 Insufficient Storage", "full\n");
    var response: [256]u8 = undefined;
    const n = try rd(pair[1], &response);
    try std.testing.expect(std.mem.startsWith(u8, response[0..n], "HTTP/1.1 507"));
    try std.testing.expect(std.mem.endsWith(u8, response[0..n], "\r\n\r\nfull\n"));
}

test "vCPU topology uses distinct APIC IDs and a single package" {
    var entries: [3]CpuidEnt = @splat(std.mem.zeroes(CpuidEnt));
    entries[0].func = 1;
    entries[1].func = 0xb;
    entries[2].func = 0xb;
    entries[2].idx = 1;
    topology(&entries, 3, 4);
    try std.testing.expectEqual(@as(u32, 0x03040000), entries[0].ebx);
    try std.testing.expectEqual(@as(u32, 3), entries[1].edx);
    try std.testing.expectEqual(@as(u32, 4), entries[2].ebx);
    try std.testing.expectEqual(@as(u32, 2), entries[2].eax);
}

test "egress grants reject spoofing, fragments, IPv6 and ungranted ports" {
    const p = try Policy.parse("tcp:10.0.0.1/32:8000,udp:1.1.1.1:53");
    const mac = [_]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0 };
    var frame: [54]u8 = @splat(0);
    @memcpy(frame[6..12], &mac);
    frame[12] = 8;
    frame[14] = 0x45;
    frame[17] = 40;
    frame[23] = 6;
    @memcpy(frame[26..30], &[_]u8{ 10, 0, 0, 2 });
    @memcpy(frame[30..34], &[_]u8{ 10, 0, 0, 1 });
    std.mem.writeInt(u16, frame[36..38], 8000, .big);
    try std.testing.expect(p.permits(&frame, 0, mac));
    const revoked: Policy = .{};
    try std.testing.expect(!revoked.permits(&frame, 0, mac));
    for ([_]usize{ 6, 12, 20, 26, 30, 37 }) |i| {
        frame[i] ^= 1;
        try std.testing.expect(!p.permits(&frame, 0, mac));
        frame[i] ^= 1;
    }
    for (0..frame.len) |n| try std.testing.expect(!p.permits(frame[0..n], 0, mac));
    for ([_][]const u8{ "tcp:1.1.1.1/33:80", "udp:300.0.0.1:53", "tcp:1.1.1.1:65536", "icmp:1.1.1.1:80", "tcp:1.1.1.1:80," }) |s| {
        if (Policy.parse(s)) |_| return error.AcceptedInvalidPolicy else |_| {}
    }
}

test "UART input IRQ acknowledgement and byte-addressed block capacity" {
    var uart: Uart = .{};
    uart.ier = 1;
    uart.put('x');
    try std.testing.expectEqual(@as(u8, 4), uart.irq());
    var byte: [1]u8 = undefined;
    uart.io(0x3f8, &byte, false, -1);
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);
    try std.testing.expectEqual(@as(u8, 1), uart.irq());
    var vm: Vm = .{ .id = 0, .gpa = std.testing.allocator, .cow = .{ .gpa = std.testing.allocator, .base = try mmapAnon(1 << 20) } };
    defer vm.cow.deinit();
    var capacity: [8]u8 = undefined;
    for (&capacity, 0..) |*b, i| b.* = @truncate(cfg(&vm, &vm.blk, i));
    try std.testing.expectEqual(@as(u64, 2048), le(u64, &capacity));
}
