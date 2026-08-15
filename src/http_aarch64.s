// http_aarch64.s — a minimal HTTP/1.1 server in AArch64 Linux assembly.
// Single-threaded but concurrent: an epoll loop over non-blocking sockets.

// ---- syscall numbers (AArch64 Linux) ----------------------------------------
.set SYS_read,          63
.set SYS_write,         64
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
.set STDOUT,            1
.set CH_DOT,            46
.set CH_COLON,          58
.set CH_SPACE,          32
.set CH_ZERO,           48
.set CH_CR,             13
.set CH_LF,             10

.set PORT_HI,           0x1f       // 8080 = 0x1f90, stored big-endian
.set PORT_LO,           0x90
.set BACKLOG,           128
.set MAX_EVENTS,        64
.set MAX_FDS,           1024       // bounds the per-connection state tables
.set CONN_BUF_SHIFT,    12
.set CONN_BUF,          (1 << CONN_BUF_SHIFT)

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

// Per-connection request buffers, indexed by fd. Headers are parsed rather than
// discarded, and they arrive a fragment at a time interleaved with other
// connections, so each fd needs somewhere of its own to accumulate.
reqbufs:
        .skip   MAX_FDS * CONN_BUF

rlen:                                      // bytes buffered, per fd
        .skip   MAX_FDS * 4
sent:                                      // response bytes sent, per fd
        .skip   MAX_FDS * 4

// Peer address per fd, captured at accept: 4 bytes of IPv4 then 2 of port, both
// still in network byte order.
peers:
        .skip   MAX_FDS * 8

acceptaddr:                                // sockaddr_in filled by accept4
        .skip   16
acceptlen:                                 // its length, in and out
        .skip   4

events:                                    // epoll_pwait output
        .skip   MAX_EVENTS * EVENT_SIZE

ev:                                        // scratch epoll_event for _ctl
        .skip   EVENT_SIZE

logpfx:                                    // "255.255.255.255:65535 "
        .skip   32
numtmp:                                    // digit scratch for utoa
        .skip   8

// -----------------------------------------------------------------------------
.section .text
.global _start

// Register roles across the event loop:
//   x19 = listening socket   x20 = epoll fd
//   x21 = current event ptr  x22 = events remaining in this batch
//   x23 = current fd         x24 = current event mask
//   x25 = connection buffer  x26 = bytes buffered
//   x27 = log length         x28 = log prefix base
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
        // conn_fd = accept4(listen_fd, &acceptaddr, &acceptlen, SOCK_NONBLOCK)
        // Loop until EAGAIN: epoll is level-triggered, but taking every pending
        // connection now saves a lap round the loop for each one.
        adrp    x9, acceptlen
        add     x9, x9, #:lo12:acceptlen
        mov     w10, #16                        // kernel overwrites this
        str     w10, [x9]
        mov     x0, x19
        adrp    x1, acceptaddr
        add     x1, x1, #:lo12:acceptaddr
        mov     x2, x9
        mov     x3, #SOCK_NONBLOCK
        mov     x8, #SYS_accept4
        svc     #0
        tbnz    x0, #63, .Lnext                 // EAGAIN: backlog is empty
        mov     x23, x0

        mov     x9, #MAX_FDS
        cmp     x23, x9
        b.hs    .Lrefuse                        // no room in the state tables

        // Stash the peer address now; by the time the request is logged the
        // accept buffer will have been reused by later connections.
        adrp    x9, acceptaddr
        add     x9, x9, #:lo12:acceptaddr
        ldr     w10, [x9, #4]                   // sin_addr
        ldrh    w11, [x9, #2]                   // sin_port
        adrp    x9, peers
        add     x9, x9, #:lo12:peers
        add     x9, x9, x23, lsl #3
        str     w10, [x9]
        strh    w11, [x9, #4]

        // fd numbers get recycled, so clear this slot before reusing it.
        adrp    x9, rlen
        add     x9, x9, #:lo12:rlen
        str     wzr, [x9, x23, lsl #2]

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
// Accumulate until the header block is complete -- that is, until a blank line
// shows up -- then log the lot and reply.
.Ldo_read:
        adrp    x25, reqbufs
        add     x25, x25, #:lo12:reqbufs
        add     x25, x25, x23, lsl #CONN_BUF_SHIFT      // this conn's buffer
        adrp    x9, rlen
        add     x9, x9, #:lo12:rlen
        ldr     w26, [x9, x23, lsl #2]                  // bytes already buffered
        mov     x2, #CONN_BUF
        sub     x2, x2, x26                             // space left
        cbz     x2, .Ldrop                              // headers too big

        // read(fd, buf + off, space)
        add     x1, x25, x26
        mov     x0, x23
        mov     x8, #SYS_read
        svc     #0
        cmp     x0, #0
        ble     .Lread_err

        add     w26, w26, w0                            // newlen = off + n
        adrp    x9, rlen
        add     x9, x9, #:lo12:rlen
        str     w26, [x9, x23, lsl #2]

        // Hunt for the blank line that ends the headers: "\n\n" or "\n\r\n".
        // Rescanning from the start each time is O(n^2), but n is a few hundred
        // bytes and it keeps the resumption logic to nothing.
        mov     x9, #0
.Lscan:
        add     x10, x9, #1
        cmp     x10, x26
        b.hs    .Lneed_more                     // need at least two bytes
        ldrb    w11, [x25, x9]
        cmp     w11, #CH_LF
        b.ne    .Lscan_next
        ldrb    w11, [x25, x10]
        cmp     w11, #CH_LF
        b.eq    .Lfound_lf
        cmp     w11, #CH_CR
        b.ne    .Lscan_next
        add     x10, x9, #2
        cmp     x10, x26
        b.hs    .Lneed_more                     // saw "\n\r", nothing after yet
        ldrb    w11, [x25, x10]
        cmp     w11, #CH_LF
        b.eq    .Lfound_crlf
.Lscan_next:
        add     x9, x9, #1
        b       .Lscan

.Lfound_lf:
        add     x26, x9, #2                     // bytes of header block
        b       .Lhave_headers
.Lfound_crlf:
        add     x26, x9, #3
        b       .Lhave_headers

.Lneed_more:
        mov     x10, #CONN_BUF
        cmp     x26, x10
        b.hs    .Ldrop                          // buffer full, no blank line
        b       .Lnext                          // stay in EPOLLIN for the rest

.Lread_err:
        cmn     x0, #EAGAIN                     // x0 == -EAGAIN ?
        b.eq    .Lnext                          // nothing yet; keep waiting
        b       .Ldrop                          // 0 = peer hung up, <0 = error

// ---- log the request --------------------------------------------------------
// Two writes, back to back: "ip:port " out of a scratch buffer, then the header
// block straight out of the connection buffer. Nothing else can log in between,
// so the pair stays contiguous without a copy into one place.
//
// x25 = buffer base, x26 = length of the header block.
.Lhave_headers:
        // Strip CRs in place so the log holds clean lines. dst never overtakes
        // src, so this is safe to do without a second buffer.
        mov     x9, #0                          // src index
        mov     x27, #0                         // dst index
.Lstrip:
        cmp     x9, x26
        b.hs    .Lstripped
        ldrb    w10, [x25, x9]
        add     x9, x9, #1
        cmp     w10, #CH_CR
        b.eq    .Lstrip
        strb    w10, [x25, x27]
        add     x27, x27, #1
        b       .Lstrip
.Lstripped:

        // Build "ip:port " -- four octets and a port, all straight out of the
        // network-order bytes stashed at accept time.
        adrp    x28, logpfx
        add     x28, x28, #:lo12:logpfx
        mov     x1, x28                         // running dest
        adrp    x11, peers
        add     x11, x11, #:lo12:peers
        add     x11, x11, x23, lsl #3
        ldrb    w0, [x11, #0]
        bl      .Lutoa
        mov     w10, #CH_DOT
        strb    w10, [x1], #1
        ldrb    w0, [x11, #1]
        bl      .Lutoa
        mov     w10, #CH_DOT
        strb    w10, [x1], #1
        ldrb    w0, [x11, #2]
        bl      .Lutoa
        mov     w10, #CH_DOT
        strb    w10, [x1], #1
        ldrb    w0, [x11, #3]
        bl      .Lutoa
        mov     w10, #CH_COLON
        strb    w10, [x1], #1
        ldrh    w0, [x11, #4]
        rev16   w0, w0                          // ntohs
        bl      .Lutoa
        mov     w10, #CH_SPACE
        strb    w10, [x1], #1

        sub     x2, x1, x28                     // prefix length
        mov     x1, x28
        bl      .Lwrite_all

        mov     x1, x25
        mov     x2, x27
        bl      .Lwrite_all

.Lto_send:
        // Flip the connection over to writing; the reply goes out next lap.
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

// -----------------------------------------------------------------------------
// Fill `ev` with {events = w9, data = x23}. Clobbers x9, x10; returns via x30.
.Lset_ev:
        adrp    x10, ev
        add     x10, x10, #:lo12:ev
        str     w9, [x10]
        str     x23, [x10, #EVENT_DATA_OFF]
        ret

// write_all(x1 = buf, x2 = len) -- push it all to stdout, short writes and all.
// Gives up silently if stdout has gone away. Clobbers x0, x1, x2, x8.
//
// This is the one blocking call in the whole loop: if the container's log pipe
// backs up, every connection waits behind it.
.Lwrite_all:
        cbz     x2, .Lwa_done
.Lwa_loop:
        mov     x0, #STDOUT
        mov     x8, #SYS_write
        svc     #0
        cmp     x0, #0
        ble     .Lwa_done
        add     x1, x1, x0
        subs    x2, x2, x0
        b.ne    .Lwa_loop
.Lwa_done:
        ret

// utoa(w0 = value, x1 = dest) -- write the value in decimal, return x1 just
// past the last digit. Digits fall out backwards, so they land in a scratch
// buffer first and get copied over. Clobbers x0, x9, x10, x12, x13, x14, x15.
.Lutoa:
        adrp    x12, numtmp
        add     x12, x12, #:lo12:numtmp
        add     x13, x12, #8                    // one past the end
        mov     x14, x13                        // cursor, walking backwards
        mov     w15, #10
.Lu_digit:
        udiv    w9, w0, w15
        msub    w10, w9, w15, w0                // w10 = value % 10
        add     w10, w10, #CH_ZERO
        sub     x14, x14, #1
        strb    w10, [x14]
        mov     w0, w9
        cbnz    w0, .Lu_digit
.Lu_copy:
        ldrb    w10, [x14]
        strb    w10, [x1], #1
        add     x14, x14, #1
        cmp     x14, x13
        b.lo    .Lu_copy
        ret

.Lfail:
        mov     x0, #1
        mov     x8, #SYS_exit
        svc     #0
