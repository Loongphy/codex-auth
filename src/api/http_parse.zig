const std = @import("std");
const types = @import("http_types.zig");

const ParsedNodeHttpOutput = types.ParsedNodeHttpOutput;
const BatchHttpResult = types.BatchHttpResult;
const BatchItemResult = types.BatchItemResult;
const NodeOutcome = types.NodeOutcome;

pub fn parseNodeHttpOutput(allocator: std.mem.Allocator, output: []const u8) ?ParsedNodeHttpOutput {
    const trimmed = std.mem.trimEnd(u8, output, "\r\n");
    const outcome_idx = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return null;
    const status_idx = std.mem.lastIndexOfScalar(u8, trimmed[0..outcome_idx], '\n') orelse return null;
    const encoded_body = std.mem.trim(u8, trimmed[0..status_idx], " \r\t");
    const status_slice = std.mem.trim(u8, trimmed[status_idx + 1 .. outcome_idx], " \r\t");
    const outcome_slice = std.mem.trim(u8, trimmed[outcome_idx + 1 ..], " \r\t");
    const status = std.fmt.parseInt(u16, status_slice, 10) catch return null;
    const decoded_body = decodeBase64Alloc(allocator, encoded_body) catch return null;
    return .{
        .body = decoded_body,
        .status_code = if (status == 0) null else status,
        .outcome = parseNodeOutcome(outcome_slice) orelse {
            allocator.free(decoded_body);
            return null;
        },
    };
}

pub fn parseBatchNodeHttpOutput(allocator: std.mem.Allocator, output: []const u8) !BatchHttpResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .array => |array| array,
        else => return error.InvalidBatchOutput,
    };

    const items = try allocator.alloc(BatchItemResult, root.items.len);
    errdefer allocator.free(items);
    for (items) |*item| item.* = .{
        .body = &.{},
        .status_code = null,
        .outcome = .failed,
    };
    errdefer {
        for (items) |*item| {
            if (item.body.len != 0) allocator.free(item.body);
        }
    }

    for (root.items, 0..) |entry, idx| {
        const obj = switch (entry) {
            .object => |object| object,
            else => return error.InvalidBatchOutput,
        };

        const encoded_body = switch (obj.get("body") orelse return error.InvalidBatchOutput) {
            .string => |value| value,
            else => return error.InvalidBatchOutput,
        };
        const status = switch (obj.get("status") orelse return error.InvalidBatchOutput) {
            .integer => |value| value,
            else => return error.InvalidBatchOutput,
        };
        const outcome_text = switch (obj.get("outcome") orelse return error.InvalidBatchOutput) {
            .string => |value| value,
            else => return error.InvalidBatchOutput,
        };

        items[idx] = .{
            .body = try decodeBase64Alloc(allocator, encoded_body),
            .status_code = if (status == 0) null else std.math.cast(u16, status) orelse return error.InvalidBatchOutput,
            .outcome = if (std.mem.eql(u8, outcome_text, "ok"))
                .ok
            else if (std.mem.eql(u8, outcome_text, "timeout"))
                .timeout
            else if (std.mem.eql(u8, outcome_text, "error"))
                .failed
            else
                return error.InvalidBatchOutput,
        };
    }

    return .{ .items = items };
}

fn parseNodeOutcome(input: []const u8) ?NodeOutcome {
    if (std.mem.eql(u8, input, "ok")) return .ok;
    if (std.mem.eql(u8, input, "timeout")) return .timeout;
    if (std.mem.eql(u8, input, "error")) return .failed;
    if (std.mem.eql(u8, input, "node-too-old")) return .node_too_old;
    return null;
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const out_len = try decoder.calcSizeForSlice(input);
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);
    try decoder.decode(buf, input);
    return buf;
}
