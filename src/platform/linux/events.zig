//! X11 wire event layouts and event type constants. Hand-written extern
//! structs only; offsets match `Xlib.h` for a 64-bit ABI.

const xlib = @import("xlib.zig");

pub const Display = xlib.Display;
pub const Window = xlib.Window;
pub const Atom = xlib.Atom;

pub const key_press: c_int = 2;
pub const key_release: c_int = 3;
pub const button_press: c_int = 4;
pub const button_release: c_int = 5;
pub const motion_notify: c_int = 6;
pub const expose: c_int = 12;
pub const configure_notify: c_int = 22;
pub const selection_request: c_int = 30;
pub const client_message: c_int = 33;

pub const KeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: c_int,
};

pub const ButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: c_int,
};

pub const ConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    event: Window,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: Window,
    override_redirect: c_int,
};

pub const ClientMessage = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: extern union { b: [20]u8, s: [10]c_short, l: [5]c_long },
};

pub const SelectionRequest = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    owner: Window,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: c_ulong,
};

pub const SelectionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: c_ulong,
};

pub const Event = extern union {
    type: c_int,
    key: KeyEvent,
    button: ButtonEvent,
    configure: ConfigureEvent,
    client: ClientMessage,
    selection_request: SelectionRequest,
    pad: [24]c_long,
};
