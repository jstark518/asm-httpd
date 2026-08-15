// http_aarch64.s — a minimal HTTP/1.1 server in AArch64 Linux assembly.
// Single-threaded but concurrent: an epoll loop over non-blocking sockets.

// ---- syscall numbers (AArch64 Linux) ----------------------------------------
.set SYS_read,          63
.set SYS_close,         57
.set SYS_exit,          93
.set SYS_socket,        198
.set SYS_bind,          200
.set SYS_listen,        201
.set SYS_sendto,        206
.set SYS_setsockopt,    208
.set SYS_accept4,       242
.set SYS_epoll_create1, 20
.set SYS_epoll_ctl,     21
.set SYS_epoll_pwait,   22          // AArch64 has no plain epoll_wait

// ---- socket constants -------------------------------------------------------
.set AF_INET,           2
.set SOCK_STREAM,       1
.set SOCK_NONBLOCK,     0x800
.set SOL_SOCKET,        1
.set SO_REUSEADDR,      2
.set MSG_NOSIGNAL,      0x4000     // dead peer -> EPIPE, not SIGPIPE

// ---- epoll constants --------------------------------------------------------
.set EPOLL_CTL_ADD,     1
.set EPOLL_CTL_MOD,     3
.set EPOLLIN,           0x001
.set EPOLLOUT,          0x004
.set EPOLLERR,          0x008
.set EPOLLHUP,          0x010

// struct epoll_event is packed only on x86-64. Here it is the natural layout:
// 4-byte events, 4 bytes of padding, then the 8-byte data union.
.set EVENT_SIZE,        16
.set EVENT_DATA_OFF,    8

.set EAGAIN,            11

.set PORT_HI,           0x1f       // 8080 = 0x1f90, stored big-endian
.set PORT_LO,           0x90
.set BACKLOG,           128
.set REQBUF_SIZE,       8192
.set MAX_EVENTS,        64
.set MAX_FDS,           4096       // bounds the per-connection state table

// -----------------------------------------------------------------------------
.section .rodata
.balign 8

// struct sockaddr_in { u16 family; u16 port; u32 addr; u8 pad[8]; }
sockaddr:
        .hword  AF_INET
        .byte   PORT_HI, PORT_LO           // network byte order
        .word   0                          // INADDR_ANY
        .quad   0                          // sin_zero
.set sockaddr_len, . - sockaddr

one:    .word   1                          // value for SO_REUSEADDR

body:
        .ascii  "Hello, world! Served by AArch64 assembly, no libc.\n"
.set body_len, . - body

response:
        .ascii  "HTTP/1.1 200 OK\r\n"
        .ascii  "Content-Type: text/plain; charset=utf-8\r\n"
        .ascii  "Content-Length: 51\r\n"
        .ascii  "Connection: close\r\n"
        .ascii  "\r\n"
        .ascii  "Hello, world! Served by AArch64 assembly, no libc.\n"
.set response_len, . - response

// Content-Length is a string literal, so assert at assembly time that it still
// matches the body. A mismatch here hangs clients; better to fail the build.
.if body_len != 51
        .error "Content-Length header is out of sync with the response body"
.endif

// -----------------------------------------------------------------------------
.section .bss
.balign 8

// Every connection reads into the same buffer. That is safe only because the
// request is never parsed -- it is read to drain the socket and then discarded.
reqbuf:
        .skip   REQBUF_SIZE

events:                                    // epoll_pwait output
        .skip   MAX_EVENTS * EVENT_SIZE

ev:                                        // scratch epoll_event for _ctl
        .skip   EVENT_SIZE

// Bytes of the response already sent, indexed by fd. Meaningful only while a
// connection is in the EPOLLOUT state.
sent:
        .skip   MAX_FDS * 4

// -----------------------------------------------------------------------------
.section .text
.global _start

// Register roles across the event loop:
//   x19 = listening socket   x20 = epoll fd
//   x21 = current event ptr  x22 = events remaining in this batch
//   x23 = current fd         x24 = current event mask
_start:
        // listen_fd = socket(AF_INET, SOCK_STREAM|SOCK_NONBLOCK, 0)
        // Non-blocking from birth, so accept() never stalls the loop.
        mov     x0, #AF_INET
        mov     x1, #(SOCK_STREAM | SOCK_NONBLOCK)
        mov     x2, #0
        mov     x8, #SYS_socket
        svc     #0
        tbnz    x0, #63, .Lfail                 // negative return -> error
        mov     x19, x0

        // setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        // Lets the container restart without waiting out TIME_WAIT.
        mov     x0, x19
        mov     x1, #SOL_SOCKET
        mov     x2, #SO_REUSEADDR
        adrp    x3, one
        add     x3, x3, #:lo12:one
        mov     x4, #4
        mov     x8, #SYS_setsockopt
        svc     #0

        // bind(listen_fd, &sockaddr, sizeof sockaddr)
        mov     x0, x19
        adrp    x1, sockaddr
        add     x1, x1, #:lo12:sockaddr
        mov     x2, #sockaddr_len
        mov     x8, #SYS_bind
        svc     #0
        tbnz    x0, #63, .Lfail

        // listen(listen_fd, BACKLOG)
        mov     x0, x19
        mov     x1, #BACKLOG
        mov     x8, #SYS_listen
        svc     #0
        tbnz    x0, #63, .Lfail

        // epoll_fd = epoll_create1(0)
        mov     x0, #0
        mov     x8, #SYS_epoll_create1
        svc     #0
        tbnz    x0, #63, .Lfail
        mov     x20, x0

        // epoll_ctl(epoll_fd, ADD, listen_fd, {EPOLLIN, listen_fd})
        mov     x23, x19
        mov     w9, #EPOLLIN
        bl      .Lset_ev
        mov     x0, x20
        mov     x1, #EPOLL_CTL_ADD
        mov     x2, x19
        adrp    x3, ev
        add     x3, x3, #:lo12:ev
        mov     x8, #SYS_epoll_ctl
        svc     #0
        tbnz    x0, #63, .Lfail

// ---- the event loop ---------------------------------------------------------
.Lwait:
        // n = epoll_pwait(epoll_fd, events, MAX_EVENTS, -1, NULL, 0)
        // Blocks until at least one socket is ready. This is the only place the
        // process ever sleeps.
        mov     x0, x20
        adrp    x1, events
        add     x1, x1, #:lo12:events
        mov     x2, #MAX_EVENTS
        mov     x3, #-1                         // no timeout
        mov     x4, #0                          // no signal mask
        mov     x5, #0
        mov     x8, #SYS_epoll_pwait
        svc     #0
        cmp     x0, #0
        ble     .Lwait                          // EINTR, or nothing to do
        mov     x22, x0
        adrp    x21, events
        add     x21, x21, #:lo12:events

.Levent:
        ldr     w24, [x21]                      // .events
        ldr     w23, [x21, #EVENT_DATA_OFF]     // .data, which holds the fd

        cmp     x23, x19
        b.eq    .Laccept_more                   // the listening socket

        tst     w24, #(EPOLLERR | EPOLLHUP)
        b.ne    .Ldrop
        tst     w24, #EPOLLIN
        b.ne    .Ldo_read
        tst     w24, #EPOLLOUT
        b.ne    .Ldo_write

.Lnext:
        add     x21, x21, #EVENT_SIZE
        subs    x22, x22, #1
        b.ne    .Levent
        b       .Lwait

// ---- listening socket: drain the backlog ------------------------------------
.Laccept_more:
        // conn_fd = accept4(listen_fd, NULL, NULL, SOCK_NONBLOCK)
        // Loop until EAGAIN: epoll is level-triggered, but taking every pending
        // connection now saves a lap round the loop for each one.
        mov     x0, x19
        mov     x1, #0
        mov     x2, #0
        mov     x3, #SOCK_NONBLOCK
        mov     x8, #SYS_accept4
        svc     #0
        tbnz    x0, #63, .Lnext                 // EAGAIN: backlog is empty
        mov     x23, x0

        mov     x9, #MAX_FDS
        cmp     x23, x9
        b.hs    .Lrefuse                        // no room in the state table

        // Register it for reading. Being in the EPOLLIN set *is* the
        // "awaiting request" state; no separate state variable needed.
        mov     w9, #EPOLLIN
        bl      .Lset_ev
        mov     x0, x20
        mov     x1, #EPOLL_CTL_ADD
        mov     x2, x23
        adrp    x3, ev
        add     x3, x3, #:lo12:ev
        mov     x8, #SYS_epoll_ctl
        svc     #0
        b       .Laccept_more

.Lrefuse:
        mov     x0, x23
        mov     x8, #SYS_close
        svc     #0
        b       .Laccept_more

// ---- connection is readable -------------------------------------------------
.Ldo_read:
        mov     x0, x23
        adrp    x1, reqbuf
        add     x1, x1, #:lo12:reqbuf
        mov     x2, #REQBUF_SIZE
        mov     x8, #SYS_read
        svc     #0
        cmp     x0, #0
        ble     .Lread_err

        // The request is not parsed beyond "something arrived". Flip the
        // connection over to writing; the reply goes out on the next lap.
        adrp    x9, sent
        add     x9, x9, #:lo12:sent
        str     wzr, [x9, x23, lsl #2]
        mov     w9, #EPOLLOUT
        bl      .Lset_ev
        mov     x0, x20
        mov     x1, #EPOLL_CTL_MOD
        mov     x2, x23
        adrp    x3, ev
        add     x3, x3, #:lo12:ev
        mov     x8, #SYS_epoll_ctl
        svc     #0
        b       .Lnext

.Lread_err:
        cmn     x0, #EAGAIN                     // x0 == -EAGAIN ?
        b.eq    .Lnext                          // nothing yet; keep waiting
        b       .Ldrop                          // 0 = peer hung up, <0 = error

// ---- connection is writable -------------------------------------------------
.Ldo_write:
        // sendto(fd, response + sent, response_len - sent, MSG_NOSIGNAL, NULL, 0)
        // A short write just leaves the rest for the next EPOLLOUT.
        adrp    x9, sent
        add     x9, x9, #:lo12:sent
        ldr     w10, [x9, x23, lsl #2]
        adrp    x1, response
        add     x1, x1, #:lo12:response
        add     x1, x1, x10
        mov     x2, #response_len
        sub     x2, x2, x10
        mov     x0, x23
        mov     x3, #MSG_NOSIGNAL
        mov     x4, #0
        mov     x5, #0
        mov     x8, #SYS_sendto
        svc     #0
        cmp     x0, #0
        ble     .Lwrite_err

        adrp    x9, sent
        add     x9, x9, #:lo12:sent
        ldr     w10, [x9, x23, lsl #2]
        add     w10, w10, w0
        str     w10, [x9, x23, lsl #2]
        mov     x11, #response_len
        cmp     x10, x11
        b.lo    .Lnext                          // more to go
        b       .Ldrop                          // sent it all: Connection: close

.Lwrite_err:
        cmn     x0, #EAGAIN
        b.eq    .Lnext
        b       .Ldrop

// ---- done with a connection -------------------------------------------------
// close() removes the fd from the epoll set on its own, so no EPOLL_CTL_DEL.
.Ldrop:
        mov     x0, x23
        mov     x8, #SYS_close
        svc     #0
        b       .Lnext

// Fill `ev` with {events = w9, data = x23}. Clobbers x9, x10; returns via x30.
.Lset_ev:
        adrp    x10, ev
        add     x10, x10, #:lo12:ev
        str     w9, [x10]
        str     x23, [x10, #EVENT_DATA_OFF]
        ret

.Lfail:
        mov     x0, #1
        mov     x8, #SYS_exit
        svc     #0
