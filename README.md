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

About 60 instructions:

```
socket -> bind(:8080) -> listen -> accept -> read -> send -> close -> repeat
```

One connection at a time, and every request gets the same response no matter
the method or path.

Two things worth knowing if you poke at it:

- Sends use `MSG_NOSIGNAL`. Otherwise a client that hangs up mid-response
  raises `SIGPIPE` and kills the process.
- `Content-Length` is a plain string in the source, so both files check it
  against the real body length at assembly time. Get it wrong and the build
  fails instead of clients hanging.

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
