; http_x86_64.asm — a minimal HTTP/1.1 server in x86-64 Linux assembly.
; Single-threaded but concurrent: an epoll loop over non-blocking sockets.

BITS 64
DEFAULT REL

; ---- syscall numbers (x86-64 Linux) -----------------------------------------
%define SYS_read            0
%define SYS_close           3
%define SYS_socket          41
%define SYS_sendto          44
%define SYS_bind            49
%define SYS_listen          50
%define SYS_setsockopt      54
%define SYS_exit            60
%define SYS_epoll_ctl       233
%define SYS_epoll_pwait     281
%define SYS_accept4         288
%define SYS_epoll_create1   291

; ---- socket constants -------------------------------------------------------
%define AF_INET         2
%define SOCK_STREAM     1
%define SOCK_NONBLOCK   0x800
%define SOL_SOCKET      1
%define SO_REUSEADDR    2
%define MSG_NOSIGNAL    0x4000      ; write to a dead peer -> EPIPE, not SIGPIPE

; ---- epoll constants --------------------------------------------------------
%define EPOLL_CTL_ADD   1
%define EPOLL_CTL_MOD   3
%define EPOLLIN         0x001
%define EPOLLOUT        0x004
%define EPOLLERR        0x008
%define EPOLLHUP        0x010

; On x86-64 struct epoll_event is __attribute__((packed)): 4-byte events
; followed immediately by the 8-byte data union, so 12 bytes with data at
; offset 4. (On most other architectures it is padded to 16.)
%define EVENT_SIZE      12
%define EVENT_DATA_OFF  4

%define EAGAIN          11

%define PORT            8080
%define BACKLOG         128
%define REQBUF_SIZE     8192
%define MAX_EVENTS      64
%define MAX_FDS         4096        ; bounds the per-connection state table

; -----------------------------------------------------------------------------
section .rodata

; struct sockaddr_in { u16 family; u16 port; u32 addr; u8 pad[8]; }
; The port is stored big-endian (network byte order), hence the byte-wise write.
sockaddr:
        dw      AF_INET
        db      (PORT >> 8) & 0xff, PORT & 0xff
        dd      0                               ; INADDR_ANY
        dq      0                               ; sin_zero
sockaddr_len    equ $ - sockaddr

one:    dd      1                               ; value for SO_REUSEADDR

body:
        db      "Hello, world! Served by x86-64 assembly, no libc.", 10
body_len        equ $ - body

response:
        db      "HTTP/1.1 200 OK", 13, 10
        db      "Content-Type: text/plain; charset=utf-8", 13, 10
        db      "Content-Length: 50", 13, 10
        db      "Connection: close", 13, 10
        db      13, 10
        db      "Hello, world! Served by x86-64 assembly, no libc.", 10
response_len    equ $ - response

; Content-Length is a string literal, so assert at assembly time that it still
; matches the body. A mismatch here hangs clients; better to fail the build.
%if body_len != 50
  %error "Content-Length header is out of sync with the response body"
%endif

; -----------------------------------------------------------------------------
section .bss

; Every connection reads into the same buffer. That is safe only because the
; request is never parsed -- it is read to drain the socket and then discarded.
reqbuf: resb REQBUF_SIZE

events: resb MAX_EVENTS * EVENT_SIZE            ; epoll_pwait output

ev:                                             ; scratch epoll_event for _ctl
ev_events:      resd 1
ev_data:        resq 1

; Bytes of the response already sent, indexed by fd. Meaningful only while a
; connection is in the EPOLLOUT state.
sent:   resd MAX_FDS

; -----------------------------------------------------------------------------
section .text
global _start

; Register roles across the event loop:
;   r12 = listening socket   r13 = epoll fd
;   r14 = current event ptr  r15 = events remaining in this batch
;   rbx = current fd         rbp = current event mask
_start:
        ; listen_fd = socket(AF_INET, SOCK_STREAM|SOCK_NONBLOCK, 0)
        ; Non-blocking from birth, so accept() never stalls the loop.
        mov     eax, SYS_socket
        mov     edi, AF_INET
        mov     esi, SOCK_STREAM | SOCK_NONBLOCK
        xor     edx, edx
        syscall
        test    eax, eax
        js      .fail
        mov     r12d, eax

        ; setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        ; Lets the container restart without waiting out TIME_WAIT.
        mov     eax, SYS_setsockopt
        mov     edi, r12d
        mov     esi, SOL_SOCKET
        mov     edx, SO_REUSEADDR
        lea     r10, [one]
        mov     r8d, 4
        syscall

        ; bind(listen_fd, &sockaddr, sizeof sockaddr)
        mov     eax, SYS_bind
        mov     edi, r12d
        lea     rsi, [sockaddr]
        mov     edx, sockaddr_len
        syscall
        test    eax, eax
        js      .fail

        ; listen(listen_fd, BACKLOG)
        mov     eax, SYS_listen
        mov     edi, r12d
        mov     esi, BACKLOG
        syscall
        test    eax, eax
        js      .fail

        ; epoll_fd = epoll_create1(0)
        mov     eax, SYS_epoll_create1
        xor     edi, edi
        syscall
        test    eax, eax
        js      .fail
        mov     r13d, eax

        ; epoll_ctl(epoll_fd, ADD, listen_fd, {EPOLLIN, listen_fd})
        mov     dword [ev_events], EPOLLIN
        mov     ebx, r12d
        mov     [ev_data], rbx
        mov     eax, SYS_epoll_ctl
        mov     edi, r13d
        mov     esi, EPOLL_CTL_ADD
        mov     edx, r12d
        lea     r10, [ev]
        syscall
        test    eax, eax
        js      .fail

; ---- the event loop ---------------------------------------------------------
.wait:
        ; n = epoll_pwait(epoll_fd, events, MAX_EVENTS, -1, NULL, 0)
        ; Blocks until at least one socket is ready. This is the only place the
        ; process ever sleeps.
        mov     eax, SYS_epoll_pwait
        mov     edi, r13d
        lea     rsi, [events]
        mov     edx, MAX_EVENTS
        mov     r10d, -1                        ; no timeout
        xor     r8d, r8d                        ; no signal mask
        xor     r9d, r9d
        syscall
        test    eax, eax
        jle     .wait                           ; EINTR, or nothing to do
        mov     r15d, eax
        lea     r14, [events]

.event:
        mov     ebp, [r14]                      ; .events
        mov     ebx, [r14 + EVENT_DATA_OFF]     ; .data, which holds the fd

        cmp     ebx, r12d
        je      .accept_more                    ; the listening socket

        test    ebp, EPOLLERR | EPOLLHUP
        jnz     .drop
        test    ebp, EPOLLIN
        jnz     .do_read
        test    ebp, EPOLLOUT
        jnz     .do_write

.next:
        add     r14, EVENT_SIZE
        dec     r15d
        jnz     .event
        jmp     .wait

; ---- listening socket: drain the backlog ------------------------------------
.accept_more:
        ; conn_fd = accept4(listen_fd, NULL, NULL, SOCK_NONBLOCK)
        ; Loop until EAGAIN: epoll is level-triggered, but taking every pending
        ; connection now saves a lap round the loop for each one.
        mov     eax, SYS_accept4
        mov     edi, r12d
        xor     esi, esi
        xor     edx, edx
        mov     r10d, SOCK_NONBLOCK
        syscall
        test    eax, eax
        js      .next                           ; EAGAIN: backlog is empty
        mov     ebx, eax

        cmp     ebx, MAX_FDS
        jae     .refuse                         ; no room in the state table

        ; Register it for reading. Being in the EPOLLIN set *is* the
        ; "awaiting request" state; no separate state variable needed.
        mov     dword [ev_events], EPOLLIN
        mov     [ev_data], rbx
        mov     eax, SYS_epoll_ctl
        mov     edi, r13d
        mov     esi, EPOLL_CTL_ADD
        mov     edx, ebx
        lea     r10, [ev]
        syscall
        jmp     .accept_more

.refuse:
        mov     eax, SYS_close
        mov     edi, ebx
        syscall
        jmp     .accept_more

; ---- connection is readable -------------------------------------------------
.do_read:
        mov     eax, SYS_read
        mov     edi, ebx
        lea     rsi, [reqbuf]
        mov     edx, REQBUF_SIZE
        syscall
        test    rax, rax
        jle     .read_err

        ; The request is not parsed beyond "something arrived". Flip the
        ; connection over to writing; the reply goes out on the next lap.
        mov     dword [sent + rbx*4], 0
        mov     dword [ev_events], EPOLLOUT
        mov     [ev_data], rbx
        mov     eax, SYS_epoll_ctl
        mov     edi, r13d
        mov     esi, EPOLL_CTL_MOD
        mov     edx, ebx
        lea     r10, [ev]
        syscall
        jmp     .next

.read_err:
        cmp     rax, -EAGAIN
        je      .next                           ; nothing yet; keep waiting
        jmp     .drop                           ; 0 = peer hung up, <0 = error

; ---- connection is writable -------------------------------------------------
.do_write:
        ; sendto(fd, response + sent, response_len - sent, MSG_NOSIGNAL, NULL, 0)
        ; A short write just leaves the rest for the next EPOLLOUT.
        mov     ecx, [sent + rbx*4]
        lea     rsi, [response]
        add     rsi, rcx
        mov     edx, response_len
        sub     edx, ecx
        mov     eax, SYS_sendto
        mov     edi, ebx
        mov     r10d, MSG_NOSIGNAL
        xor     r8d, r8d
        xor     r9d, r9d
        syscall
        test    rax, rax
        jle     .write_err

        add     [sent + rbx*4], eax
        mov     ecx, [sent + rbx*4]
        cmp     ecx, response_len
        jb      .next                           ; more to go
        jmp     .drop                           ; sent it all: Connection: close

.write_err:
        cmp     rax, -EAGAIN
        je      .next
        jmp     .drop

; ---- done with a connection -------------------------------------------------
; close() removes the fd from the epoll set on its own, so no EPOLL_CTL_DEL.
.drop:
        mov     eax, SYS_close
        mov     edi, ebx
        syscall
        jmp     .next

.fail:
        mov     eax, SYS_exit
        mov     edi, 1
        syscall
