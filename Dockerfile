FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN printf '%s\n' \
        'Acquire::http::Proxy "socks5h://192.168.1.1:1091";' \
        'Acquire::https::Proxy "socks5h://192.168.1.1:1091";' \
        > /etc/apt/apt.conf.d/99yaof-socks \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        asciidoc \
        bash \
        bcc \
        bin86 \
        binutils \
        bison \
        bzip2 \
        ca-certificates \
        ccache \
        clang \
        curl \
        dos2unix \
        dwarves \
        file \
        flex \
        g++ \
        g++-multilib \
        gawk \
        gcc-multilib \
        gettext \
        git \
        gosu \
        gzip \
        help2man \
        intltool \
        iproute2 \
        iptables \
        jq \
        libbpf-dev \
        libboost-dev \
        libelf-dev \
        liblz4-dev \
        libncurses-dev \
        libssl-dev \
        libthread-queue-any-perl \
        libusb-dev \
        libxml-parser-perl \
        linux-tools-generic \
        llvm \
        lz4 \
        make \
        nodejs \
        npm \
        patch \
        perl-modules \
        pkg-config \
        python3-dev \
        python3-libfdt \
        python3-pip \
        python3-pyelftools \
        python3-setuptools \
        proxychains4 \
        quilt \
        redsocks \
        rsync \
        sharutils \
        stubby \
        swig \
        time \
        unzip \
        util-linux \
        wget \
        xsltproc \
        xz-utils \
        zip \
        zlib1g-dev \
        zstd \
    && printf '%s\n' \
        'strict_chain' \
        'proxy_dns' \
        'tcp_read_time_out 15000' \
        'tcp_connect_time_out 8000' \
        '[ProxyList]' \
        'socks5 192.168.1.1 1091' \
        > /etc/proxychains4.conf \
    && proxychains4 -q npm install --global n@10.2.0 \
    && proxychains4 -q n 22.17.0 \
    && proxychains4 -q npm install --global pnpm@11.16.0 \
    && rm -rf /var/lib/apt/lists/* /root/.npm /etc/apt/apt.conf.d/99yaof-socks

RUN groupmod --new-name builder ubuntu \
    && usermod --login builder --home /home/builder --move-home --shell /bin/bash ubuntu \
    && useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin stubby \
    && install -d --owner=builder --group=builder /opt/source/YAOF

COPY docker/entrypoint.sh /usr/local/sbin/yaof-entrypoint
RUN chmod 0755 /usr/local/sbin/yaof-entrypoint

WORKDIR /opt/source/YAOF

HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=12 \
    CMD test -f /run/yaof-ready \
        && kill -0 "$(cat /run/redsocks.pid)" \
        && kill -0 "$(cat /run/stubby.pid)" \
        && ss -ltnH | grep -q '127.0.0.1:53' \
        && getent ahostsv4 downloads.openwrt.org >/dev/null \
        && iptables -t nat -C OUTPUT -p tcp -d 192.168.1.1 --dport 1091 -m owner --uid-owner "$(id -u redsocks)" -j RETURN \
        && iptables -t nat -C OUTPUT -p tcp -j REDIRECT --to-ports 12345 \
        && iptables -t mangle -C OUTPUT -p tcp --dport 53 -j MARK --set-mark 53 \
        && iptables -t mangle -C OUTPUT -p tcp -d 192.168.1.1 --dport 1091 -j MARK --set-mark 1091 \
        && iptables -C OUTPUT -m mark --mark 53 -j REJECT \
        && iptables -C OUTPUT -m mark --mark 1091 -j REJECT \
        && iptables -C OUTPUT -p udp -j REJECT >/dev/null

ENTRYPOINT ["/usr/local/sbin/yaof-entrypoint"]
CMD ["sleep", "infinity"]
