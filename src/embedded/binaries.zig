// Embedded MLK Binaries
// These are user programs compiled and embedded in the kernel image

pub const hello = @embedFile("hello.mlk");
pub const init = @embedFile("init.mlk");

// Binary IDs for SYS_SPAWN
pub const BINARY_HELLO: u64 = 0;
pub const BINARY_INIT: u64 = 1;
