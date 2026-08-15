FROM alpine:3.20 AS build

# Set by BuildKit to the architecture being built for ("amd64" / "arm64").
ARG TARGETARCH

RUN apk add --no-cache binutils \
 && if [ "$TARGETARCH" = "amd64" ]; then apk add --no-cache nasm; fi

WORKDIR /src
COPY src/ ./

# Each architecture has its own source.
RUN case "$TARGETARCH" in \
      amd64) nasm -f elf64 -o httpd.o http_x86_64.asm ;; \
      arm64) as -o httpd.o http_aarch64.s ;; \
      *) echo "no assembly source for TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac \
 && ld -s --build-id=none -o httpd httpd.o


# The binary is static and makes only raw syscalls, so it needs nothing else
# no shell, no libc, no package manager, nothing to CVE-scan.
FROM scratch AS runtime

COPY --from=build /src/httpd /httpd

EXPOSE 8080
ENTRYPOINT ["/httpd"]
