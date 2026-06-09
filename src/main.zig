const std = @import("std");
const otzade = @import("otzade");
const options = @import("options");

const Rsa = struct {
    n: u1024,
    e: u8,
};

fn findRsa(buf: []const u8) Rsa {
    var iter: otzade.LoadIterator = .{ .buf = buf };
    const s_xref = blk: {
        const s_address = std.mem.find(u8, buf, options.needle).?;
        while (iter.next()) |ea| if (ea == s_address) break :blk iter.idx;
        unreachable;
    };

    iter.idx = std.mem.findScalarLast(u8, buf[0..@intCast(s_xref)], 0xc3).?;

    while (iter.next()) |ea| {
        const target = buf[ea..][0..128];
        if (otzade.entropy(target) > 6) {
            return .{
                .n = std.mem.readInt(u1024, target, .little),
                .e = buf[iter.next().?],
            };
        }
    }

    unreachable;
}

fn patchAll(
    io: std.Io,
    files: []const [*:0]const u8,
    needle: u1024,
    replacement: u1024,
) !void {
    var needle_bytes: [128]u8 = undefined;
    var replacement_bytes: [128]u8 = undefined;
    std.mem.writeInt(u1024, &needle_bytes, needle, .little);
    std.mem.writeInt(u1024, &replacement_bytes, replacement, .little);

    for (files) |file_path| {
        var file = try std.Io.Dir.cwd().openFile(io, std.mem.sliceTo(file_path, 0), .{
            .mode = .read_write,
        });
        defer file.close(io);

        var mmap = try file.createMemoryMap(io, .{
            .len = try file.length(io),
            .protection = .{ .read = true, .write = true },
        });
        defer mmap.destroy(io);
        try mmap.read(io);

        var idx: usize = 0;
        while (std.mem.findPos(u8, mmap.memory, idx, &needle_bytes)) |match| {
            defer idx = match + 128;
            @memcpy(mmap.memory[match..][0..128], &replacement_bytes);
        }

        try mmap.write(io);
    }
}

pub fn main(init: std.process.Init) !void {
    if (std.process.Args.Vector != []const [*:0]const u8) {
        @compileError("tough luck, kiddo");
    }

    const args = init.minimal.args.vector;
    std.debug.assert(args.len > 1);

    const rsa = blk: {
        var file = try std.Io.Dir.cwd().openFile(init.io, std.mem.sliceTo(args[1], 0), .{
            .mode = .read_only,
        });
        defer file.close(init.io);

        var mmap = try file.createMemoryMap(init.io, .{
            .len = try file.length(init.io),
            .protection = .{ .read = true, .write = false },
        });
        defer mmap.destroy(init.io);
        try mmap.read(init.io);

        break :blk findRsa(mmap.memory);
    };

    const prime = otzade.findNearestPrime(rsa.n);
    const d = otzade.modInv(rsa.e, prime - 1);

    const payload = blk: {
        var buf: [128]u8 = undefined;
        var reader = std.Io.File.stdin().reader(init.io, &buf);
        break :blk try reader.interface.takeInt(u1024, .little);
    };

    const signature = otzade.modExp(payload, d, prime);

    std.debug.print("{X}", .{signature});

    try patchAll(init.io, args[1..], rsa.n, prime);
}
