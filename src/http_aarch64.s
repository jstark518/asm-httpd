// http_aarch64.s — a minimal HTTP/1.1 server in AArch64 Linux assembly.

// ---- syscall numbers (AArch64 Linux) ----------------------------------------
.set SYS_read,          63
.set SYS_close,         57
.set SYS_exit,          93
.set SYS_socket,        198
.set SYS_bind,          200
.set SYS_listen,        201
.set SYS_accept,        202
.set SYS_sendto,        206
.set SYS_setsockopt,    208

// ---- socket constants -------------------------------------------------------
.set AF_INET,           2
.set SOCK_STREAM,       1
.set SOL_SOCKET,        1
.set SO_REUSEADDR,      2
.set MSG_NOSIGNAL,      0x4000     // dead peer -> EPIPE, not SIGPIPE

.set PORT_HI,           0x1f       // 8080 = 0x1f90, stored big-endian
.set PORT_LO,           0x90
.set BACKLOG,           128
.set REQBUF_SIZE,       8192

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
reqbuf:
        .skip   REQBUF_SIZE

// -----------------------------------------------------------------------------
.section .text
.global _start

_start:
        // listen_fd = socket(AF_INET, SOCK_STREAM, 0)
        mov     x0, #AF_INET
        mov     x1, #SOCK_STREAM
        mov     x2, #0
        mov     x8, #SYS_socket
        svc     #0
        tbnz    x0, #63, .Lfail                 // negative return -> error
        mov     x19, x0                         // x19 = listening socket

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

.Laccept:
        // conn_fd = accept(listen_fd, NULL, NULL)
        mov     x0, x19
        mov     x1, #0
        mov     x2, #0
        mov     x8, #SYS_accept
        svc     #0
        tbnz    x0, #63, .Laccept               // EINTR and friends: just retry
        mov     x20, x0                         // x20 = connection socket

        // read(conn_fd, reqbuf, REQBUF_SIZE)
        // One read is enough here: the request is parsed no further than
        // "something arrived", and draining it avoids an RST on close.
        mov     x0, x20
        adrp    x1, reqbuf
        add     x1, x1, #:lo12:reqbuf
        mov     x2, #REQBUF_SIZE
        mov     x8, #SYS_read
        svc     #0

        // sendto(conn_fd, response, remaining, MSG_NOSIGNAL, NULL, 0)
        // Looped, because a short write is legal even on a fresh socket.
        adrp    x21, response
        add     x21, x21, #:lo12:response
        mov     x22, #response_len
.Lsend:
        mov     x0, x20
        mov     x1, x21
        mov     x2, x22
        mov     x3, #MSG_NOSIGNAL
        mov     x4, #0
        mov     x5, #0
        mov     x8, #SYS_sendto
        svc     #0
        cmp     x0, #0
        ble     .Lclose                         // peer gone or error: drop it
        add     x21, x21, x0
        subs    x22, x22, x0
        bne     .Lsend

.Lclose:
        mov     x0, x20
        mov     x8, #SYS_close
        svc     #0
        b       .Laccept

.Lfail:
        mov     x0, #1
        mov     x8, #SYS_exit
        svc     #0
