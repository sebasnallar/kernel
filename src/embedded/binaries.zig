// Embedded MLK Binaries
// These are user programs compiled and embedded in the kernel image

pub const hello = @embedFile("hello.mlk");
pub const init = @embedFile("init.mlk");
pub const console = @embedFile("console.mlk");
pub const blkdev = @embedFile("blkdev.mlk");

// Binary IDs for SYS_SPAWN
pub const BINARY_HELLO: u64 = 0;
pub const BINARY_INIT: u64 = 1;
pub const BINARY_CONSOLE: u64 = 2;
pub const BINARY_BLKDEV: u64 = 3;
