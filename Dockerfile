# syntax = docker/dockerfile:1.0-experimental
# https://docs.docker.com/develop/develop-images/build_enhancements/#overriding-default-frontends


FROM node:slim

# Add nomad
RUN cd /usr/sbin  &&  \
    node --input-type=module -e " \
        import https from 'https'; \
        import fs from 'fs'; \
        const URL = 'https://releases.hashicorp.com/nomad/1.0.3/nomad_1.0.3_linux_amd64.zip'; \
        const DST = 'nomad.zip'; \
        const request = https.get(URL, (resp) => resp.pipe(fs.createWriteStream(DST)))"  &&  \
    apt-get -yqq update  &&  \
    apt-get -yqq --no-install-recommends install unzip ca-certificates wget  &&  \
    unzip    nomad.zip  &&  \
    rm       nomad.zip


# NOTE: `nomad` binary needed for other repositories using us for CI/CD - but drop from _our_ webapp.
# NOTE: switching to `USER node` makes `nomad` binary not work right now - so immediately drop privs.
CMD rm /usr/sbin/nomad  &&  su node -c 'node --input-type=module -e "import http from \"http\"; http.createServer((req, res) => res.end(\"hai \"+new Date())).listen(5000)"'
