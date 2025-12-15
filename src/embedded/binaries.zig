// Embedded MLK Binaries
// These are user programs compiled and embedded in the kernel image

pub const hello = @embedFile("hello.mlk");
