//! End-to-end tests of `RdpSession` against the in-process RDP server.

use std::ffi::{c_char, c_void};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use toolbox_core::rdp_test_server::{self, TestServer, TestServerConfig, H264_PICTURE_SIZE};
use toolbox_core::{RdpConfig, RdpListener, RdpMouseButton, RdpSession};

#[derive(Default)]
struct Seen {
    /// Width, height and the ID of the surface the app would display.
    connected: Mutex<Option<(u16, u16, u32)>>,
    resized: Mutex<Option<(u16, u16, u32)>>,
    regions: Mutex<Vec<(u16, u16, u16, u16)>>,
    errors: Mutex<Vec<String>>,
    closed: AtomicBool,
    clean: AtomicBool,
    close_reason: Mutex<Option<String>>,
    clipboard_ready: AtomicBool,
    remote_copies: Mutex<Vec<bool>>,
    clipboard_text: Mutex<Vec<String>>,
    text_requests: AtomicU32,
    notices: Mutex<Vec<String>>,
}

impl Seen {
    fn size(&self) -> Option<(u16, u16)> {
        self.connected.lock().unwrap().map(|(width, height, _)| (width, height))
    }

    fn resized_to(&self) -> Option<(u16, u16)> {
        self.resized.lock().unwrap().map(|(width, height, _)| (width, height))
    }

    /// The surface the app would be showing now.
    fn surface(&self) -> u32 {
        let resized = *self.resized.lock().unwrap();
        resized.or(*self.connected.lock().unwrap()).map_or(0, |(_, _, surface)| surface)
    }
}

struct Recorder(Arc<Seen>);

impl RdpListener for Recorder {
    fn on_connected(&self, width: u16, height: u16, surface_id: u32) {
        *self.0.connected.lock().unwrap() = Some((width, height, surface_id));
    }
    fn on_desktop_resized(&self, width: u16, height: u16, surface_id: u32) {
        *self.0.resized.lock().unwrap() = Some((width, height, surface_id));
    }
    fn on_region_updated(&self, x: u16, y: u16, width: u16, height: u16) {
        self.0.regions.lock().unwrap().push((x, y, width, height));
    }
    fn on_error(&self, message: String) {
        self.0.errors.lock().unwrap().push(message);
    }
    fn on_closed(&self, reason: String, clean: bool) {
        *self.0.close_reason.lock().unwrap() = Some(reason);
        self.0.clean.store(clean, SeqCst);
        self.0.closed.store(true, SeqCst);
    }
    fn on_clipboard_ready(&self) {
        self.0.clipboard_ready.store(true, SeqCst);
    }
    fn on_clipboard_remote_changed(&self, has_text: bool) {
        self.0.remote_copies.lock().unwrap().push(has_text);
    }
    fn on_clipboard_text(&self, text: String) {
        self.0.clipboard_text.lock().unwrap().push(text);
    }
    fn on_clipboard_text_requested(&self) {
        self.0.text_requests.fetch_add(1, SeqCst);
    }
    fn on_notice(&self, message: String) {
        self.0.notices.lock().unwrap().push(message);
    }
}

fn wait_until(what: &str, secs: u64, mut cond: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(secs);
    while !cond() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn config(addr: std::net::SocketAddr, password: &str) -> RdpConfig {
    RdpConfig {
        host: addr.ip().to_string(),
        port: addr.port(),
        username: "demo".into(),
        password: password.into(),
        domain: None,
        width: 640,
        height: 480,
        scale_factor: 100,
        accept_invalid_certs: true,
        connect_timeout_secs: 10,
        fast_graphics: false,
        clipboard: false,
    }
}

fn start_server(config: TestServerConfig) -> (tokio::runtime::Runtime, TestServer) {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let server = rt.block_on(rdp_test_server::start(config)).unwrap();
    (rt, server)
}

fn connect(config: RdpConfig) -> (Arc<Seen>, Arc<RdpSession>) {
    let seen = Arc::new(Seen::default());
    let session = RdpSession::connect(config, Box::new(Recorder(seen.clone())));
    (seen, session)
}

fn close(session: &RdpSession, seen: &Seen) {
    session.close();
    wait_until("close", 10, || seen.closed.load(SeqCst));
    assert!(session.is_closed());
    assert!(seen.clean.load(SeqCst));
    assert!(seen.errors.lock().unwrap().is_empty(), "{:?}", seen.errors.lock().unwrap());
}

#[link(name = "IOSurface", kind = "framework")]
extern "C" {
    fn IOSurfaceLookup(id: u32) -> *mut c_void;
    fn IOSurfaceLock(surface: *mut c_void, options: u32, seed: *mut u32) -> i32;
    fn IOSurfaceUnlock(surface: *mut c_void, options: u32, seed: *mut u32) -> i32;
    fn IOSurfaceGetBaseAddress(surface: *mut c_void) -> *mut c_void;
    fn IOSurfaceGetBytesPerRow(surface: *mut c_void) -> usize;
    fn IOSurfaceGetWidth(surface: *mut c_void) -> usize;
    fn IOSurfaceGetHeight(surface: *mut c_void) -> usize;
    fn IOSurfaceSetValue(surface: *mut c_void, key: *const c_void, value: *const c_void);
    fn IOSurfaceCopyValue(surface: *mut c_void, key: *const c_void) -> *const c_void;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(cf: *const c_void);
    fn CFStringCreateWithCString(allocator: *const c_void, text: *const c_char, encoding: u32) -> *const c_void;
}

const UTF8: u32 = 0x0800_0100; // kCFStringEncodingUTF8

/// One BGRA pixel of the surface with this ID, read the way the app's
/// layer gets at it: by looking the surface up. `None` when there is no
/// such surface or the pixel is outside it.
fn surface_pixel(id: u32, x: usize, y: usize) -> Option<[u8; 4]> {
    // SAFETY: the surface is checked for null, locked while read, and the
    // pixel is checked to lie inside it.
    unsafe {
        let surface = IOSurfaceLookup(id);
        if surface.is_null() {
            return None;
        }
        let mut pixel = None;
        if x < IOSurfaceGetWidth(surface) && y < IOSurfaceGetHeight(surface) && IOSurfaceLock(surface, 1, std::ptr::null_mut()) == 0 {
            let base = IOSurfaceGetBaseAddress(surface).cast::<u8>();
            let at = base.add(y * IOSurfaceGetBytesPerRow(surface) + x * 4);
            pixel = Some([*at, *at.add(1), *at.add(2), *at.add(3)]);
            IOSurfaceUnlock(surface, 1, std::ptr::null_mut());
        }
        CFRelease(surface.cast_const());
        pixel
    }
}

/// Whether the surface with this ID carries the test's mark, which `set`
/// puts on it first. This is how to ask whether a surface is gone: its ID
/// goes to the next surface that is made, here or in a test running
/// beside this one, so a look-up of an old ID may well find something.
fn surface_mark(id: u32, set: bool) -> bool {
    // SAFETY: the surface is checked for null; the key is a valid string
    // for both calls, and everything created or copied is released.
    unsafe {
        let surface = IOSurfaceLookup(id);
        if surface.is_null() {
            return false;
        }
        let key = CFStringCreateWithCString(std::ptr::null(), c"toolbox.test.mark".as_ptr(), UTF8);
        if set {
            IOSurfaceSetValue(surface, key, key);
        }
        let value = IOSurfaceCopyValue(surface, key);
        if !value.is_null() {
            CFRelease(value);
        }
        CFRelease(key);
        CFRelease(surface.cast_const());
        !value.is_null()
    }
}

fn near(got: &[u8], want: [u8; 3], tolerance: u8) -> bool {
    got.len() >= 3 && got.iter().zip(want).all(|(got, want)| got.abs_diff(want) <= tolerance)
}

const FILL: [u8; 4] = [0x40, 0x80, 0x20, 0xFF];

#[test]
fn connects_renders_inputs_and_resizes() {
    let (_rt, server) = start_server(TestServerConfig::default());
    let (seen, session) = connect(config(server.addr, "secret"));

    wait_until("connect", 20, || seen.connected.lock().unwrap().is_some());
    assert_eq!(seen.size(), Some((640, 480)));
    assert_eq!(session.frame_size().width, 640);
    let first_surface = seen.surface();
    assert_ne!(first_surface, 0);

    // The first update paints the whole desktop in the fill colour.
    wait_until("first frame", 10, || {
        seen.regions.lock().unwrap().iter().any(|&(x, y, w, h)| x == 0 && y == 0 && w >= 640 && h >= 480)
    });
    let pixels = session.copy_region(10, 10, 2, 1);
    assert_eq!(pixels, [FILL, FILL].concat(), "pixels were {pixels:?}");
    let clipped = session.copy_region(636, 476, 100, 100);
    assert_eq!(clipped.len(), 4 * 4 * 4);
    assert!(session.copy_region(700, 10, 1, 1).is_empty());
    // The surface the app displays holds the same pixels.
    assert_eq!(surface_pixel(first_surface, 10, 10), Some(FILL));
    assert_eq!(surface_pixel(first_surface, 639, 479), Some(FILL));

    // Input reaches the server.
    session.mouse_move(100, 50);
    session.mouse_button(RdpMouseButton::Left, true);
    session.mouse_button(RdpMouseButton::Left, false);
    session.key(0x1E, false, true);
    session.key(0x1E, false, false);
    session.unicode(u32::from('é'), true);
    session.unicode(u32::from('é'), false);
    wait_until("input observed", 10, || {
        let o = server.observed.lock().unwrap();
        !o.mouse.is_empty() && o.keys.len() >= 4
    });

    // Resize through Display Control: a new desktop, on a new surface.
    assert!(surface_mark(first_surface, true));
    assert!(surface_mark(first_surface, false), "the mark stays on the surface");
    session.resize(800, 600, 100);
    wait_until("resize", 20, || seen.resized_to() == Some((800, 600)));
    assert_eq!(session.frame_size().width, 800);
    assert_eq!(server.observed.lock().unwrap().layouts.last(), Some(&(800, 600)));
    assert_ne!(seen.surface(), first_surface);
    wait_until("frame after resize", 10, || surface_pixel(seen.surface(), 799, 599) == Some(FILL));
    // The old surface is gone once nothing shows it.
    assert!(!surface_mark(first_surface, false), "the first surface is still there");

    // Without the clipboard, its calls are accepted and do nothing.
    session.clipboard_offer(true, vec!["/etc/hosts".into()]);
    session.clipboard_fetch_text();
    session.clipboard_provide_text(Some("ignored".into()));
    std::thread::sleep(Duration::from_millis(300));
    assert!(!seen.clipboard_ready.load(SeqCst));
    assert!(server.observed.lock().unwrap().clipboard_formats.is_empty());

    assert!(!session.is_closed());
    close(&session, &seen);
}

/// A pane on a Retina display asks for a desktop several times larger than
/// the one it connected at; the session has to survive that.
#[test]
fn resizes_to_a_large_retina_desktop() {
    let (_rt, server) = start_server(TestServerConfig::default());

    // Sizes straight from a pane: neither width is a multiple of 4, which
    // this server (like some real ones) refuses to encode.
    let mut cfg = config(server.addr, "secret");
    cfg.width = 642;
    cfg.height = 481;
    let (seen, session) = connect(cfg);
    wait_until("connect", 20, || seen.connected.lock().unwrap().is_some());
    assert_eq!(seen.size(), Some((640, 480)));

    session.resize(2114, 1588, 200);
    wait_until("resize or failure", 20, || seen.resized_to() == Some((2112, 1588)) || seen.closed.load(SeqCst));
    assert!(
        !seen.closed.load(SeqCst),
        "session closed: {:?} errors {:?}",
        seen.close_reason.lock().unwrap(),
        seen.errors.lock().unwrap()
    );
    // A frame this large arrives as several tiles; wait until both corners
    // of the new desktop carry the fill colour.
    wait_until("frame after resize", 15, || {
        seen.closed.load(SeqCst)
            || (session.copy_region(10, 10, 1, 1) == FILL && session.copy_region(2110, 1586, 1, 1) == FILL)
    });
    assert!(
        !seen.closed.load(SeqCst),
        "session closed after resize: {:?} errors {:?}",
        seen.close_reason.lock().unwrap(),
        seen.errors.lock().unwrap()
    );
    assert_eq!(session.frame_size().width, 2112);
    assert_eq!(server.observed.lock().unwrap().layouts.last(), Some(&(2112, 1588)));
    assert!(seen.regions.lock().unwrap().len() > 1, "expected the frame in tiles");
    assert_eq!(surface_pixel(seen.surface(), 2110, 1586), Some(FILL));
    close(&session, &seen);
}

/// A server without the graphics pipeline sends RemoteFX to a client that
/// offers it: lossy, so colours are close rather than equal.
#[test]
fn fast_graphics_fall_back_to_remotefx() {
    let (_rt, server) = start_server(TestServerConfig::default());
    let mut cfg = config(server.addr, "secret");
    cfg.fast_graphics = true;
    let (seen, session) = connect(cfg);
    wait_until("connect", 20, || seen.connected.lock().unwrap().is_some());
    let fill = [FILL[0], FILL[1], FILL[2]];
    wait_until("first frame", 10, || {
        surface_pixel(seen.surface(), 600, 400).is_some_and(|pixel| near(&pixel, fill, 8))
    });
    assert!(server.observed.lock().unwrap().graphics_capabilities.is_none());

    session.resize(1024, 768, 100);
    wait_until("resize", 20, || seen.resized_to() == Some((1024, 768)));
    wait_until("frame after resize", 10, || {
        surface_pixel(seen.surface(), 1000, 700).is_some_and(|pixel| near(&pixel, fill, 8))
    });
    close(&session, &seen);
}

/// The colour the protocol's transform gives a decoded H.264 sample
/// ([MS-RDPEGFX] 3.3.8.3.1), as B G R.
fn bgr_of(y: u8, u: u8, v: u8) -> [u8; 3] {
    let (luma, u, v) = (256 * i32::from(y), i32::from(u) - 128, i32::from(v) - 128);
    let channel = |value: i32| (value >> 8).clamp(0, 255) as u8;
    [channel(luma + 475 * u), channel(luma - 48 * u - 120 * v), channel(luma + 403 * v)]
}

/// The first picture of tests/data/quadrants.h264, as (Y, Cb, Cr) per
/// quadrant; see tools/make-h264-fixture.swift.
const H264_QUADRANTS: [(u8, u8, u8); 4] = [(200, 100, 180), (60, 200, 90), (120, 128, 128), (235, 60, 60)];

fn h264_picture_is_shown(read: impl Fn(usize, usize) -> Option<Vec<u8>>) -> bool {
    H264_QUADRANTS.iter().enumerate().all(|(index, &(y, u, v))| {
        let (x, row) = (80 + 160 * (index % 2), 50 + 100 * (index / 2));
        read(x, row).is_some_and(|pixel| near(&pixel, bgr_of(y, u, v), 14))
    })
}

/// A server with the graphics pipeline: the desktop arrives over it, with
/// an H.264 picture decoded by VideoToolbox, and a resize arrives as a
/// graphics reset instead of a new activation.
#[test]
fn graphics_pipeline_delivers_h264_and_resizes() {
    let (_rt, server) = start_server(TestServerConfig {
        graphics_pipeline: true,
        ..TestServerConfig::default()
    });
    let mut cfg = config(server.addr, "secret");
    cfg.fast_graphics = true;
    let (seen, session) = connect(cfg);
    wait_until("connect", 20, || seen.connected.lock().unwrap().is_some());
    assert_eq!(seen.size(), Some((640, 480)));

    wait_until("pipeline negotiated", 10, || server.observed.lock().unwrap().graphics_capabilities.is_some());
    let capabilities = server.observed.lock().unwrap().graphics_capabilities.clone().unwrap();
    assert!(capabilities.starts_with("V10"), "expected an H.264-capable set, got {capabilities}");

    // The fill is sent uncompressed, so it is exact; it is below the picture.
    wait_until("desktop over the pipeline", 10, || surface_pixel(seen.surface(), 600, 400) == Some(FILL));
    wait_until("H.264 picture sent", 10, || server.observed.lock().unwrap().h264_frames >= 1);
    wait_until("H.264 picture decoded", 10, || {
        seen.closed.load(SeqCst) || h264_picture_is_shown(|x, y| surface_pixel(seen.surface(), x, y).map(Vec::from))
    });
    assert!(!seen.closed.load(SeqCst), "session closed: {:?}", seen.errors.lock().unwrap());
    // The framebuffer agrees with the surface.
    assert!(h264_picture_is_shown(|x, y| Some(session.copy_region(x as u16, y as u16, 1, 1))));
    // Outside the picture the fill is untouched.
    let (picture_width, picture_height) = H264_PICTURE_SIZE;
    assert_eq!(session.copy_region(picture_width + 4, 10, 1, 1), FILL);
    assert_eq!(session.copy_region(10, picture_height + 2, 1, 1), FILL);

    let first_surface = seen.surface();
    session.resize(800, 600, 100);
    wait_until("resize", 20, || seen.resized_to() == Some((800, 600)) || seen.closed.load(SeqCst));
    assert!(!seen.closed.load(SeqCst), "session closed: {:?}", seen.errors.lock().unwrap());
    assert_eq!(session.frame_size().height, 600);
    assert_ne!(seen.surface(), first_surface);
    wait_until("desktop after resize", 10, || surface_pixel(seen.surface(), 790, 590) == Some(FILL));
    // The decoder starts over after the reset and decodes the new key frame.
    wait_until("H.264 picture after resize", 10, || {
        h264_picture_is_shown(|x, y| surface_pixel(seen.surface(), x, y).map(Vec::from))
    });
    assert_eq!(server.observed.lock().unwrap().h264_frames, 2);
    close(&session, &seen);
}

/// With fast graphics off, the same server is used the old way.
#[test]
fn compatible_graphics_ignore_the_pipeline() {
    let (_rt, server) = start_server(TestServerConfig {
        graphics_pipeline: true,
        ..TestServerConfig::default()
    });
    let (seen, session) = connect(config(server.addr, "secret"));
    wait_until("connect", 20, || seen.connected.lock().unwrap().is_some());
    wait_until("first frame", 10, || surface_pixel(seen.surface(), 600, 400) == Some(FILL));
    let observed = server.observed.lock().unwrap();
    assert!(observed.graphics_capabilities.is_none());
    assert_eq!(observed.h264_frames, 0);
    drop(observed);
    close(&session, &seen);
}

fn clipboard_session(server: &TestServer) -> (Arc<Seen>, Arc<RdpSession>) {
    let mut cfg = config(server.addr, "secret");
    cfg.clipboard = true;
    let (seen, session) = connect(cfg);
    wait_until("connect", 20, || seen.connected.lock().unwrap().is_some());
    wait_until("clipboard channel", 10, || seen.clipboard_ready.load(SeqCst));
    assert!(server.observed.lock().unwrap().clipboard_ready);
    (seen, session)
}

const CF_UNICODETEXT: u32 = 13;

#[test]
fn clipboard_text_goes_both_ways() {
    let (_rt, server) = start_server(TestServerConfig::default());
    let (seen, session) = clipboard_session(&server);
    let announced = || server.observed.lock().unwrap().clipboard_formats.last().cloned();
    let answers = || server.observed.lock().unwrap().clipboard_text.clone();

    // The channel opens with an empty announcement: nothing is shared
    // until the app offers it.
    assert_eq!(announced(), Some(vec![]));

    // This Mac to the remote: announced, then handed over when pasted.
    session.clipboard_offer(true, vec![]);
    wait_until("text announced", 10, || announced() == Some(vec![(CF_UNICODETEXT, None)]));
    assert_eq!(seen.text_requests.load(SeqCst), 0, "nothing is read before the remote pastes");
    server.clipboard_paste_text();
    wait_until("text asked for", 10, || seen.text_requests.load(SeqCst) == 1);
    session.clipboard_provide_text(Some("héllo\nwörld 🙂".into()));
    wait_until("text delivered", 10, || answers().len() == 1);
    assert_eq!(answers()[0].as_deref(), Some("héllo\r\nwörld 🙂"));

    // An answer nobody asked for goes nowhere.
    session.clipboard_provide_text(Some("unasked".into()));

    // The app may find the text gone by the time it is asked.
    server.clipboard_paste_text();
    wait_until("text asked for again", 10, || seen.text_requests.load(SeqCst) == 2);
    session.clipboard_provide_text(None);
    wait_until("refusal delivered", 10, || answers().len() == 2);
    assert_eq!(answers()[1], None);

    // Once withdrawn, the remote is refused without the app being asked.
    session.clipboard_offer(false, vec![]);
    wait_until("withdrawal announced", 10, || announced() == Some(vec![]));
    server.clipboard_paste_text();
    wait_until("refused after withdrawal", 10, || answers().len() == 3);
    assert_eq!(answers()[2], None);
    assert_eq!(seen.text_requests.load(SeqCst), 2);

    // The remote to this Mac: the app is told, and fetches when it wants.
    server.clipboard_copy_text("from the remote\r\nline two");
    wait_until("remote copy seen", 10, || *seen.remote_copies.lock().unwrap() == [true]);
    assert!(seen.clipboard_text.lock().unwrap().is_empty(), "text is not fetched unasked");
    session.clipboard_fetch_text();
    wait_until("remote text", 10, || !seen.clipboard_text.lock().unwrap().is_empty());
    assert_eq!(*seen.clipboard_text.lock().unwrap(), ["from the remote\nline two"]);
    assert_eq!(server.observed.lock().unwrap().clipboard_text_requests, 1);

    // After the remote copied, an offer made before it no longer stands.
    session.clipboard_offer(true, vec![]);
    wait_until("text announced again", 10, || announced() == Some(vec![(CF_UNICODETEXT, None)]));
    server.clipboard_copy_text("remote again");
    wait_until("second remote copy", 10, || seen.remote_copies.lock().unwrap().len() == 2);
    server.clipboard_paste_text();
    wait_until("refused after remote copy", 10, || answers().len() == 4);
    assert_eq!(answers()[3], None);
    assert_eq!(seen.text_requests.load(SeqCst), 2);

    close(&session, &seen);
}

/// An app that never answers must not leave the remote waiting for ever.
#[test]
fn unanswered_clipboard_requests_time_out() {
    let (_rt, server) = start_server(TestServerConfig::default());
    let (seen, session) = clipboard_session(&server);
    session.clipboard_offer(true, vec![]);
    wait_until("text announced", 10, || {
        server.observed.lock().unwrap().clipboard_formats.last() == Some(&vec![(CF_UNICODETEXT, None)])
    });
    server.clipboard_paste_text();
    wait_until("text asked for", 10, || seen.text_requests.load(SeqCst) == 1);
    wait_until("refusal after the wait", 15, || !server.observed.lock().unwrap().clipboard_text.is_empty());
    assert_eq!(server.observed.lock().unwrap().clipboard_text[0], None);
    // A late answer is dropped.
    session.clipboard_provide_text(Some("too late".into()));
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(server.observed.lock().unwrap().clipboard_text.len(), 1);
    close(&session, &seen);
}

#[test]
fn clipboard_files_are_listed_and_read() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().join("reports");
    std::fs::create_dir(&folder).unwrap();
    let big: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    std::fs::write(folder.join("big.bin"), &big).unwrap();
    std::fs::write(folder.join("a:b.txt"), b"renamed for Windows").unwrap();
    let single = dir.path().join("notes.txt");
    std::fs::write(&single, b"hello from the Mac").unwrap();
    let outside = dir.path().join("not-copied.txt");
    std::fs::write(&outside, b"never offered").unwrap();

    let (_rt, server) = start_server(TestServerConfig::default());
    let (seen, session) = clipboard_session(&server);

    // Files win over text when both are on the clipboard.
    session.clipboard_offer(true, vec![folder.to_string_lossy().into(), single.to_string_lossy().into()]);
    wait_until("files announced", 10, || {
        server.observed.lock().unwrap().clipboard_formats.last().is_some_and(|formats| {
            formats.iter().any(|(_, name)| name.as_deref() == Some("FileGroupDescriptorW"))
        })
    });
    let formats = server.observed.lock().unwrap().clipboard_formats.last().cloned().unwrap();
    assert!(formats.iter().all(|(id, _)| *id != CF_UNICODETEXT), "{formats:?}");

    assert!(server.clipboard_paste_file_list());
    wait_until("file list", 10, || server.observed.lock().unwrap().clipboard_files.is_some());
    let files = server.observed.lock().unwrap().clipboard_files.clone().unwrap();
    assert_eq!(
        files,
        vec![
            ("reports".to_owned(), None),
            ("reports\\a_b.txt".to_owned(), Some(19)),
            ("reports\\big.bin".to_owned(), Some(200_000)),
            ("notes.txt".to_owned(), Some(18)),
        ],
        "names only, never a path on this Mac"
    );

    let contents = |stream: u32| {
        server.observed.lock().unwrap().clipboard_file_contents.iter().find(|(id, _)| *id == stream).cloned()
    };
    // Size, then the file in two ranges, as Windows reads it.
    server.clipboard_read_file(1, 2, None);
    wait_until("size", 10, || contents(1).is_some());
    assert_eq!(contents(1).unwrap().1, Some(200_000u64.to_le_bytes().to_vec()));
    server.clipboard_read_file(2, 2, Some((0, 150_000)));
    server.clipboard_read_file(3, 2, Some((150_000, 50_000)));
    wait_until("ranges", 10, || contents(2).is_some() && contents(3).is_some());
    let mut received = contents(2).unwrap().1.unwrap();
    received.extend(contents(3).unwrap().1.unwrap());
    assert_eq!(received, big);
    server.clipboard_read_file(4, 3, Some((6, 4)));
    wait_until("small range", 10, || contents(4).is_some());
    assert_eq!(contents(4).unwrap().1.as_deref(), Some(&b"from"[..]));

    // A folder has no contents to give.
    server.clipboard_read_file(5, 0, Some((0, 1)));
    wait_until("folder refused", 10, || contents(5).is_some());
    assert_eq!(contents(5).unwrap().1, None);

    // A file that disappears is refused rather than read from elsewhere.
    std::fs::remove_file(&single).unwrap();
    server.clipboard_read_file(6, 3, Some((0, 4)));
    wait_until("missing file refused", 10, || contents(6).is_some());
    assert_eq!(contents(6).unwrap().1, None);

    assert!(seen.notices.lock().unwrap().is_empty(), "{:?}", seen.notices.lock().unwrap());
    close(&session, &seen);
}

/// What cannot be shared is left out and the app is told.
#[test]
fn unshareable_clipboard_files_are_reported() {
    let dir = tempfile::tempdir().unwrap();
    let real = dir.path().join("real.txt");
    std::fs::write(&real, b"x").unwrap();
    let (_rt, server) = start_server(TestServerConfig::default());
    let (seen, session) = clipboard_session(&server);

    // Nothing usable: the text on the clipboard is offered instead.
    session.clipboard_offer(true, vec![dir.path().join("gone").to_string_lossy().into()]);
    wait_until("text offered instead", 10, || {
        server.observed.lock().unwrap().clipboard_formats.last() == Some(&vec![(CF_UNICODETEXT, None)])
    });
    assert_eq!(seen.notices.lock().unwrap().len(), 1);
    assert!(seen.notices.lock().unwrap()[0].starts_with("1 item "));

    session.clipboard_offer(false, vec![real.to_string_lossy().into(), "/nonexistent/one".into(), "/nonexistent/two".into()]);
    wait_until("files announced", 10, || seen.notices.lock().unwrap().len() == 2);
    assert!(seen.notices.lock().unwrap()[1].starts_with("2 items "));
    assert!(server.clipboard_paste_file_list() || {
        wait_until("file list format", 10, || server.clipboard_paste_file_list());
        true
    });
    wait_until("file list", 10, || server.observed.lock().unwrap().clipboard_files.is_some());
    assert_eq!(server.observed.lock().unwrap().clipboard_files.clone().unwrap(), vec![("real.txt".to_owned(), Some(1))]);
    close(&session, &seen);
}

#[test]
fn wrong_password_is_reported() {
    let (_rt, server) = start_server(TestServerConfig::default());
    let (seen, _session) = connect(config(server.addr, "nope"));
    wait_until("closed", 20, || seen.closed.load(SeqCst));
    assert!(seen.connected.lock().unwrap().is_none());
    assert!(!seen.clean.load(SeqCst));
    let errors = seen.errors.lock().unwrap().clone();
    assert_eq!(errors.len(), 1, "{errors:?}");
}

#[test]
fn unreachable_host_fails_fast() {
    let mut cfg = config("127.0.0.1:1".parse().unwrap(), "secret");
    cfg.connect_timeout_secs = 2;
    let (seen, _session) = connect(cfg);
    wait_until("closed", 10, || seen.closed.load(SeqCst));
    let errors = seen.errors.lock().unwrap().clone();
    assert!(errors.iter().any(|e| e.contains("127.0.0.1:1")), "{errors:?}");
}
