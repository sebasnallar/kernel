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

// Forward declare the SyscallFrame type from syscall module
const SyscallFrame = @import("root").syscall.SyscallFrame;

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
    // For receiver's syscall frame (to set return values directly)
    receiver_frame: ?*SyscallFrame = null,
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
    // Endpoints are already zero-initialized at compile time
    // Just set special states for reserved endpoints
    endpoints[0].state = .closed;
    endpoints[1].state = .active;

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

/// Copy message fields (avoids SIMD in freestanding)
fn copyMessage(dst: *Message, src: *const Message) void {
    dst.op = src.op;
    dst.arg0 = src.arg0;
    dst.arg1 = src.arg1;
    dst.arg2 = src.arg2;
    dst.arg3 = src.arg3;
    dst.sender = src.sender;
    dst.reply_to = src.reply_to;
    dst.badge = src.badge;
}

/// Send a message (synchronous - blocks until received)
pub fn send(dest: EndpointId, msg: *const Message) IpcError!void {
    if (!initialized) return IpcError.InvalidEndpoint;

    const idx = dest.raw();
    if (idx >= MAX_ENDPOINTS) return IpcError.InvalidEndpoint;

    const ep = &endpoints[idx];
    if (ep.state != .active) return IpcError.EndpointClosed;

    // Check if there's a waiting receiver
    if (ep.waiting_receiver) |receiver| {
        // Direct handoff to receiver's buffer
        if (ep.receiver_buf) |recv_buf| {
            copyMessage(recv_buf, msg);
            if (scheduler.getCurrent()) |cur| {
                recv_buf.sender = EndpointId.fromRaw(cur.tid);
            }
        }
        // Also set the receiver's syscall frame return values directly
        // This ensures when the receiver returns from the blocked syscall,
        // it has the correct return values without needing to continue execution
        if (ep.receiver_frame) |frame| {
            // x0 = op (return value)
            frame.x0 = msg.op;
            // x1 = arg0
            frame.x1 = msg.arg0;
            // x2 = arg1
            frame.x2 = msg.arg1;
        }
        ep.waiting_receiver = null;
        ep.receiver_buf = null;
        ep.receiver_frame = null;
        scheduler.unblock(receiver);
    } else {
        // No receiver waiting - store and block
        copyMessage(&ep.pending_msg, msg);
        if (scheduler.getCurrent()) |cur| {
            ep.pending_msg.sender = EndpointId.fromRaw(cur.tid);
        }
        ep.has_pending_msg = true;
        if (scheduler.getCurrent()) |cur| {
            ep.waiting_sender = cur;
        }
        scheduler.blockCurrent(.blocked_ipc);
        // NOTE: With deferred scheduling, execution continues here immediately.
        // The receiver's tryReceive will clear has_pending_msg when it picks up
        // the message and unblocks us. We don't clear it here.
    }
}

/// Clear a message to defaults
fn clearMessage(msg: *Message) void {
    msg.op = 0;
    msg.arg0 = 0;
    msg.arg1 = 0;
    msg.arg2 = 0;
    msg.arg3 = 0;
    msg.sender = .invalid;
    msg.reply_to = .invalid;
    msg.badge = 0;
}

/// Receive a message (synchronous - blocks until message arrives)
pub fn receive(from: EndpointId, msg: *Message) IpcError!void {
    if (!initialized) return IpcError.InvalidEndpoint;

    const idx = from.raw();
    if (idx >= MAX_ENDPOINTS) return IpcError.InvalidEndpoint;

    const ep = &endpoints[idx];
    if (ep.state != .active) return IpcError.EndpointClosed;

    // Check for pending notification first
    if (ep.notification_pending) {
        clearMessage(msg);
        msg.badge = ep.notification_badge;
        ep.notification_pending = false;
        return;
    }

    // Check if there's a waiting sender with a message
    if (ep.waiting_sender) |sender| {
        if (ep.has_pending_msg) {
            copyMessage(msg, &ep.pending_msg);
            ep.has_pending_msg = false;
        }
        ep.waiting_sender = null;
        scheduler.unblock(sender);
    } else {
        // No sender waiting - block until one arrives
        const console = root.console;
        console.puts("[IPC] No sender, blocking receiver\n");
        if (scheduler.getCurrent()) |cur| {
            ep.waiting_receiver = cur;
        }
        ep.receiver_buf = msg;
        // Mark as blocked - the actual reschedule happens when syscall returns
        // We need to check if a message arrived after we're unblocked
        scheduler.blockCurrent(.blocked_ipc);
        // When we return here, the sender should have filled our message buffer
        console.puts("[IPC] Receiver unblocked\n");
        ep.receiver_buf = null;
    }
}

/// Result of tryReceive operation
pub const TryReceiveResult = enum(u8) {
    got_message = 0,
    no_message = 1,
    invalid_endpoint = 2,
    endpoint_closed = 3,
};

/// Non-blocking receive - returns simple enum to avoid error union issues
pub fn tryReceive(from: EndpointId, msg: *Message) TryReceiveResult {
    if (!initialized) return .invalid_endpoint;

    const idx = from.raw();
    if (idx >= MAX_ENDPOINTS) return .invalid_endpoint;

    const ep = &endpoints[idx];
    if (ep.state != .active) return .endpoint_closed;

    // Check for pending notification
    if (ep.notification_pending) {
        clearMessage(msg);
        msg.badge = ep.notification_badge;
        ep.notification_pending = false;
        return .got_message;
    }

    // Check if there's a waiting sender with a message
    if (ep.waiting_sender) |sender| {
        if (ep.has_pending_msg) {
            copyMessage(msg, &ep.pending_msg);
            ep.has_pending_msg = false;
            ep.waiting_sender = null;
            scheduler.unblock(sender);
            return .got_message;
        }
    }

    return .no_message;
}

/// Register current thread as waiting receiver on an endpoint
/// This is called when tryReceive returns false, to set up for later wakeup
/// The frame pointer is used to set return values directly when message arrives
pub fn registerWaitingReceiver(from: EndpointId, msg: *Message, frame: ?*SyscallFrame) void {
    const idx = from.raw();
    if (idx >= MAX_ENDPOINTS) return;

    const ep = &endpoints[idx];
    if (ep.state != .active) return;

    if (scheduler.getCurrent()) |cur| {
        ep.waiting_receiver = cur;
    }
    ep.receiver_buf = msg;
    ep.receiver_frame = frame;
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
