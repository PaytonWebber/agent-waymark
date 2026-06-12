//! Single source of truth for the agent-waymark version. The release
//! workflow verifies this against package.json before publishing. The daemon
//! stamps it on every response so clients can detect a daemon left running
//! by an older install and replace it.

pub const version = "0.4.1";
