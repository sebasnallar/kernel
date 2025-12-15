// MyLittleKernel - IPC (Inter-Process Communication)
//
// The HEART of the microkernel. All service communication
// happens through message passing.
//
// Design:
//   - Synchronous send/receive (rendezvous - no buffering!)
//   - Lightweight notifications
//   - Capability-based security

const root = @import("root");
const scheduler = root.scheduler;
const console = root.console;

// ============================================================
// Constants
// ============================================================

/// Maximum message payload size
pub const MAX_MSG_SIZE: usize = 64; // Keep it small

/// Maximum endpoints (keep small for now)
const MAX_ENDPOINTS: usize = 32;

// ============================================================
// Types
// ============================================================

/// Endpoint identifier
pub const EndpointId = enum(u32) {
    invalid = 0,
    kernel = 1,
    _,

    pub fn raw(self: EndpointId) u32 {
        return @intFromEnum(self);
    }

    pub fn fromRaw(val: u32) EndpointId {
        return @enumFromInt(val);
    }
};

/// Message structure (small!)
pub const Message = struct {
    op: u32 = 0, // Operation code
    arg0: u64 = 0, // Arguments (register-sized for speed)
    arg1: u64 = 0,
    arg2: u64 = 0,
    arg3: u64 = 0,
    sender: EndpointId = .invalid,
    reply_to: EndpointId = .invalid,
    badge: u64 = 0,

    pub fn init(op: u32) Message {
        return .{
            .op = op,
            .arg0 = 0,
            .arg1 = 0,
            .arg2 = 0,
            .arg3 = 0,
            .sender = .invalid,
            .reply_to = .invalid,
            .badge = 0,
        };
    }
};

/// Capability permissions
pub const CapPermissions = packed struct {
    send: bool = false,
    receive: bool = false,
    grant: bool = false,
    _pad: u29 = 0,
};

/// Capability token
pub const Capability = struct {
    endpoint: EndpointId,
    permissions: CapPermissions,
    badge: u64,
};

/// Endpoint state
const EndpointState = enum(u8) {
    free,
    active,
    closed,
};

/// Lightweight endpoint (no message buffering - pure rendezvous)
const Endpoint = struct {
    state: EndpointState = .free,
    owner_tid: u32 = 0,
    // Waiting thread (only one at a time for simplicity)
    waiting_sender: ?*scheduler.Thread = null,
    waiting_receiver: ?*scheduler.Thread = null,
    // Pending message from blocked sender
    pending_msg: Message = .{},
    has_pending_msg: bool = false,
    // For receiver to store where to put the result
    receiver_buf: ?*Message = null,
    // For pending notification
    notification_pending: bool = false,
    notification_badge: u64 = 0,
};

/// IPC errors
pub const IpcError = error{
    InvalidEndpoint,
    NoPermission,
    WouldBlock,
    EndpointClosed,
    OutOfEndpoints,
};

// ============================================================
// State (small footprint!)
// ============================================================

var endpoints: [MAX_ENDPOINTS]Endpoint = [_]Endpoint{.{}} ** MAX_ENDPOINTS;
var initialized: bool = false;

// ============================================================
// Initialization
// ============================================================

/// Initialize the IPC subsystem
pub fn init() void {
    // Reset all endpoints (set fields individually to avoid SIMD/memset issues)
    for (&endpoints) |*ep| {
        ep.state = .free;
        ep.owner_tid = 0;
        ep.waiting_sender = null;
        ep.waiting_receiver = null;
        // Initialize pending_msg fields individually
        ep.pending_msg.op = 0;
        ep.pending_msg.arg0 = 0;
        ep.pending_msg.arg1 = 0;
        ep.pending_msg.arg2 = 0;
        ep.pending_msg.arg3 = 0;
        ep.pending_msg.sender = .invalid;
        ep.pending_msg.reply_to = .invalid;
        ep.pending_msg.badge = 0;
        ep.has_pending_msg = false;
        ep.receiver_buf = null;
        ep.notification_pending = false;
        ep.notification_badge = 0;
    }

    // Reserve endpoint 0 (invalid) and 1 (kernel)
    endpoints[0].state = .closed;
    endpoints[1].state = .active;
    endpoints[1].owner_tid = 0;

    initialized = true;
}

// ============================================================
// Endpoint Management
// ============================================================

/// Create a new endpoint
pub fn createEndpoint() IpcError!EndpointId {
    if (!initialized) return IpcError.InvalidEndpoint;

    for (&endpoints, 0..) |*ep, i| {
        if (ep.state == .free) {
            ep.state = .active;
            ep.owner_tid = if (scheduler.getCurrent()) |t| t.tid else 0;
            return EndpointId.fromRaw(@intCast(i));
        }
    }
    return IpcError.OutOfEndpoints;
}

/// Destroy an endpoint
pub fn destroyEndpoint(id: EndpointId) void {
    const idx = id.raw();
    if (idx >= MAX_ENDPOINTS) return;
    endpoints[idx] = .{}; // Reset to default
    endpoints[idx].state = .closed;
}

// ============================================================
// IPC Operations
// ============================================================

// Static buffer for send operation (avoid stack issues with large structs)
var send_temp_msg: Message = .{};

/// Send a message (synchronous - blocks until received)
pub fn send(dest: EndpointId, msg: *const Message) IpcError!void {
    if (!initialized) return IpcError.InvalidEndpoint;

    const idx = dest.raw();
    if (idx >= MAX_ENDPOINTS) return IpcError.InvalidEndpoint;

    const ep = &endpoints[idx];
    if (ep.state != .active) return IpcError.EndpointClosed;

    // Copy message fields individually to static buffer (avoid stack struct copy)
    send_temp_msg.op = msg.op;
    send_temp_msg.arg0 = msg.arg0;
    send_temp_msg.arg1 = msg.arg1;
    send_temp_msg.arg2 = msg.arg2;
    send_temp_msg.arg3 = msg.arg3;
    send_temp_msg.reply_to = msg.reply_to;
    send_temp_msg.badge = msg.badge;

    // Fill in sender info
    if (scheduler.getCurrent()) |cur| {
        send_temp_msg.sender = EndpointId.fromRaw(cur.tid);
    }

    // Check if there's a waiting receiver
    if (ep.waiting_receiver) |receiver| {
        // Direct handoff - copy message to receiver's buffer field-by-field
        if (ep.receiver_buf) |recv_buf| {
            recv_buf.op = send_temp_msg.op;
            recv_buf.arg0 = send_temp_msg.arg0;
            recv_buf.arg1 = send_temp_msg.arg1;
            recv_buf.arg2 = send_temp_msg.arg2;
            recv_buf.arg3 = send_temp_msg.arg3;
            recv_buf.sender = send_temp_msg.sender;
            recv_buf.reply_to = send_temp_msg.reply_to;
            recv_buf.badge = send_temp_msg.badge;
        }
        ep.waiting_receiver = null;
        ep.receiver_buf = null;
        scheduler.unblock(receiver);
    } else {
        // Store message field by field (avoid struct copy)
        ep.pending_msg.op = send_temp_msg.op;
        ep.pending_msg.arg0 = send_temp_msg.arg0;
        ep.pending_msg.arg1 = send_temp_msg.arg1;
        ep.pending_msg.arg2 = send_temp_msg.arg2;
        ep.pending_msg.arg3 = send_temp_msg.arg3;
        ep.pending_msg.sender = send_temp_msg.sender;
        ep.pending_msg.reply_to = send_temp_msg.reply_to;
        ep.pending_msg.badge = send_temp_msg.badge;
        ep.has_pending_msg = true;
        if (scheduler.getCurrent()) |cur| {
            ep.waiting_sender = cur;
        }
        scheduler.blockCurrent(.blocked_ipc);
        // When we wake up, the receiver has taken our message
        ep.has_pending_msg = false;
    }
}

/// Receive a message (synchronous - blocks until message arrives)
pub fn receive(from: EndpointId, msg: *Message) IpcError!void {
    if (!initialized) return IpcError.InvalidEndpoint;

    const idx = from.raw();
    console.puts(console.Color.cyan);
    console.puts("[IPC] receive ep=");
    console.putDec(idx);
    console.newline();
    console.puts(console.Color.reset);

    if (idx >= MAX_ENDPOINTS) return IpcError.InvalidEndpoint;

    const ep = &endpoints[idx];
    if (ep.state != .active) return IpcError.EndpointClosed;

    // Check for pending notification first
    if (ep.notification_pending) {
        msg.op = 0;
        msg.arg0 = 0;
        msg.arg1 = 0;
        msg.arg2 = 0;
        msg.arg3 = 0;
        msg.sender = .invalid;
        msg.reply_to = .invalid;
        msg.badge = ep.notification_badge;
        ep.notification_pending = false;
        return;
    }

    // Check if there's a waiting sender with a message
    if (ep.waiting_sender) |sender| {
        console.puts("[IPC] has waiting sender\n");
        if (ep.has_pending_msg) {
            // Copy the pending message field-by-field
            msg.op = ep.pending_msg.op;
            msg.arg0 = ep.pending_msg.arg0;
            msg.arg1 = ep.pending_msg.arg1;
            msg.arg2 = ep.pending_msg.arg2;
            msg.arg3 = ep.pending_msg.arg3;
            msg.sender = ep.pending_msg.sender;
            msg.reply_to = ep.pending_msg.reply_to;
            msg.badge = ep.pending_msg.badge;
            ep.has_pending_msg = false;
        }
        ep.waiting_sender = null;
        scheduler.unblock(sender);
    } else {
        // No sender waiting - block until one arrives
        console.puts("[IPC] no sender, blocking...\n");
        if (scheduler.getCurrent()) |cur| {
            ep.waiting_receiver = cur;
        }
        ep.receiver_buf = msg;
        scheduler.blockCurrent(.blocked_ipc);
        // When we wake up, the message has been copied to msg
        console.puts("[IPC] unblocked!\n");
        ep.receiver_buf = null;
    }
}

/// Non-blocking receive
pub fn tryReceive(from: EndpointId, msg: *Message) IpcError!bool {
    if (!initialized) return IpcError.InvalidEndpoint;

    const idx = from.raw();
    if (idx >= MAX_ENDPOINTS) return IpcError.InvalidEndpoint;

    const ep = &endpoints[idx];
    if (ep.state != .active) return IpcError.EndpointClosed;

    // Check for pending notification
    if (ep.notification_pending) {
        msg.* = Message.init(0);
        msg.badge = ep.notification_badge;
        ep.notification_pending = false;
        return true;
    }

    // Check if there's a waiting sender with a message
    if (ep.waiting_sender) |sender| {
        if (ep.has_pending_msg) {
            msg.* = ep.pending_msg;
            ep.has_pending_msg = false;
            ep.waiting_sender = null;
            scheduler.unblock(sender);
            return true;
        }
    }

    return false;
}

/// Send a notification (non-blocking, fire-and-forget)
pub fn notify(dest: EndpointId, badge: u64) IpcError!void {
    if (!initialized) return IpcError.InvalidEndpoint;

    const idx = dest.raw();
    if (idx >= MAX_ENDPOINTS) return IpcError.InvalidEndpoint;

    const ep = &endpoints[idx];
    if (ep.state != .active) return IpcError.EndpointClosed;

    if (ep.waiting_receiver) |receiver| {
        ep.waiting_receiver = null;
        ep.notification_badge = badge;
        scheduler.unblock(receiver);
    } else {
        // Store notification for later
        ep.notification_pending = true;
        ep.notification_badge = badge;
    }
}

// ============================================================
// Statistics
// ============================================================

/// Get number of active endpoints
pub fn getEndpointCount() u32 {
    var count: u32 = 0;
    for (endpoints) |ep| {
        if (ep.state == .active) count += 1;
    }
    return count;
}
