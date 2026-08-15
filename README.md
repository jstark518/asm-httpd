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

Every request gets the same response no matter the method or path.

Each connection is really a two-state machine, and the state is just which
event it's registered for: `EPOLLIN` while waiting for the request, `EPOLLOUT`
while sending the reply. So there's no state variable to keep — the only thing
worth remembering is how many bytes have gone out, in an array indexed by fd.

Two things worth knowing if you poke at it:

- Sends use `MSG_NOSIGNAL`. Otherwise a client that hangs up mid-response
  raises `SIGPIPE` and kills the process.
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
