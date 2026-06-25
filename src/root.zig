const std = @import("std");
const options = @import("options");

/// Shannon entropy <https://rosettacode.org/wiki/Entropy>
pub fn entropy(s: []const u8) f64 {
    var counts: [256]u16 = @splat(0);
    for (s) |ch| counts[ch] += 1;

    var h: f64 = 0;
    for (counts) |c|
        if (c != 0) {
            const p = @as(f64, c) / @as(f64, @floatFromInt(s.len));
            h -= p * std.math.log2(p);
        };

    return h;
}

pub const LoadIterator = struct {
    buf: []const u8,
    idx: usize = 0,

    const Self = @This();

    const Params = switch (options.arch) {
        .x86, .x86_64 => struct {
            pub const hint: []const u8 = &.{0x8d};
            pub const offsets: [2]u8 = .{ 0, 6 };
            pub const window_size = offsets[0] + offsets[1];
            pub inline fn check(w: *const [window_size]u8) bool {
                return w[1] & 0b11_000_111 == 0b00_000_101;
            }
            pub inline fn result(idx: usize, w: *const [window_size]u8) usize {
                const imm = std.mem.readInt(i32, w[2..6], .little);
                return idx +% @as(usize, @bitCast(@as(isize, imm)));
            }
        },
        .aarch64 => struct {
            pub const hint: []const u8 = &.{0x91};
            pub const offsets: [2]u8 = .{ 7, 1 };
            pub const window_size = offsets[0] + offsets[1];
            pub inline fn check(w: *const [window_size]u8) bool {
                if (w[3] & 0x9F != 0x90) return false;
                if (w[6] & 0xC0 != 0x00) return false;
                const adrp_rd = w[0] & 0x1F;
                const add_rn = (w[4] >> 5) | (@as(u8, w[5] & 0x03) << 3);
                return adrp_rd == add_rn;
            }

            pub inline fn result(idx: usize, w: *const [window_size]u8) usize {
                const pc = idx - 8;

                const immlo = (w[3] >> 5) & 0x03;
                const immhi_0_2 = @as(u32, w[0] >> 5) << 2;
                const immhi_3_10 = @as(u32, w[1]) << 5;
                const immhi_11_18 = @as(u32, w[2]) << 13;
                const imm21_u = @as(u32, immlo) | immhi_0_2 | immhi_3_10 | immhi_11_18;

                const imm_i32 = @as(i32, @bitCast(imm21_u << 11)) >> 11;
                const adrp_offset = @as(isize, imm_i32) * 4096;

                const base = (pc & ~@as(usize, 0xFFF)) +% @as(usize, @bitCast(adrp_offset));

                const add_offset = (@as(usize, w[5]) >> 2) | (@as(usize, w[6] & 0x3F) << 6);

                // HACK: parsing the ELF header lets us calculate the virtual offset
                //       hardcode the commonly used value 0x10000 for now

                // LOAD off    0x0000000000ac49e8 vaddr 0x0000000000ad49e8 ... align 2**16

                return base + add_offset + 0x10000;
            }
        },
        else => @compileError("Unsupported arch"),
    };

    pub fn next(self: *Self) ?usize {
        return while (std.mem.findPos(u8, self.buf, self.idx, Params.hint)) |m| {
            const w: *const [Params.window_size]u8 = @ptrCast(self.buf[m - Params.offsets[0] .. m + Params.offsets[1]]);

            if (!Params.check(w)) {
                self.idx = m + 1;
                continue;
            } else {
                self.idx = m + Params.offsets[1];
            }

            break Params.result(self.idx, w);
        } else null;
    }
};

/// Montgomery modular multiplication <10.1090/S0025-5718-1985-0777282-X>
fn Montgomery(comptime N: usize) type {
    const T = @Int(.unsigned, N);
    const T2 = @Int(.unsigned, 2 * N);

    return struct {
        mod: T,
        n_prime: T,
        r2: T,

        m_1: T,
        m_predMod: T,

        const Self = @This();

        pub fn init(mod: T) Self {
            var x: T = 1;
            for (0..std.math.log2(N)) |_| x = x *% (2 -% mod *% x);
            const n_prime = 0 -% x;

            var r: T = 1;
            for (0..2 * N) |_| {
                const hi: bool = r >> (N - 1) != 0;
                r <<= 1;
                if (hi or r >= mod) r -%= mod;
            }

            var self: Self = .{
                .mod = mod,
                .n_prime = n_prime,
                .r2 = r,
                .m_1 = undefined,
                .m_predMod = undefined,
            };

            self.m_1 = self.lift(1);
            self.m_predMod = self.lift(mod - 1);

            return self;
        }

        pub fn mul(self: *Self, a: T, b: T) T {
            const t: T2 = @as(T2, a) * b;
            const u: T = @as(T, @truncate(t)) *% self.n_prime;
            const sum, const carry = @addWithOverflow(t, @as(T2, u) * self.mod);
            var r: T = @truncate(sum >> N);
            if (carry != 0 or r >= self.mod) r -%= self.mod;
            return r;
        }

        pub fn lift(self: *Self, a: T) T {
            return self.mul(a, self.r2);
        }

        pub fn lower(self: *Self, a: T) T {
            return self.mul(a, 1);
        }

        pub fn modExp(self: *Self, base: T, exp: T) T {
            var res = self.m_1;
            var b = self.lift(base);
            var e = exp;
            while (e > 0) : (e >>= 1) {
                if (e & 1 != 0) res = self.mul(res, b);
                b = self.mul(b, b);
            }
            return res;
        }
    };
}

/// Miller-Rabin primality test <https://rosettacode.org/wiki/Miller-Rabin_primality_test>
fn isPrime(n: u1024) bool {
    if (n <= 1) return false;
    if (n <= 3) return true;
    if (n & 1 == 0) return false;

    var d = n - 1;
    var s: u32 = 0;
    while (d & 1 == 0) : (d >>= 1) s += 1;

    var mont: Montgomery(1024) = .init(n);

    const bases = [_]u1024{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 };
    for (bases) |base| {
        if (n <= base) break;

        var x = mont.modExp(base, d);
        if (x == mont.m_1 or x == mont.m_predMod) continue;

        var r: u32 = 1;
        while (r < s) : (r += 1) {
            x = mont.mul(x, x);
            if (x == mont.m_predMod) break;
        } else return false;
    }

    return true;
}

/// Gosper's hack <https://rosettacode.org/wiki/Gosper's_hack>
fn BitmaskIterator(n: usize) type {
    const T = @Int(.unsigned, n);

    return struct {
        mask: T,

        const Self = @This();

        fn withBits(bits: std.math.Log2Int(T)) Self {
            return .{ .mask = (@as(T, 1) << bits) - 1 };
        }

        fn next(self: *Self) ?T {
            if (self.mask == 0) return null;
            const mask = self.mask;

            const c = self.mask & (0 -% self.mask);
            const r = self.mask +% c;
            self.mask = (((r ^ self.mask) >> 2) / c) | r;

            return mask;
        }
    };
}

pub fn findNearestPrime(target: u1024) u1024 {
    if (isPrime(target)) return target;

    var iter: BitmaskIterator(1024) = undefined;
    return blk: for (1..1024) |d| {
        iter = .withBits(@intCast(d));
        while (iter.next()) |mask| {
            const candidate = (target | 1) ^ (mask << 1);
            if (isPrime(candidate)) break :blk candidate;
        }
    } else unreachable;
}

pub fn modInv(a: u1024, module: u1024) u1024 {
    var mn_0 = module;
    var mn_1 = a;
    var xy_0: i2048 = 0;
    var xy_1: i2048 = 1;

    while (mn_1 != 0) {
        const xy_0_temp = xy_1;
        xy_1 = xy_0 - @divFloor(mn_0, mn_1) * xy_1;
        xy_0 = xy_0_temp;

        const mn_0_temp = mn_1;
        mn_1 = @rem(mn_0, mn_1);
        mn_0 = mn_0_temp;
    }

    while (xy_0 < 0) {
        xy_0 += module;
    }

    return @intCast(xy_0);
}

pub fn modExp(base: u1024, exp: u1024, mod: u1024) u1024 {
    const m: u1024 = mod;
    var r: u2048 = 1;
    var b: u2048 = base % m;
    var e: u1024 = exp;
    while (e > 0) : (e >>= 1) {
        if (e & 1 != 0) r = (r * b) % m;
        b = (b * b) % m;
    }
    return @intCast(r);
}
