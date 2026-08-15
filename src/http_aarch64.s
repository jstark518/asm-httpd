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
.set CH_QUOTE,          34
.set CH_COMMA,          44
.set CH_LBRACE,         123
.set CH_RBRACE,         125
.set CH_BACKSLASH,      92

.set PORT_HI,           0x1f       // 8080 = 0x1f90, stored big-endian
.set PORT_LO,           0x90
.set BACKLOG,           128
.set MAX_EVENTS,        64
.set MAX_FDS,           1024       // bounds the per-connection state tables
.set CONN_BUF_SHIFT,    12
.set CONN_BUF,          (1 << CONN_BUF_SHIFT)
.set JSONLOG_MAX,       4096       // parsed body lines are built up here

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

// The header we hunt for in the request, lowercased for case-folded matching.
cl_name:
        .ascii  "content-length:"
.set cl_name_len, . - cl_name

s_indent:
        .ascii  "  "
.set s_indent_len, . - s_indent
s_eq:
        .ascii  " = "
.set s_eq_len, . - s_eq
s_nl:
        .byte   CH_LF
s_bad:
        .ascii  "  <malformed JSON>\n"
.set s_bad_len, . - s_bad
s_nonjson_a:
        .ascii  "  <non-JSON body, "
.set s_nonjson_a_len, . - s_nonjson_a
s_nonjson_b:
        .ascii  " bytes>\n"
.set s_nonjson_b_len, . - s_nonjson_b

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

// Where the body starts, per fd -- the offset just past the blank line. Zero
// means the header block has not landed yet, which doubles as the sub-state
// flag inside the reading phase: no real request can have a body at offset 0.
hdrend:
        .skip   MAX_FDS * 4
clen:                                      // Content-Length, per fd
        .skip   MAX_FDS * 4
hlog:                                      // header bytes after CR-stripping
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
numbuf:                                    // formatted number, for jappend
        .skip   16

// The parsed body is assembled here as text and written in one go, rather than
// a syscall per key.
jsonlog:
        .skip   JSONLOG_MAX
jlen:                                      // bytes used in jsonlog
        .skip   4
jlinestart:                                // jlen at the start of this pair
        .skip   4

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
        adrp    x9, hdrend
        add     x9, x9, #:lo12:hdrend
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
// Two phases, told apart by hdrend: accumulate until the blank line that ends
// the headers, then keep going until Content-Length bytes of body have landed.
// Only once the whole request is in does anything get logged, so a request's
// output stays in one piece even while other connections are mid-flight.
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

        adrp    x9, hdrend
        add     x9, x9, #:lo12:hdrend
        ldr     w10, [x9, x23, lsl #2]
        cbnz    w10, .Lcheck_body                       // headers already done

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

// ---- headers are in ---------------------------------------------------------
// Note the body offset, tidy the headers up for logging, and find out how much
// body to expect. Runs exactly once per connection; the hdrend check above
// keeps later reads out of here.
//
// x25 = buffer base, x26 = raw length of the header block.
.Lhave_headers:
        adrp    x9, hdrend
        add     x9, x9, #:lo12:hdrend
        str     w26, [x9, x23, lsl #2]          // body starts here

        // Strip CRs in place so the log holds clean lines. dst never overtakes
        // src, so this is safe to do without a second buffer. Only the headers
        // are touched -- body bytes already sitting past hdrend stay put.
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
        adrp    x9, hlog
        add     x9, x9, #:lo12:hlog
        str     w27, [x9, x23, lsl #2]          // header bytes worth logging

        // Content-Length off the tidied headers, where lines end in a bare \n.
        mov     x1, x25
        mov     x2, x27
        bl      .Lfind_clen
        adrp    x9, clen
        add     x9, x9, #:lo12:clen
        str     w0, [x9, x23, lsl #2]

        // Refuse anything whose body cannot fit alongside its headers.
        adrp    x9, hdrend
        add     x9, x9, #:lo12:hdrend
        ldr     w10, [x9, x23, lsl #2]
        add     w10, w10, w0
        mov     w11, #CONN_BUF
        cmp     w10, w11
        b.hi    .Ldrop

// ---- is the whole request in yet? -------------------------------------------
.Lcheck_body:
        adrp    x9, hdrend
        add     x9, x9, #:lo12:hdrend
        ldr     w10, [x9, x23, lsl #2]
        adrp    x9, clen
        add     x9, x9, #:lo12:clen
        ldr     w11, [x9, x23, lsl #2]
        add     w10, w10, w11                   // bytes the full request needs
        adrp    x9, rlen
        add     x9, x9, #:lo12:rlen
        ldr     w12, [x9, x23, lsl #2]
        cmp     w12, w10
        b.lo    .Lnext                          // still waiting on body

// ---- log the request --------------------------------------------------------
// Writes go out back to back and nothing else can log in between, so the pieces
// stay contiguous without being copied into one place first.
.Lcomplete:
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

        adrp    x9, hlog
        add     x9, x9, #:lo12:hlog
        ldr     w2, [x9, x23, lsl #2]
        mov     x1, x25
        bl      .Lwrite_all

        // Nothing more to say if the request had no body.
        adrp    x9, clen
        add     x9, x9, #:lo12:clen
        ldr     w26, [x9, x23, lsl #2]
        cbz     w26, .Lto_send

        // Body: parse it as JSON if it looks like JSON, otherwise just say how
        // big it was. Either way the result is assembled in jsonlog and written
        // once, rather than a syscall per key.
        adrp    x9, jlen
        add     x9, x9, #:lo12:jlen
        str     wzr, [x9]
        adrp    x9, hdrend
        add     x9, x9, #:lo12:hdrend
        ldr     w10, [x9, x23, lsl #2]
        add     x27, x25, x10                   // x27 = body

        mov     x11, #0                         // sniff past leading whitespace
.Lsniff:
        cmp     x11, x26
        b.hs    .Lnonjson
        ldrb    w12, [x27, x11]
        cmp     w12, #CH_SPACE
        b.hi    .Lsniffed
        add     x11, x11, #1
        b       .Lsniff
.Lsniffed:
        cmp     w12, #CH_LBRACE
        b.ne    .Lnonjson
        mov     x1, x27
        mov     x2, x26
        bl      .Ljson_log
        b       .Llogged

.Lnonjson:
        adrp    x1, s_nonjson_a
        add     x1, x1, #:lo12:s_nonjson_a
        mov     x2, #s_nonjson_a_len
        bl      .Ljappend
        adrp    x1, numbuf
        add     x1, x1, #:lo12:numbuf
        mov     x28, x1
        mov     w0, w26
        bl      .Lutoa
        sub     x2, x1, x28
        mov     x1, x28
        bl      .Ljappend
        adrp    x1, s_nonjson_b
        add     x1, x1, #:lo12:s_nonjson_b
        mov     x2, #s_nonjson_b_len
        bl      .Ljappend

.Llogged:
        // Blank line so consecutive requests stay readable.
        adrp    x1, s_nl
        add     x1, x1, #:lo12:s_nl
        mov     x2, #1
        bl      .Ljappend
        adrp    x1, jsonlog
        add     x1, x1, #:lo12:jsonlog
        adrp    x9, jlen
        add     x9, x9, #:lo12:jlen
        ldr     w2, [x9]
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

// find_clen(x1 = headers, x2 = len) -> w0 -- the Content-Length value, or 0 if
// the header is absent. Expects CR-stripped headers, so lines end in \n.
// Matching is case-folded with ORR 0x20, which leaves ':' and '-' alone.
.Lfind_clen:
        mov     x3, #0                          // index of the current line
.Lfc_line:
        mov     x4, #0                          // how much of the name matched
.Lfc_cmp:
        mov     x5, #cl_name_len
        cmp     x4, x5
        b.hs    .Lfc_hit
        add     x6, x3, x4
        cmp     x6, x2
        b.hs    .Lfc_none                       // ran off the end mid-name
        ldrb    w7, [x1, x6]
        orr     w7, w7, #0x20                   // fold to lower case
        adrp    x9, cl_name
        add     x9, x9, #:lo12:cl_name
        ldrb    w10, [x9, x4]
        cmp     w7, w10
        b.ne    .Lfc_next
        add     x4, x4, #1
        b       .Lfc_cmp

.Lfc_hit:
        mov     x5, #cl_name_len
        add     x6, x3, x5
.Lfc_space:
        cmp     x6, x2
        b.hs    .Lfc_none
        ldrb    w7, [x1, x6]
        cmp     w7, #CH_SPACE
        b.ne    .Lfc_digits
        add     x6, x6, #1
        b       .Lfc_space
.Lfc_digits:
        mov     w0, #0
.Lfc_digit:
        cmp     x6, x2
        b.hs    .Lfc_ret
        ldrb    w7, [x1, x6]
        sub     w7, w7, #CH_ZERO
        cmp     w7, #9
        b.hi    .Lfc_ret
        mov     w9, #10
        madd    w0, w0, w9, w7
        add     x6, x6, #1
        b       .Lfc_digit
.Lfc_ret:
        ret

.Lfc_next:
        // Skip to the start of the next line and try again.
        cmp     x3, x2
        b.hs    .Lfc_none
        ldrb    w7, [x1, x3]
        cmp     w7, #CH_LF
        b.eq    .Lfc_advance
        add     x3, x3, #1
        b       .Lfc_next
.Lfc_advance:
        add     x3, x3, #1
        cmp     x3, x2
        b.hs    .Lfc_none
        b       .Lfc_line

.Lfc_none:
        mov     w0, #0
        ret

// jappend(x1 = src, x2 = len) -- tack bytes onto jsonlog, silently truncating
// if it would overflow. Deliberately leaves x9-x15 alone so the parser can keep
// its cursor and token registers across a call.
.Ljappend:
        adrp    x3, jlen
        add     x3, x3, #:lo12:jlen
        ldr     w4, [x3]
        mov     w5, #JSONLOG_MAX
        sub     w5, w5, w4                      // space remaining
        cmp     x2, x5
        b.ls    .Lja_fits
        mov     x2, x5                          // truncate
.Lja_fits:
        cbz     x2, .Lja_done
        add     w6, w4, w2
        str     w6, [x3]
        adrp    x0, jsonlog
        add     x0, x0, #:lo12:jsonlog
        add     x0, x0, x4                      // dst
.Lja_copy:
        ldrb    w7, [x1], #1
        strb    w7, [x0], #1
        subs    x2, x2, #1
        b.ne    .Lja_copy
.Lja_done:
        ret

// json_log(x1 = body, x2 = len) -- parse a flat JSON object and append one
// "  key = value" line per pair to jsonlog.
//
// Deliberately shallow: top-level scalars only, and string contents are logged
// raw rather than unescaped, so "a\nb" appears with its backslash intact. What
// it does handle is \" inside strings, so an escaped quote does not end a token
// early. Anything it cannot make sense of collapses to <malformed JSON>, with
// the half-built line rolled back so the output stays tidy.
//
// x9 = cursor, x10 = end, x11/x12 = current token, x13 = byte scratch,
// x14 = scan_string error flag.
.Ljson_log:
        stp     x29, x30, [sp, #-16]!
        mov     x9, x1                          // cursor
        add     x10, x1, x2                     // end
        bl      .Ljl_mark

        bl      .Lskip_ws
        cmp     x9, x10
        b.hs    .Ljl_bad
        ldrb    w13, [x9]
        cmp     w13, #CH_LBRACE
        b.ne    .Ljl_bad
        add     x9, x9, #1
        bl      .Lskip_ws
        cmp     x9, x10
        b.hs    .Ljl_bad
        ldrb    w13, [x9]
        cmp     w13, #CH_RBRACE
        b.eq    .Ljl_done                       // {} is legal and boring

.Ljl_pair:
        bl      .Ljl_mark                       // rollback point for this line
        bl      .Lskip_ws
        cmp     x9, x10
        b.hs    .Ljl_bad
        ldrb    w13, [x9]
        cmp     w13, #CH_QUOTE
        b.ne    .Ljl_bad
        bl      .Lscan_string
        cbnz    x14, .Ljl_bad

        adrp    x1, s_indent
        add     x1, x1, #:lo12:s_indent
        mov     x2, #s_indent_len
        bl      .Ljappend
        mov     x1, x11
        mov     x2, x12
        bl      .Ljappend
        adrp    x1, s_eq
        add     x1, x1, #:lo12:s_eq
        mov     x2, #s_eq_len
        bl      .Ljappend

        bl      .Lskip_ws
        cmp     x9, x10
        b.hs    .Ljl_bad
        ldrb    w13, [x9]
        cmp     w13, #CH_COLON
        b.ne    .Ljl_bad
        add     x9, x9, #1
        bl      .Lskip_ws
        cmp     x9, x10
        b.hs    .Ljl_bad

        ldrb    w13, [x9]
        cmp     w13, #CH_QUOTE
        b.eq    .Ljl_vstring
        // Bare scalar -- number, true, false, null. Runs to whitespace or to
        // whatever punctuation ends the pair.
        mov     x11, x9
.Ljl_vscan:
        cmp     x9, x10
        b.hs    .Ljl_vend
        ldrb    w13, [x9]
        cmp     w13, #CH_COMMA
        b.eq    .Ljl_vend
        cmp     w13, #CH_RBRACE
        b.eq    .Ljl_vend
        cmp     w13, #CH_SPACE
        b.ls    .Ljl_vend
        add     x9, x9, #1
        b       .Ljl_vscan
.Ljl_vend:
        sub     x12, x9, x11
        cbz     x12, .Ljl_bad                   // ':' with nothing after it
        b       .Ljl_vemit

.Ljl_vstring:
        bl      .Lscan_string
        cbnz    x14, .Ljl_bad

.Ljl_vemit:
        mov     x1, x11
        mov     x2, x12
        bl      .Ljappend
        adrp    x1, s_nl
        add     x1, x1, #:lo12:s_nl
        mov     x2, #1
        bl      .Ljappend

        bl      .Lskip_ws
        cmp     x9, x10
        b.hs    .Ljl_bad
        ldrb    w13, [x9]
        cmp     w13, #CH_COMMA
        b.ne    .Ljl_maybe_close
        add     x9, x9, #1
        b       .Ljl_pair
.Ljl_maybe_close:
        cmp     w13, #CH_RBRACE
        b.ne    .Ljl_bad

.Ljl_done:
        ldp     x29, x30, [sp], #16
        ret

.Ljl_bad:
        // Throw away the partial line, then say so.
        adrp    x15, jlinestart
        add     x15, x15, #:lo12:jlinestart
        ldr     w14, [x15]
        adrp    x13, jlen
        add     x13, x13, #:lo12:jlen
        str     w14, [x13]
        adrp    x1, s_bad
        add     x1, x1, #:lo12:s_bad
        mov     x2, #s_bad_len
        bl      .Ljappend
        b       .Ljl_done

// Remember where this log line began, so a parse failure can roll it back.
.Ljl_mark:
        adrp    x13, jlen
        add     x13, x13, #:lo12:jlen
        ldr     w14, [x13]
        adrp    x15, jlinestart
        add     x15, x15, #:lo12:jlinestart
        str     w14, [x15]
        ret

// Advance the cursor past spaces, tabs, CRs and newlines.
.Lskip_ws:
        cmp     x9, x10
        b.hs    .Lsw_ret
        ldrb    w13, [x9]
        cmp     w13, #CH_SPACE
        b.hi    .Lsw_ret
        add     x9, x9, #1
        b       .Lskip_ws
.Lsw_ret:
        ret

// Cursor sits on the opening quote. Sets x11/x12 to the contents and leaves the
// cursor past the closing quote. x14 nonzero if the string never closes.
.Lscan_string:
        mov     x14, #0
        add     x9, x9, #1
        mov     x11, x9
.Lss_scan:
        cmp     x9, x10
        b.hs    .Lss_err
        ldrb    w13, [x9]
        cmp     w13, #CH_BACKSLASH
        b.eq    .Lss_escape
        cmp     w13, #CH_QUOTE
        b.eq    .Lss_close
        add     x9, x9, #1
        b       .Lss_scan
.Lss_escape:
        add     x9, x9, #2
        b       .Lss_scan
.Lss_close:
        sub     x12, x9, x11
        add     x9, x9, #1
        ret
.Lss_err:
        mov     x14, #1
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
