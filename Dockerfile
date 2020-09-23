FROM node:alpine

# Add nomad and levant
# https://github.com/jrasell/levant
# https://pkgs.alpinelinux.org/package/edge/testing/x86/nomad
# NOTE: adds ~115MB binary to /usr/sbin/nomad
RUN apk add --no-cache -X http://dl-cdn.alpinelinux.org/alpine/edge/community cni-plugins  nomad  &&  \
    wget -qO /usr/sbin/levant https://github.com/jrasell/levant/releases/download/0.2.9/linux-amd64-levant  &&  \
    chmod +x /usr/sbin/levant

# NOTE: `nomad` binary needed for other repositories using us for CI/CD - but drop from _our_ webapp.
# NOTE: switching to `USER node` makes `nomad` binary not work right now - so immediately drop privs.
CMD apk del nomad  &&  rm /usr/sbin/levant  &&  su node -c 'node --input-type=module -e "import http from \"http\"; http.createServer((req, res) => res.end(\"hai \"+new Date())).listen(5000)"'
