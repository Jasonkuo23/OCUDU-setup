FROM ubuntu:24.04 AS builder

ARG OCUDU_REF=release_26_04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    cmake \
    dpdk \
    dpdk-dev \
    g++ \
    gcc \
    git \
    libboost-program-options-dev \
    libconfig++-dev \
    libdpdk-dev \
    libfftw3-dev \
    libgtest-dev \
    libmbedtls-dev \
    libnuma-dev \
    libpcap-dev \
    libsctp-dev \
    libyaml-cpp-dev \
    make \
    pciutils \
    pkg-config \
  && rm -rf /var/lib/apt/lists/*

RUN git init /src/ocudu \
  && git -C /src/ocudu remote add origin https://gitlab.com/ocudu/ocudu.git \
  && git -C /src/ocudu fetch --depth 1 origin "${OCUDU_REF}" \
  && git -C /src/ocudu checkout --detach FETCH_HEAD

RUN cmake -S /src/ocudu -B /src/ocudu/build \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=OFF \
      -DENABLE_DPDK=ON \
      -DENABLE_EXPORT=ON \
      -DENABLE_UHD=OFF \
      -DENABLE_ZEROMQ=OFF \
  && cmake --build /src/ocudu/build -j"$(nproc)"

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    dpdk \
    iproute2 \
    iputils-ping \
    libboost-program-options1.83.0 \
    libconfig++9v5 \
    libdpdk-dev \
    libfftw3-bin \
    libfftw3-double3 \
    libfftw3-single3 \
    libmbedtls14 \
    libnuma1 \
    libpcap0.8 \
    libsctp1 \
    libyaml-cpp0.8 \
    pciutils \
    tini \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/ocudu/build/apps/cu_cp/ocucp /usr/local/bin/ocucp
COPY --from=builder /src/ocudu/build/apps/cu_up/ocuup /usr/local/bin/ocuup
COPY --from=builder /src/ocudu/build/apps/du/odu /usr/local/bin/odu

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["odu", "--help"]
