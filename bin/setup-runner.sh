#!/bin/zsh -ex

# Sets up a GitLab runner on machine/VM w/ docker already on it
#
# Uses `docker.sock` as a _much_ faster alternative to docker-in-docker (esp. for monorepos).


# https://docs.gitlab.com/runner/install/docker.html
sudo docker run -d --name gitlab-runner --restart=unless-stopped \
-v /srv/gitlab-runner/config:/etc/gitlab-runner \
-v /var/run/docker.sock:/var/run/docker.sock \
gitlab/gitlab-runner:latest

# https://docs.gitlab.com/runner/register/index.html#docker
# NOTE: you can rerun this command multiple times to add the same runner as a group runner to
# addtional groups!
sudo docker run --rm -it \
  -v /srv/gitlab-runner/config:/etc/gitlab-runner \
  gitlab/gitlab-runner -- register \
  --executor docker \
  --docker-image docker \
  --docker-volumes /var/run/docker.sock:/var/run/docker.sock
# fill in your remaining answers...


# update num. simultaneous jobs; ensure docker gets IP addy inside network walls to talk to nomad
CONF=/srv/gitlab-runner/config/config.toml
sudo perl -i -pe 's/^concurrent = 1/concurrent = 3/' ${CONF?}
echo '    network_mode = "host"' | sudo tee -a       ${CONF?}


sudo docker restart gitlab-runner
