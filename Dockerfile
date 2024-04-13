FROM denoland/deno:alpine

# add `nomad`
RUN mkdir -m777 /usr/local/sbin  && \
    cd          /usr/local/sbin  && \
    wget -qO  nomad.zip  https://releases.hashicorp.com/nomad/1.7.6/nomad_1.7.6_linux_amd64.zip && \
    unzip     nomad.zip  && \
    rm        nomad.zip  && \
    chmod 777 nomad && \
    apk add bash zsh

COPY deploy.sh test/test.sh /
USER deno

# run our logical tests during the build (since our .gitlab-ci.yml applies to other repos using us)
RUN env -i zsh -euax /test.sh

# NOTE: `nomad` binary needed for other repositories using us for CI/CD - but drop from _our_ webapp.
CMD rm /usr/local/sbin/nomad  &&  deno eval "import { serve } from 'https://deno.land/std/http/server.ts'; serve(() => new Response('hai'), { port: 5000 })"
