# syntax=docker/dockerfile:1

# Keep this in sync with .github/workflows/build.yml. Unlike setup-roc's nightly
# path, this build verifies the immutable release asset before executing it.
FROM ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea AS builder

ARG ROC_NIGHTLY_TAG=nightly-2026-August-04-1cb06bc
ARG ROC_ARCHIVE=roc_nightly-linux_x86_64-2026-08-04-1cb06bc.tar.gz
ARG ROC_SHA256=356d38882c77923ac78e21d8da9efa3ce8f2ef20d143f42a2558958eb82a9339

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        libsqlite3-dev \
        pkg-config \
        zstd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/roc
RUN curl --fail --show-error --location \
        --output roc.tar.gz \
        "https://github.com/roc-lang/nightlies/releases/download/${ROC_NIGHTLY_TAG}/${ROC_ARCHIVE}" \
    && echo "${ROC_SHA256}  roc.tar.gz" | sha256sum --check --strict \
    && tar --extract --gzip --file roc.tar.gz --strip-components=1 \
    && rm roc.tar.gz

WORKDIR /src
COPY src ./src

RUN /opt/roc/roc test src/Csv.roc \
    && mkdir /out \
    && /opt/roc/roc build src/app.roc --output=/out/stride --opt=dev \
    && /out/stride --version


FROM ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea AS runtime

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        ca-certificates \
        libsqlite3-0 \
        python3 \
        tzdata \
        unzip \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 65532 stride \
    && useradd --uid 65532 --gid stride --home-dir /data --no-create-home --shell /usr/sbin/nologin stride \
    && install --directory --owner=stride --group=stride --mode=0700 /data

COPY --from=builder --chown=root:root /out/stride /usr/local/bin/stride
COPY --chown=root:root tools/stride_activity_file.py /usr/local/libexec/stride_activity_file.py

ENV HOME=/data
VOLUME ["/data"]
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/stride"]
CMD ["--help"]
