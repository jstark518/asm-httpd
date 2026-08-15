; http.asm — a minimal HTTP/1.1 server in x86-64 Linux assembly.
;
; No libc, no runtime: raw syscalls only, so the linked binary is fully static
; and can run in a `scratch` container.
;
;   nasm -f elf64 -o http.o http.asm
;   ld -o httpd http.o
;
; Serves one fixed response to every request on port 8080, one connection at a
; time (accept -> read -> reply -> close).

BITS 64
DEFAULT REL

; ---- syscall numbers (x86-64 Linux) -----------------------------------------
%define SYS_read        0
%define SYS_write       1
%define SYS_close       3
%define SYS_socket      41
%define SYS_accept      43
%define SYS_sendto      44
%define SYS_bind        49
%define SYS_listen      50
%define SYS_setsockopt  54
%define SYS_exit        60

; ---- socket constants -------------------------------------------------------
%define AF_INET         2
%define SOCK_STREAM     1
%define SOL_SOCKET      1
%define SO_REUSEADDR    2
%define MSG_NOSIGNAL    0x4000      ; write to a dead peer -> EPIPE, not SIGPIPE

%define PORT            8080
%define BACKLOG         128
%define REQBUF_SIZE     8192

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
reqbuf: resb REQBUF_SIZE

; -----------------------------------------------------------------------------
section .text
global _start

_start:
        ; listen_fd = socket(AF_INET, SOCK_STREAM, 0)
        mov     eax, SYS_socket
        mov     edi, AF_INET
        mov     esi, SOCK_STREAM
        xor     edx, edx
        syscall
        test    eax, eax
        js      .fail
        mov     r12d, eax                       ; r12 = listening socket

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

.accept:
        ; conn_fd = accept(listen_fd, NULL, NULL)
        mov     eax, SYS_accept
        mov     edi, r12d
        xor     esi, esi
        xor     edx, edx
        syscall
        test    eax, eax
        js      .accept                         ; EINTR and friends: just retry
        mov     r13d, eax                       ; r13 = connection socket

        ; read(conn_fd, reqbuf, REQBUF_SIZE)
        ; One read is enough here: the request is parsed no further than
        ; "something arrived", and draining it avoids an RST on close.
        mov     eax, SYS_read
        mov     edi, r13d
        lea     rsi, [reqbuf]
        mov     edx, REQBUF_SIZE
        syscall

        ; sendto(conn_fd, response, remaining, MSG_NOSIGNAL, NULL, 0)
        ; Looped, because a short write is legal even on a fresh socket.
        lea     rsi, [response]
        mov     edx, response_len
.send:
        mov     eax, SYS_sendto
        mov     edi, r13d
        mov     r10d, MSG_NOSIGNAL
        xor     r8d, r8d
        xor     r9d, r9d
        syscall
        test    rax, rax
        jle     .close                          ; peer gone or error: drop it
        add     rsi, rax
        sub     rdx, rax
        jnz     .send

.close:
        mov     eax, SYS_close
        mov     edi, r13d
        syscall
        jmp     .accept

.fail:
        mov     eax, SYS_exit
        mov     edi, 1
        syscall
