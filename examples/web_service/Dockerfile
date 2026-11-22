# Build Linux archives with the matching OTP distro/CPU before building this image.
FROM ubuntu:26.04 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libncurses6 libtinfo6 libssl3 libstdc++6 zlib1g \
    && rm -rf /var/lib/apt/lists/*

FROM runtime AS application
WORKDIR /app
COPY web_service.tar.gz /tmp/application.tar.gz
RUN tar -xzf /tmp/application.tar.gz -C /app && rm /tmp/application.tar.gz
USER 65532:65532
STOPSIGNAL SIGTERM
ENTRYPOINT ["/app/web_service_bin"]
