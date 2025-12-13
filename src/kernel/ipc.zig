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
    op: u32, // Operation code
    arg0: u64, // Arguments (register-sized for speed)
    arg1: u64,
    arg2: u64,
    arg3: u64,
    sender: EndpointId,
    reply_to: EndpointId,
    badge: u64,

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
    // Reset all endpoints (set fields individually to avoid SIMD issues)
    for (&endpoints) |*ep| {
        ep.state = .free;
        ep.owner_tid = 0;
        ep.waiting_sender = null;
        ep.waiting_receiver = null;
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

/// Send a message (synchronous - blocks until received)
pub fn send(dest: EndpointId, msg: *const Message) IpcError!void {
    if (!initialized) return IpcError.InvalidEndpoint;

    const idx = dest.raw();
    if (idx >= MAX_ENDPOINTS) return IpcError.InvalidEndpoint;

    const ep = &endpoints[idx];
    if (ep.state != .active) return IpcError.EndpointClosed;

    // Check if there's a waiting receiver
    if (ep.waiting_receiver) |receiver| {
        // Direct handoff - TODO: copy msg to receiver's buffer
        ep.waiting_receiver = null;
        _ = msg;
        scheduler.unblock(receiver);
    } else {
        // Block until receiver arrives
        scheduler.blockCurrent(.blocked_ipc);
    }
}

/// Receive a message (synchronous - blocks until message arrives)
pub fn receive(from: EndpointId, msg: *Message) IpcError!void {
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
        return;
    }

    // Check if there's a waiting sender
    if (ep.waiting_sender) |sender| {
        ep.waiting_sender = null;
        // TODO: Copy message from sender's buffer to msg
        scheduler.unblock(sender);
    } else {
        // Block until sender arrives
        scheduler.blockCurrent(.blocked_ipc);
    }
}

/// Non-blocking receive
pub fn tryReceive(from: EndpointId, msg: *Message) IpcError!bool {
    if (!initialized) return IpcError.InvalidEndpoint;

    const idx = from.raw();
    if (idx >= MAX_ENDPOINTS) return IpcError.InvalidEndpoint;

    const ep = &endpoints[idx];
    if (ep.state != .active) return IpcError.EndpointClosed;

    if (ep.notification_pending) {
        msg.* = Message.init(0);
        msg.badge = ep.notification_badge;
        ep.notification_pending = false;
        return true;
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
