//! Root of the abstract, zero-C X11 library (one `x11` module).
//! Consumers reach the pieces as namespaces: `x11.wire`, `x11.display`,
//! `x11.xauth`, `x11.cookie`, `x11.connection`, `x11.client`.

const std = @import("std");

pub const wire = @import("x11/wire.zig");
pub const display = @import("x11/display.zig");
pub const xauth = @import("x11/xauth.zig");
pub const cookie = @import("x11/cookie.zig");
pub const connection = @import("x11/connection.zig");
pub const Connection = connection.Connection;
pub const client = @import("x11/client.zig");
pub const Client = client.Client;
pub const server = @import("x11/server.zig");
pub const Server = server.Server;
pub const ServerConn = server.ServerConn;
pub const Multiplexer = server.Multiplexer;
pub const ServerEvent = server.ServerEvent;
pub const server_state = @import("x11/server_state.zig");
pub const Display = server_state.Display;
pub const render = @import("x11/render.zig");
pub const server_loop = @import("x11/server_loop.zig");
pub const server_atoms = @import("x11/server_atoms.zig");
pub const randr = @import("x11/randr.zig");

pub const name = "x11";

test {
    std.testing.refAllDecls(@This());
}
