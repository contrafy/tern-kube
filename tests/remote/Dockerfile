# Disposable Linux host for tern-kube's remote tests (scripts/remote-host.sh):
# Debian 13 with sshd, fish/zsh/bash/dash, kubectl, helm and luau (built
# from source: luau publishes no linux-arm64 binary, and the x86_64 one
# fails every require under Docker Desktop's emulation). Login shell of
# user tk: --build-arg SHELL_NAME=fish|bash|zsh. Nothing is copied in: the
# ssh key, kubeconfig and Tern arrive at run time.
ARG DEBIAN=debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4

FROM ${DEBIAN} AS luau
ARG LUAU_VERSION=0.741
ARG LUAU_SRC_SHA256=deee653d0f5971b809ef67f50dbe8109ad369d7575e344cfe2013774fed2f4c6
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends cmake make g++ curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSLo /tmp/luau.tar.gz "https://github.com/luau-lang/luau/archive/refs/tags/${LUAU_VERSION}.tar.gz" \
 && echo "${LUAU_SRC_SHA256}  /tmp/luau.tar.gz" | sha256sum -c - \
 && mkdir /src && tar -xzf /tmp/luau.tar.gz -C /src --strip-components=1 \
 && cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DLUAU_BUILD_TESTS=OFF \
 && cmake --build /build --target Luau.Repl.CLI -j"$(nproc)" \
 && install -m 0755 /build/luau /usr/local/bin/luau

FROM ${DEBIAN}
ARG TARGETARCH
ARG SHELL_NAME=fish
ARG KUBECTL_VERSION=1.34.1
ARG KUBECTL_SHA256_arm64=420e6110e3ba7ee5a3927b5af868d18df17aae36b720529ffa4e9e945aa95450
ARG KUBECTL_SHA256_amd64=7721f265e18709862655affba5343e85e1980639395d5754473dafaadcaa69e3
ARG HELM_VERSION=3.22.0
ARG HELM_SHA256_arm64=f14e804dfee240f55525b667488fe9adca349e63e00c9af634c0beb1421ac310
ARG HELM_SHA256_amd64=1e4ab49e429626cf6c6958d914248b78c9730803c2751b87627e171dc800e7bb
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
    openssh-server fish zsh bash dash perl git curl ca-certificates procps less file jq make \
 && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in \
      arm64) kubectl_sha=$KUBECTL_SHA256_arm64 helm_sha=$HELM_SHA256_arm64 ;; \
      amd64) kubectl_sha=$KUBECTL_SHA256_amd64 helm_sha=$HELM_SHA256_amd64 ;; \
      *) echo "unsupported TARGETARCH '$TARGETARCH'" >&2; exit 1 ;; \
    esac \
 && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && echo "${kubectl_sha}  /usr/local/bin/kubectl" | sha256sum -c - && chmod 0755 /usr/local/bin/kubectl \
 && curl -fsSLo /tmp/helm.tgz "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
 && echo "${helm_sha}  /tmp/helm.tgz" | sha256sum -c - \
 && tar -xzf /tmp/helm.tgz -C /tmp "linux-${TARGETARCH}/helm" \
 && install -m 0755 "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm && rm -rf /tmp/helm.tgz "/tmp/linux-${TARGETARCH}"
COPY --from=luau /usr/local/bin/luau /usr/local/bin/luau
# An empty .zshrc keeps zsh's new-user wizard out of login panes. The Tern
# build directory exists in the image so a named volume mounted there
# starts owned by tk (it caches the Tern download across containers).
RUN case "$SHELL_NAME" in \
      fish) login=/usr/bin/fish ;; bash) login=/bin/bash ;; zsh) login=/usr/bin/zsh ;; \
      *) echo "SHELL_NAME must be fish, bash or zsh, not '$SHELL_NAME'" >&2; exit 1 ;; \
    esac \
 && useradd -m -s "$login" tk \
 && mkdir -p /run/sshd /home/tk/.ssh /home/tk/.kube /home/tk/.local/share/tern /home/tk/.local/bin \
 && touch /home/tk/.zshrc \
 && chmod 700 /home/tk/.ssh && chown -R tk:tk /home/tk \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' >/etc/ssh/sshd_config.d/tk.conf
EXPOSE 22
# Host keys are made per container, never baked into the image.
CMD ["sh", "-c", "ssh-keygen -A && exec /usr/sbin/sshd -D -e"]
