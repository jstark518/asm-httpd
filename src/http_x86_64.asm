; http_x86_64.asm — a minimal HTTP/1.1 server in x86-64 Linux assembly.
; Single-threaded but concurrent: an epoll loop over non-blocking sockets.

BITS 64
DEFAULT REL

; ---- syscall numbers (x86-64 Linux) -----------------------------------------
%define SYS_read            0
%define SYS_write           1
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
%define STDOUT          1

%define PORT            8080
%define BACKLOG         128
%define MAX_EVENTS      64
%define MAX_FDS         1024        ; bounds the per-connection state tables
%define CONN_BUF_SHIFT  12
%define CONN_BUF        (1 << CONN_BUF_SHIFT)
%define JSONLOG_MAX     4096        ; parsed body lines are built up here

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

; The header we hunt for in the request, lowercased for case-folded matching.
cl_name:        db "content-length:"
cl_name_len     equ $ - cl_name

s_indent:       db "  "
s_indent_len    equ $ - s_indent
s_eq:           db " = "
s_eq_len        equ $ - s_eq
s_nl:           db 10
s_bad:          db "  <malformed JSON>", 10
s_bad_len       equ $ - s_bad
s_nonjson_a:    db "  <non-JSON body, "
s_nonjson_a_len equ $ - s_nonjson_a
s_nonjson_b:    db " bytes>", 10
s_nonjson_b_len equ $ - s_nonjson_b

; -----------------------------------------------------------------------------
section .bss

; Per-connection request buffers, indexed by fd. Headers are parsed rather than
; discarded, and they arrive a fragment at a time interleaved with other
; connections, so each fd needs somewhere of its own to accumulate.
reqbufs:        resb MAX_FDS * CONN_BUF

rlen:   resd MAX_FDS                            ; bytes buffered, per fd
sent:   resd MAX_FDS                            ; response bytes sent, per fd

; Where the body starts, per fd -- the offset just past the blank line. Zero
; means the header block has not landed yet, which doubles as the sub-state
; flag inside the reading phase: no real request can have a body at offset 0.
hdrend: resd MAX_FDS
clen:   resd MAX_FDS                            ; Content-Length, per fd
hlog:   resd MAX_FDS                            ; header bytes after CR-stripping

; Peer address per fd, captured at accept: 4 bytes of IPv4 then 2 of port, both
; still in network byte order.
peers:  resb MAX_FDS * 8

acceptaddr:     resb 16                         ; sockaddr_in filled by accept4
acceptlen:      resd 1                          ; its length, in and out

events: resb MAX_EVENTS * EVENT_SIZE            ; epoll_pwait output

ev:                                             ; scratch epoll_event for _ctl
ev_events:      resd 1
ev_data:        resq 1

logpfx: resb 32                                 ; "255.255.255.255:65535 "
numtmp: resb 8                                  ; digit scratch for utoa
numbuf: resb 16                                 ; formatted number, for jappend

; The parsed body is assembled here as text and written in one go, rather than
; a syscall per key.
jsonlog:        resb JSONLOG_MAX
jlen:           resd 1                          ; bytes used in jsonlog
jlinestart:     resd 1                          ; jlen at the start of this pair

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
        ; conn_fd = accept4(listen_fd, &acceptaddr, &acceptlen, SOCK_NONBLOCK)
        ; Loop until EAGAIN: epoll is level-triggered, but taking every pending
        ; connection now saves a lap round the loop for each one.
        mov     dword [acceptlen], 16           ; kernel overwrites this
        mov     eax, SYS_accept4
        mov     edi, r12d
        lea     rsi, [acceptaddr]
        lea     rdx, [acceptlen]
        mov     r10d, SOCK_NONBLOCK
        syscall
        test    eax, eax
        js      .next                           ; EAGAIN: backlog is empty
        mov     ebx, eax

        cmp     ebx, MAX_FDS
        jae     .refuse                         ; no room in the state tables

        ; Stash the peer address now; by the time the request is logged the
        ; accept buffer will have been reused by later connections.
        mov     eax, [acceptaddr + 4]           ; sin_addr
        mov     [peers + rbx*8], eax
        mov     ax, [acceptaddr + 2]            ; sin_port
        mov     [peers + rbx*8 + 4], ax

        ; fd numbers get recycled, so clear this slot before reusing it.
        mov     dword [rlen + rbx*4], 0
        mov     dword [hdrend + rbx*4], 0

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
; Two phases, told apart by hdrend: accumulate until the blank line that ends
; the headers, then keep going until Content-Length bytes of body have landed.
; Only once the whole request is in does anything get logged, so a request's
; output stays in one piece even while other connections are mid-flight.
.do_read:
        mov     ecx, ebx
        shl     rcx, CONN_BUF_SHIFT
        lea     rsi, [reqbufs]
        add     rsi, rcx                        ; rsi = this connection's buffer
        mov     r9d, [rlen + rbx*4]             ; bytes already buffered
        mov     edx, CONN_BUF
        sub     edx, r9d                        ; space left
        jbe     .drop                           ; headers too big

        ; read(fd, buf + off, space)
        add     rsi, r9
        mov     eax, SYS_read
        mov     edi, ebx
        syscall
        test    rax, rax
        jle     .read_err

        add     eax, r9d                        ; newlen = off + n
        mov     [rlen + rbx*4], eax
        mov     edx, eax

        mov     ecx, ebx
        shl     rcx, CONN_BUF_SHIFT
        lea     rsi, [reqbufs]
        add     rsi, rcx                        ; rsi = buffer base again

        cmp     dword [hdrend + rbx*4], 0
        jne     .check_body                     ; headers already done

        ; Hunt for the blank line that ends the headers: "\n\n" or "\n\r\n".
        ; Rescanning from the start each time is O(n^2), but n is a few hundred
        ; bytes and it keeps the resumption logic to nothing.
        xor     ecx, ecx
.scan:
        lea     eax, [ecx + 1]
        cmp     eax, edx
        jae     .need_more                      ; need at least two bytes
        cmp     byte [rsi + rcx], 10
        jne     .scan_next
        cmp     byte [rsi + rcx + 1], 10
        je      .found_lf
        cmp     byte [rsi + rcx + 1], 13
        jne     .scan_next
        lea     eax, [ecx + 2]
        cmp     eax, edx
        jae     .need_more                      ; saw "\n\r", nothing after yet
        cmp     byte [rsi + rcx + 2], 10
        je      .found_crlf
.scan_next:
        inc     ecx
        jmp     .scan

.found_lf:
        lea     edx, [ecx + 2]                  ; bytes of header block
        jmp     .have_headers
.found_crlf:
        lea     edx, [ecx + 3]
        jmp     .have_headers

.need_more:
        cmp     edx, CONN_BUF
        jae     .drop                           ; buffer full, still no blank line
        jmp     .next                           ; stay in EPOLLIN for the rest

.read_err:
        cmp     rax, -EAGAIN
        je      .next                           ; nothing yet; keep waiting
        jmp     .drop                           ; 0 = peer hung up, <0 = error

; ---- headers are in ---------------------------------------------------------
; Note the body offset, tidy the headers up for logging, and find out how much
; body to expect. Runs exactly once per connection; the hdrend check above
; keeps later reads out of here.
;
; rsi = buffer base, rdx = raw length of the header block.
.have_headers:
        mov     [hdrend + rbx*4], edx           ; body starts here

        ; Strip CRs in place so the log holds clean lines. dst never overtakes
        ; src, so this is safe to do without a second buffer. Only the headers
        ; are touched -- body bytes already sitting past hdrend stay put.
        mov     rdi, rsi                        ; dst
        xor     ecx, ecx                        ; src index
.strip:
        cmp     ecx, edx
        jae     .stripped
        mov     al, [rsi + rcx]
        inc     ecx
        cmp     al, 13
        je      .strip
        mov     [rdi], al
        inc     rdi
        jmp     .strip
.stripped:
        sub     rdi, rsi
        mov     [hlog + rbx*4], edi             ; header bytes worth logging

        ; Content-Length off the tidied headers, where lines end in a bare \n.
        mov     rdx, rdi
        call    find_clen
        mov     [clen + rbx*4], eax

        ; Refuse anything whose body cannot fit alongside its headers.
        add     eax, [hdrend + rbx*4]
        cmp     eax, CONN_BUF
        ja      .drop

; ---- is the whole request in yet? -------------------------------------------
.check_body:
        mov     eax, [hdrend + rbx*4]
        add     eax, [clen + rbx*4]             ; bytes the full request needs
        cmp     [rlen + rbx*4], eax
        jb      .next                           ; still waiting on body

; ---- log the request --------------------------------------------------------
; Writes go out back to back and nothing else can log in between, so the pieces
; stay contiguous without being copied into one place first.
.complete:
        ; Build "ip:port " -- four octets and a port, all straight out of the
        ; network-order bytes stashed at accept time.
        lea     rdi, [logpfx]
        movzx   eax, byte [peers + rbx*8 + 0]
        call    utoa
        mov     byte [rdi], '.'
        inc     rdi
        movzx   eax, byte [peers + rbx*8 + 1]
        call    utoa
        mov     byte [rdi], '.'
        inc     rdi
        movzx   eax, byte [peers + rbx*8 + 2]
        call    utoa
        mov     byte [rdi], '.'
        inc     rdi
        movzx   eax, byte [peers + rbx*8 + 3]
        call    utoa
        mov     byte [rdi], ':'
        inc     rdi
        movzx   eax, word [peers + rbx*8 + 4]
        xchg    al, ah                          ; ntohs
        call    utoa
        mov     byte [rdi], ' '
        inc     rdi

        lea     rsi, [logpfx]
        mov     rdx, rdi
        sub     rdx, rsi                        ; prefix length
        call    write_all

        mov     ecx, ebx
        shl     rcx, CONN_BUF_SHIFT
        lea     rsi, [reqbufs]
        add     rsi, rcx
        mov     edx, [hlog + rbx*4]
        call    write_all

        ; Nothing more to say if the request had no body.
        mov     edx, [clen + rbx*4]
        test    edx, edx
        jz      .to_send

        ; Body: parse it as JSON if it looks like JSON, otherwise just say how
        ; big it was. Either way the result is assembled in jsonlog and written
        ; once, rather than a syscall per key.
        mov     dword [jlen], 0
        mov     ecx, ebx
        shl     rcx, CONN_BUF_SHIFT
        lea     rsi, [reqbufs]
        add     rsi, rcx
        add     esi, [hdrend + rbx*4]           ; rsi = body

        xor     ecx, ecx                        ; sniff past leading whitespace
.sniff:
        cmp     ecx, edx
        jae     .nonjson
        mov     al, [rsi + rcx]
        cmp     al, ' '
        ja      .sniffed
        inc     ecx
        jmp     .sniff
.sniffed:
        cmp     al, '{'
        jne     .nonjson
        call    json_log
        jmp     .logged

.nonjson:
        lea     rsi, [s_nonjson_a]
        mov     edx, s_nonjson_a_len
        call    jappend
        lea     rdi, [numbuf]
        mov     eax, [clen + rbx*4]
        call    utoa
        lea     rsi, [numbuf]
        mov     rdx, rdi
        sub     rdx, rsi
        call    jappend
        lea     rsi, [s_nonjson_b]
        mov     edx, s_nonjson_b_len
        call    jappend

.logged:
        ; Blank line so consecutive requests stay readable.
        lea     rsi, [s_nl]
        mov     edx, 1
        call    jappend
        lea     rsi, [jsonlog]
        mov     edx, [jlen]
        call    write_all

.to_send:
        ; Flip the connection over to writing; the reply goes out next lap.
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

; -----------------------------------------------------------------------------
; write_all(rsi = buf, rdx = len) -- push it all to stdout, short writes and
; all. Gives up silently if stdout has gone away. Clobbers rax, rcx, rsi, rdx,
; rdi, r11.
;
; This is the one blocking call in the whole loop: if the container's log pipe
; backs up, every connection waits behind it.
write_all:
        test    rdx, rdx
        jz      .wa_done
.wa_loop:
        mov     eax, SYS_write
        mov     edi, STDOUT
        syscall
        test    rax, rax
        jle     .wa_done
        add     rsi, rax
        sub     rdx, rax
        jnz     .wa_loop
.wa_done:
        ret

; find_clen(rsi = headers, rdx = len) -> eax -- the Content-Length value, or 0
; if the header is absent. Expects CR-stripped headers, so lines end in \n.
; Matching is case-folded with OR 0x20, which leaves ':' and '-' alone.
; Clobbers rax, rcx, r8, r9, r10.
find_clen:
        xor     r8d, r8d                        ; index of the current line
.fc_line:
        xor     ecx, ecx                        ; how much of the name matched
.fc_cmp:
        cmp     ecx, cl_name_len
        jae     .fc_hit
        lea     r9, [r8 + rcx]
        cmp     r9, rdx
        jae     .fc_none                        ; ran off the end mid-name
        movzx   r10d, byte [rsi + r9]
        or      r10d, 0x20                      ; fold to lower case
        lea     rax, [cl_name]
        cmp     r10b, [rax + rcx]
        jne     .fc_next
        inc     ecx
        jmp     .fc_cmp

.fc_hit:
        lea     r9, [r8 + cl_name_len]
.fc_space:
        cmp     r9, rdx
        jae     .fc_none
        cmp     byte [rsi + r9], ' '
        jne     .fc_digits
        inc     r9
        jmp     .fc_space
.fc_digits:
        xor     eax, eax
.fc_digit:
        cmp     r9, rdx
        jae     .fc_ret
        movzx   ecx, byte [rsi + r9]
        sub     ecx, '0'
        cmp     ecx, 9
        ja      .fc_ret
        imul    eax, eax, 10
        add     eax, ecx
        inc     r9
        jmp     .fc_digit
.fc_ret:
        ret

.fc_next:
        ; Skip to the start of the next line and try again.
        cmp     r8, rdx
        jae     .fc_none
        cmp     byte [rsi + r8], 10
        je      .fc_advance
        inc     r8
        jmp     .fc_next
.fc_advance:
        inc     r8
        cmp     r8, rdx
        jae     .fc_none
        jmp     .fc_line

.fc_none:
        xor     eax, eax
        ret

; jappend(rsi = src, rdx = len) -- tack bytes onto jsonlog, silently truncating
; if it would overflow. Deliberately leaves rbp and r8-r11 alone so the parser
; can keep its cursor and token registers across a call.
; Clobbers rax, rcx, rdx, rsi, rdi.
jappend:
        mov     ecx, [jlen]
        mov     eax, JSONLOG_MAX
        sub     eax, ecx                        ; space remaining
        cmp     rdx, rax
        jbe     .ja_fits
        mov     edx, eax                        ; truncate
.ja_fits:
        test    edx, edx
        jz      .ja_done
        lea     rdi, [jsonlog]
        add     rdi, rcx
        add     [jlen], edx
.ja_copy:
        mov     al, [rsi]
        mov     [rdi], al
        inc     rsi
        inc     rdi
        dec     edx
        jnz     .ja_copy
.ja_done:
        ret

; json_log(rsi = body, rdx = len) -- parse a flat JSON object and append one
; "  key = value" line per pair to jsonlog.
;
; Deliberately shallow: top-level scalars only, and string contents are logged
; raw rather than unescaped, so "a\nb" appears with its backslash intact. What
; it does handle is \" inside strings, so an escaped quote does not end a token
; early. Anything it cannot make sense of collapses to <malformed JSON>, with
; the half-built line rolled back so the output stays tidy.
;
; rbp = cursor, r8 = end, r9/r10 = current token. Clobbers rax, rcx, rdx, rsi,
; rdi, rbp, r8, r9, r10.
json_log:
        mov     rbp, rsi                        ; cursor
        mov     r8, rsi
        add     r8, rdx                         ; end
        mov     eax, [jlen]
        mov     [jlinestart], eax

        call    .skip_ws
        cmp     rbp, r8
        jae     .bad
        cmp     byte [rbp], '{'
        jne     .bad
        inc     rbp
        call    .skip_ws
        cmp     rbp, r8
        jae     .bad
        cmp     byte [rbp], '}'
        je      .done                           ; {} is legal and boring

.pair:
        mov     eax, [jlen]
        mov     [jlinestart], eax               ; rollback point for this line

        call    .skip_ws
        cmp     rbp, r8
        jae     .bad
        cmp     byte [rbp], '"'
        jne     .bad
        call    .scan_string
        jc      .bad

        lea     rsi, [s_indent]
        mov     edx, s_indent_len
        call    jappend
        mov     rsi, r9
        mov     rdx, r10
        call    jappend
        lea     rsi, [s_eq]
        mov     edx, s_eq_len
        call    jappend

        call    .skip_ws
        cmp     rbp, r8
        jae     .bad
        cmp     byte [rbp], ':'
        jne     .bad
        inc     rbp
        call    .skip_ws
        cmp     rbp, r8
        jae     .bad

        cmp     byte [rbp], '"'
        je      .value_string
        ; Bare scalar -- number, true, false, null. Runs to whitespace or to
        ; whatever punctuation ends the pair.
        mov     r9, rbp
.value_scan:
        cmp     rbp, r8
        jae     .value_end
        mov     al, [rbp]
        cmp     al, ','
        je      .value_end
        cmp     al, '}'
        je      .value_end
        cmp     al, ' '
        jbe     .value_end
        inc     rbp
        jmp     .value_scan
.value_end:
        mov     r10, rbp
        sub     r10, r9
        jz      .bad                            ; ':' with nothing after it
        jmp     .value_emit

.value_string:
        call    .scan_string
        jc      .bad

.value_emit:
        mov     rsi, r9
        mov     rdx, r10
        call    jappend
        lea     rsi, [s_nl]
        mov     edx, 1
        call    jappend

        call    .skip_ws
        cmp     rbp, r8
        jae     .bad
        mov     al, [rbp]
        cmp     al, ','
        jne     .maybe_close
        inc     rbp
        jmp     .pair
.maybe_close:
        cmp     al, '}'
        jne     .bad
.done:
        ret

.bad:
        ; Throw away the partial line, then say so.
        mov     eax, [jlinestart]
        mov     [jlen], eax
        lea     rsi, [s_bad]
        mov     edx, s_bad_len
        call    jappend
        ret

; Advance the cursor past spaces, tabs, CRs and newlines.
.skip_ws:
        cmp     rbp, r8
        jae     .sw_ret
        cmp     byte [rbp], ' '
        ja      .sw_ret
        inc     rbp
        jmp     .skip_ws
.sw_ret:
        ret

; Cursor sits on the opening quote. Sets r9/r10 to the contents and leaves the
; cursor past the closing quote. CF set if the string never closes.
.scan_string:
        inc     rbp
        mov     r9, rbp
.ss_scan:
        cmp     rbp, r8
        jae     .ss_err
        mov     al, [rbp]
        cmp     al, 92                          ; backslash: skip the pair
        je      .ss_escape
        cmp     al, '"'
        je      .ss_close
        inc     rbp
        jmp     .ss_scan
.ss_escape:
        add     rbp, 2
        jmp     .ss_scan
.ss_close:
        mov     r10, rbp
        sub     r10, r9
        inc     rbp
        clc
        ret
.ss_err:
        stc
        ret

; utoa(eax = value, rdi = dest) -- write the value in decimal, return rdi just
; past the last digit. Digits fall out backwards, so they land in a scratch
; buffer first and get copied over. Clobbers rax, rcx, rdx, rsi.
utoa:
        mov     ecx, 10
        lea     rsi, [numtmp + 8]
.u_digit:
        xor     edx, edx
        div     ecx                             ; edx = value % 10
        add     dl, '0'
        dec     rsi
        mov     [rsi], dl
        test    eax, eax
        jnz     .u_digit
.u_copy:
        mov     al, [rsi]
        mov     [rdi], al
        inc     rsi
        inc     rdi
        lea     rdx, [numtmp + 8]
        cmp     rsi, rdx
        jb      .u_copy
        ret
