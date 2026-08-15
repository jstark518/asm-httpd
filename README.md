# asm-container

A tiny HTTP server written in assembly, in a ~1 KB Docker image.

No libc, no shell, nothing in the final image but one static binary talking
straight to the kernel.

## Run it

```bash
docker compose up --build -d
```

```bash
curl http://localhost:8080/
```

## How it works

One thread, no processes, but it handles plenty of connections at once — an
epoll loop over non-blocking sockets:

```
socket -> bind(:8080) -> listen -> epoll_create1
   |
   +-> epoll_pwait -> for each ready fd: accept / read / send / close
```

Every request gets the same response no matter the method or path, but the
requester and its headers are logged to stdout:

```
192.168.65.1:60076 GET /search?q=asm HTTP/1.1
Host: localhost:8080
User-Agent: curl/8.7.1
Accept: */*

```

Each connection is really a two-state machine, and the state is just which
event it's registered for: `EPOLLIN` while reading the request, `EPOLLOUT`
while sending the reply. What does need storing, per fd, is how much has been
buffered and how much has been sent — plus the request bytes themselves, since
they can arrive a fragment at a time interleaved with other connections.

The headers get logged without being reassembled anywhere. The buffer already
holds them as text, so logging is: strip the CRs in place (dst never overtakes
src, so no second buffer), then two back-to-back writes — `ip:port ` from a
scratch buffer, then the block itself. Nothing else can log in between, since
there's only the one thread.

`accept4` captures the peer address, which is stashed per fd and formatted at
log time — by the time a request completes, the accept buffer has long since
been reused by later connections. Formatting it needs a decimal conversion,
which is the one genuine subroutine in the file.

Reading now waits for the blank line ending the headers, so `GET / HTTP/1.1`
with no blank line after it will sit there unanswered. That's correct HTTP,
but worth knowing if you're poking at it with `nc`. Bare-LF line endings work
as well as CRLF.

Two things worth knowing if you poke at it:

- Sends use `MSG_NOSIGNAL`. Otherwise a client that hangs up mid-response
  raises `SIGPIPE` and kills the process.
- The log write is the one blocking call in the loop. If the container's log
  pipe backs up, everything stalls behind it.
- Headers over 4 KB get the connection closed with no response.
- The logged address is whoever actually connected. Behind Docker's port
  forwarding that's the gateway (`192.168.65.1`), not the original client.
- `Content-Length` is a plain string in the source, so both files check it
  against the real body length at assembly time. Get it wrong and the build
  fails instead of clients hanging.

`struct epoll_event` is packed on x86-64 (12 bytes) but not on arm64 (16), which
is the one place the two sources genuinely differ rather than just spelling the
same thing in different syntax.

## Two architectures?

The Dockerfile picks the source based on `TARGETARCH` so the binary is always
built natively.

That's not just neatness — Docker Desktop on Apple Silicon runs amd64 images
through Rosetta, and Rosetta segfaults this binary on startup. The same binary
works fine under `qemu-x86_64`, so it's an emulation bug, not our bug. Building
natively avoids the whole problem.

## Changing the response

Edit the `body:` string, fix the `Content-Length:` number to match, rebuild.
If you get it wrong:

```
error: Content-Length header is out of sync with the response body
```
