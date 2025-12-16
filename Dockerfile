FROM denoland/deno:alpine

# add `nomad`
RUN mkdir -m777 /usr/local/sbin  && \
    cd          /usr/local/sbin  && \
    wget -qO  nomad.zip  https://releases.hashicorp.com/nomad/1.7.6/nomad_1.7.6_linux_amd64.zip && \
    unzip     nomad.zip  && \
    rm        nomad.zip  && \
    chmod 777 nomad && \
    # podman for build.sh
    apk add bash zsh jq podman caddy && \
    # using podman not docker
    ln -s /usr/bin/podman /usr/bin/docker

WORKDIR /app
COPY ci.yml .

WORKDIR /
COPY build.sh test.sh deploy.sh project.nomad /

CMD ["/usr/sbin/caddy", "file-server", "-r=/app"]
