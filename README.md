Code, setup, and information to:
- setup automatic deployment to Nomad clusters from GitHub & GitLab CI/CD pipelines
- interact with, monitor, and customize deployments


# GitHub Overview
We have a https://github.com/internetarchive/cicd repo that uses GitHub Actions reusable workflows for full CI/CD pipelines.

More documentation coming soon.


# GitLab Overview
Deployment leverages a simple `.gitlab-ci.yml` using GitLab runners & CI/CD ([build] and [test]);
then switches to custom [deploy] phase to deploy docker containers into `nomad`.

This also contains demo "hi world" webapp.


Uses:
- [nomad](https://www.nomadproject.io) **deployment** (management, scheduling)
- [consul](https://www.consul.io) **networking** (service discovery, healthchecking, secrets storage)
- [caddy](https://caddyserver.com/) **routing** (load balancing, automatic https)

![Architecture](img/overview2.drawio.svg)


## Want to deploy to nomad? 🚀
- verify project's [Settings] [CI/CD] [Variables] has either Group or Project level settings for:
  - `NOMAD_TOKEN` `MY-TOKEN`
  - `NOMAD_ADDR` `https://MY-HOSTNAME` or `BASE_DOMAIN` `example.com`
  - (archive.org admins will often have set this already for you at the group-level)
- simply make your project have this simple `.gitlab-ci.yml` in top-level dir:
```yaml
include:
  - remote: 'https://nomad.archive.org/ci.yml'
```
*OR*
```yaml
include:
  - remote: 'https://raw.githubusercontent.com/internetarchive/nomad/refs/heads/main/gitlab.yml'
```

- if you want a [test] phase, you can add this to the `.gitlab-ci.yml` file above:
```yaml
test:
  stage: test
  image: ${CI_REGISTRY_IMAGE}/${CI_COMMIT_REF_SLUG}:${CI_COMMIT_SHA}
  script:
    - cd /app   # or wherever in your image
    - npm test  # or whatever your test scripts/steps are
```
- [optional] you can _instead_ copy [the included file](gitlab.yml) and customize/extend it.
- [optional] you can copy this [project.nomad](project.nomad) file into your repo top level and customize/extend it if desired
- _... but there's a good chance you won't need to_ 😎

_**Note:** For urls like https://archive.org/services/project -- watch out for routes defined in your app with trailing slashes – they may redirect to project.dev.archive.org. More information [here](https://git.archive.org/services/pyhi/-/blob/main/README.md#notes)._

### Customizing
There are various options that can be used in conjunction with the `project.nomad` and `.gitlab-ci.yml` files, keys:
```text
NOMAD_VAR_CHECK_PATH
NOMAD_VAR_CHECK_PROTOCOL
NOMAD_VAR_CHECK_TIMEOUT
NOMAD_VAR_CONSUL_PATH
NOMAD_VAR_COUNT
NOMAD_VAR_COUNT_CANARIES
NOMAD_VAR_CPU
NOMAD_VAR_FORCE_PULL
NOMAD_VAR_HEALTH_TIMEOUT
NOMAD_VAR_HOSTNAMES
NOMAD_VAR_IS_BATCH
NOMAD_VAR_MEMORY
NOMAD_VAR_MULTI_CONTAINER
NOMAD_VAR_NAMESPACE
NOMAD_VAR_NETWORK_MODE
NOMAD_VAR_NO_DEPLOY
NOMAD_VAR_PERSISTENT_VOLUME
NOMAD_VAR_PORTS
NOMAD_VAR_SERVERLESS
NOMAD_VAR_VOLUMES
```
- See the top of [project.nomad](project.nomad)
- Our customizations always prefix with `NOMAD_VAR_`.
- You can simply insert them, with values, in your project's `.gitlab-ci.yml` file before including _our_ [gitlab.yml](gitlab.yml) like above.
- Examples 👇
#### Don't actually deploy containers to nomad
Perhaps your project just wants to leverage the CI (Continuous Integration) for [buil] and/or [test] steps - but not CD (Continuous Deployment).  An example might be a back-end container that runs elsewhere and doesn't have web listener.
```yaml
variables:
  NOMAD_VAR_NO_DEPLOY: 'true'
```

#### Custom default RAM expectations from (default) 300 MB to 1 GB
This value is the _expected_ value for your container's average running needs/usage, helpful for `nomad` scheduling purposes.  It is a "soft limit" and we use *ten times* this amount to be the amount used for a "hard limit".  If your allocated container exceeds the hard limit, the container may be restarted by `nomad` if there is memory pressure on the Virtual Machine the container is running on.
```yaml
variables:
  NOMAD_VAR_MEMORY: 1000
```
#### Custom default CPU expectations from (default) 100 MHz to 1 GHz
This value is the _expected_ value for your container's average running needs/usage, helpful for `nomad` scheduling purposes.  It is a "soft limit".  If your allocated container exceeds your specified limit, the container _may_ be restarted by `nomad` if there is CPU pressure on the Virtual Machine the container is running on.  (So far, CPU-based restarts seem very rare in practice, since most VMs tend to "fill" up from aggregate container RAM requirements first 😊)
```yaml
variables:
  NOMAD_VAR_CPU: 1000
```
#### Custom healthcheck, change from (default) HTTP to TCP:
This can be useful if your webapp serves using websockets, doesnt respond to http, or typically takes too long (or can't) respond with a `200 OK` status.  (Think of it like switching to just a `ping` on your main port your webapp listens on).
```yaml
variables:
  NOMAD_VAR_CHECK_PROTOCOL: 'tcp'
```
#### Custom healthcheck, change path from (default) `/` to `/healthcheck`:
```yaml
variables:
  NOMAD_VAR_CHECK_PATH: '/healthcheck'
```
#### Custom healthcheck run time, change from (default) `2s` (2 seconds) to `1m` (one minute)
If your healthcheck may take awhile to run & succeed, you can increase the amount of time the `consul` healthcheck allows your HTTP request to run.
```yaml
variables:
  NOMAD_VAR_CHECK_TIMEOUT: '1m'
```
#### Custom time to start healthchecking after container re/start from (default) `20s` (20 second) to `3m` (3 minutes)
If your container takes awhile, after startup, to settle before healthchecking can work reliably, you can extend the wait time for the first healthcheck to run.
```yaml
variables:
  NOMAD_VAR_HEALTH_TIMEOUT: '3m'
```
#### Custom running container count from (default) 1 to 3
You can run more than one container for increased reliability, more request processing, and more reliable uptimes (in the event of one or more Virtual Machines hosting containers having issues).

For archive.org users, we suggest instead to switch your production deploy to our alternate production cluster.

Keep in mind, you will have 2+ containers running simultaneously (_usually_, but not always, on different VMs).  So if your webapp uses any shared resources, like backends not in containers, or "persistent volumes", that you will need to think about concurrency, potentially multiple writers, etc. 😊
```yaml
variables:
  NOMAD_VAR_COUNT: 3
```
#### Custom make NFS `/home/` available in running containers, readonly
Allow your containers to see NFS `/home/` home directories, readonly.
```yaml
variables:
  NOMAD_VAR_VOLUMES: '["/home:/home:ro"]'
```
#### Custom make NFS `/home/` available in running containers, read/write
Allow your containers to see NFS `/home/` home directories, readable and writable.  Please be highly aware of operational security in your container when using this (eg: switch your `USER` in your `Dockerfile` to another non-`root` user; use "prepared statements" with any DataBase interactions; use [https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP](Content Security Policy) in all your pages to eliminate [https://developer.mozilla.org/en-US/docs/Glossary/Cross-site_scripting](XSS attacks, etc.)
```yaml
variables:
  NOMAD_VAR_VOLUMES: '["/home:/home:rw"]'
```
#### Custom hostname for your `main` branch deploy
Your deploy will get a nice semantic hostname by default, based upon "[slugged](https://en.wikipedia.org/wiki/Clean_URL#Slug)" formula like: https://[GITLAB_GROUP]-[GITLAB_PROJECT_OR_REPO_NAME]-[BRANCH_NAME].  However, you can override this if needed.  This custom hostname will only pertain to a branch named `main` (or `master` [sic])
```yaml
variables:
  NOMAD_VAR_HOSTNAMES: '["www.example.com"]'
```
#### Custom hostnameS for your `main` branch deploy
Similar to prior example, but you can have your main deployment respond to multiple hostnames if desired.
```yaml
variables:
  NOMAD_VAR_HOSTNAMES: '["www.example.com", "store.example.com"]'
```

#### Multiple containers in same job spec
If you want to run multiple containers in the same job and group, set this to true.  For example, you might want to run a Postgresql 3rd party container from bitnami, and have the main/http front-end container talk to it.  Being in the same group will ensure all containers run on the same VM; which makes communication between them extremely easy.  You simply need to inspect environment variables.

You can see a minimal example of two containers with a "front end" talking to a "backend" here
https://gitlab.com/internetarchive/nomad-multiple-tasks

See also a [postgres DB setup example](#postgres-db).
```yaml
variables:
  NOMAD_VAR_MULTI_CONTAINER: 'true'
```

#### Force `docker pull` before container starts
If your deployment's job spec doesn't change between pipelines for some reason, you can set this to ensure `docker pull` always happens before your container starts up.  A good example where you might see this is a periodic/batch/cron process that fires up a pipeline without any repository commit.  Depending on your workflow and `Dockerfile` from there, if you see "stale" versions of containers, use this customization.
```yaml
variables:
  NOMAD_VAR_FORCE_PULL: 'true'
```

#### Turn off [deploy canaries](https://learn.hashicorp.com/tutorials/nomad/job-blue-green-and-canary-deployments)
When a new deploy is happening, live traffic continues to old deploy about to be replaced, while a new deploy fires off in the background and `nomad` begins healthchecking.  Only once it seems healthy, is traffic cutover to the new container and the old container removed.  (If unhealthy, new container is removed).  That can mean *two* deploys can run simultaneously.  Depending on your setup and constraints, you might not want this and can disable canaries with this snippet below.  (Keep in mind your deploy will temporarily 404 during re-deploy *without* using blue/green deploys w/ canaries).
```yaml
variables:
  NOMAD_VAR_COUNT_CANARIES: 0
```

#### Change your deploy to a cron-like batch/periodic
If you deployment is something you want to run periodically, instead of continuously, you can use this variable to switch to a nomad `type="batch"`
```yaml
variables:
  NOMAD_VAR_IS_BATCH: 'true'
```
Combine your `NOMAD_VAR_IS_BATCH` override, with a small `job.nomad` file in your repo to setup your cron behaviour.

Example `job.nomad` file contents, to run the deploy every hour at 15m past the hour:
```ini
type = "batch"
periodic {
    cron = "15 * * * * *"
    prohibit_overlap = false  # must be false cause of kv env vars task
}
```

#### Custom deploy networking
If your admin allows it, there might be some useful reasons to use VM host networking for your deploy.  A good example is "relaying" UDP *broadcast* messages in/out of a container.  Please see Tracey if interested, archive folks. :)
```yaml
variables:
  NOMAD_VAR_NETWORK_MODE: 'host'
```

#### Custom namespacing
A job can be limited to a specific 'namespace' for purposes of ACL 'gating'.
In the example below, a cluster admin could create a custom `NOMAD_TOKEN` that only allows the
bearer to access jobs part of the namespace `team-titan`.
```yaml
variables:
  NOMAD_VAR_NAMESPACE: 'team-titan'
```



#### More customizations
There are even more, less common, ways to customize your deploys.

With other variables, like `NOMAD_VAR_PORTS`, you can use dynamic port allocation, setup daemons that use raw TCP, and more.

Please see the top area of [project.nomad](project.nomad) for "Persistent Volumes" (think a "disk" that survives container restarts), additional open ports into your webapp, and more.

See also [this section](#optional-add-ons-to-your-project) below.

### Deploying to production nomad cluster (archive.org only)
Our production cluster has 3 VMs and will deploy your repo to a running container on each VM, using `haproxy` load balancer to balance requests.

This should ensure much higher availability and handle more requests.

Keep in mind if your deployment uses a "persistent volume" or talks to other backend services, they'll be getting traffic and access from multiple containers simultaneously.

Setting up your repo to deploy to production is easy!

- add a CI/CD Secret `NOMAD_TOKEN_PROD` with the nomad cluster value (ask tracey or scott)
  - make it: protected, masked, hidden
![Production CI/CD Secret](img/prod.jpg)
- Make a new branch named `production` (presumably from your repo's latest `main` or `master` branch)
  - It should now deploy your project to a different `NOMAD_ADDR` url
  - Your default hostname domain will change from `.dev.archive.org` to `.prod.archive.org`
- [GitLab only] - [Protect the `production` branch](https://docs.gitlab.com/ee/user/project/protected_branches.html)
  - suggest using same settings as your `main` or `master` (or default) branch
![Protect a branch](img/protect.jpg)


### Deploying to staging nomad cluster (archive.org only)
Our staging cluster will deploy your repo to a running container on one of its VMs.

Setting up your repo to deploy to staging is easy!

- add a CI/CD Secret `NOMAD_TOKEN_STAGING` with the nomad cluster value (ask tracey or scott)
  - make it: protected, masked, hidden (similar to `production` section above)
- Make a new branch named `staging` (presumably from your repo's latest `main` or `master` branch)
  - It should now deploy your project to a different `NOMAD_ADDR` url
  - Your default hostname domain will change from `.dev.archive.org` to `.staging.archive.org`
- [GitLab only] - [Protect the `staging` branch](https://docs.gitlab.com/ee/user/project/protected_branches.html)
  - suggest using same settings as your `main` or `master` (or default) branch, changing `production` to `staging` here:
![Protect a branch](img/protect.jpg)


## Laptop access
- create `$HOME/.config/nomad` and/or get it from an admin who setup your Nomad cluster
  - @see top of [aliases](aliases)
  - `brew install nomad`
  - `source $HOME/.config/nomad`
    - better yet:
      - `git clone https://github.com/internetarchive/nomad`
      - adjust next line depending on where you checked out the above repo
      - add this to your `$HOME/.bash_profile` or `$HOME/.zshrc` etc.
        - `FI=$HOME/nomad/aliases  &&  [ -e $FI ]  &&  source $FI`
  - then `nomad status` should work nicely
    -  @see [aliases](aliases) for lots of handy aliases..
- you can then also use your browser to visit [$NOMAD_ADDR/ui/jobs](https://MY-HOSTNAME:4646/ui/jobs)
  - and enter your `$NOMAD_TOKEN` in the ACL requirement


# Setup a Nomad Cluster
- we use HinD: https://github.com/internetarchive/hind
  - you can customize the install with various environment variables

Other alternatives:
- have DNS domain you can point to a VM?
  - nomad/consul with $5/mo VM (or on-prem)
    - [[1/2] Setup GitLab, Nomad, Consul & Fabio](https://tracey.archive.org/devops/2021-03-31)
    - [[2/2] Add GitLab Runner & Setup full CI/CD pipelines](https://tracey.archive.org/devops/2021-04-07)
- have DNS domain and want on-prem GitLab?
  - nomad/consul/gitlab/runners with $20/mo VM (or on-prem)
    - [[1/2] Setup GitLab, Nomad, Consul & Fabio](https://tracey.archive.org/devops/2021-03-31)
    - [[2/2] Add GitLab Runner & Setup full CI/CD pipelines](https://tracey.archive.org/devops/2021-04-07)
- no DNS - run on mac/linux laptop?
  - [[1/3] setup GitLab & GitLab Runner on your Mac](https://tracey.archive.org/devops/2021-02-17)
  - [[2/3] setup Nomad & Consul on your Mac](https://tracey.archive.org/devops/2021-02-24)
  - [[3/3] connect: GitLab, GitLab Runner, Nomad & Consul](https://tracey.archive.org/devops/2021-03-10)


# Monitoring GUI urls (via ssh tunnelling above)
![Cluster Overview](https://tracey.archive.org/images/nomad-ui4.jpg)
- nomad really nice overview (see `Topology` link ☝)
  - https://[NOMAD-HOST]:4646 (eg: `$NOMAD_ADDR`)
  - then enter your `$NOMAD_TOKEN`
- @see [aliases](aliases)  `nom-tunnel`
  - http://localhost:8500  # consul


# Inspect, poke around
```bash
nomad node status
nomad node status -allocs
nomad server members


nomad job run example.nomad
nomad job status
nomad job status example

nomad job deployments -t '{{(index . 0).ID}}' www-nomad
nomad job history -json www-nomad

nomad alloc logs -stderr -f $(nomad job status www-nomad |egrep -m1 '\srun\s' |cut -f1 -d' ')


# get CPU / RAM stats and allocations
nomad node status -self

nomad node status # OR pick a node's 1st column, then
nomad node status 01effcb8

# get list of all services, urls, and more, per nomad
wget -qO- --header "X-Nomad-Token: $NOMAD_TOKEN" $NOMAD_ADDR/v1/jobs |jq .
wget -qO- --header "X-Nomad-Token: $NOMAD_TOKEN" $NOMAD_ADDR/v1/job/JOB-NAME |jq .


# get list of all services and urls, per consul
consul catalog services -tags
wget -qO- 'http://127.0.0.1:8500/v1/catalog/services' |jq .
```

# Optional add-ons to your project

## Secrets
In your project/repo Settings, set CI/CD environment variables starting with `NOMAD_SECRET_`, marked `Masked` but _not_ `Protected`, eg:
![Secrets](img/secrets.jpg)
and they will show up in your running container as environment variables, named with the lead `NOMAD_SECRET_` removed.  Thus, you can get `DATABASE_URL` (etc.) set in your running container - but not have it anywhere else in your docker image and not printed/shown during CI/CD pipeline phase logging.


## Persistent Volumes
Persistent Volumes (PV) are like mounted disks that get setup before your container starts and _mount_ in as a filesystem into your running container.  They are the only things that survive a running deployment update (eg: a new CI/CD pipeline), container restart, or system move to another cluster VM - hence _Persistent_.

You can use PV to store files and data - especially nice for databases or otherwise (eg: retain `/var/lib/postgresql` through restarts, etc.)

Here's how you'd update your project's `.gitlab-ci.yml` file,
by adding these lines (suggest near top of your file):
```yaml
variables:
  NOMAD_VAR_PERSISTENT_VOLUME: '/pv'
```
Then the dir `/pv/` will show up (blank to start with) in your running container.

If you'd like to have the mounted dir show up somewhere besides `/pv` in your container,
you can setup like:
```yaml
variables:
  NOMAD_VAR_PERSISTENT_VOLUME: '/var/lib/postgresql'
```

Please verify added/updated files persist through two repo CI/CD pipelines before adding important data and files.  Your DevOps teams will try to ensure the VM that holds the data is backed up - but that does not happen by default without some extra setup.  Your DevOps team must ensure each VM in the cluster has (the same) shared `/pv/` directory.  We presently use NFS for this (after some data corruption issues with glusterFS and rook/ceph).


## Postgres DB
We have a [postgresql example](https://git.archive.org/www/dwebcamp2019), visible to archive.org folks.  But the gist, aside from a CI/CD Variable/Secret `POSTGRESQL_PASSWORD`, is below.

_Keep in mind if you setup something like a database in a container, using a Persistent Volume (like below) you can get multiple containers each trying to write to your database backing store filesystem (one for production; one temporarily for production re-deploy "canary"; and similar 1 or 2 for every deployed branch (which is probably not what you want).  So you might want to look into `NOMAD_VAR_COUNT` and `NOMAD_VAR_COUNT_CANARIES` in that case._

It's recommended to run the DB container during the prestart hook as a "sidecar" service (this will cause it to finish starting before any other group tasks initialize, avoiding service start failures due to unavailable DB, see [nomad task dependencies](https://www.hashicorp.com/blog/hashicorp-nomad-task-dependencies) for more info)

`.gitlab-ci.yml`:
```yaml
variables:
  NOMAD_VAR_MULTI_CONTAINER: 'true'
  NOMAD_VAR_PORTS: '{ 5000 = "http", 5432 = "db" }'
  NOMAD_VAR_PERSISTENT_VOLUME: '/bitnami/postgresql'
  NOMAD_VAR_CHECK_PROTOCOL: 'tcp'
  # avoid 2+ containers running where both try to write to database
  NOMAD_VAR_COUNT: 1
  NOMAD_VAR_COUNT_CANARIES: 0

include:
  - remote: 'https://raw.githubusercontent.com/internetarchive/nomad/refs/heads/main/gitlab.yml'
```
`vars.nomad`:
```ini
# used in @see group.nomad
variable "POSTGRESQL_PASSWORD" {
  type = string
  default = ""
}
```
`group.nomad`:
```ini
task "db" {
  driver = "docker"
  lifecycle {
    sidecar = true
    hook = "prestart"
  }
  config {
    image = "docker.io/bitnami/postgresql:11.7.0-debian-10-r9"
    ports = ["db"]
    volumes = ["/pv/${var.CI_PROJECT_PATH_SLUG}:/bitnami/postgresql"]
  }
  template {
    data = <<EOH
POSTGRESQL_PASSWORD="${var.POSTGRESQL_PASSWORD}"
EOH
    destination = "secrets/file.env"
    env         = true
  }
}
```
`Dockerfile`: (setup DB env var, then fire up django front-end..)
```
...
CMD echo DATABASE_URL=postgres://postgres:${POSTGRESQL_PASSWORD}@${NOMAD_ADDR_db}/production >| .env && python ...
```

---

## Two `group`s, within same `job`, wanting to talk to each other
Normally, we strongly suggest all `task`s be together in the same `group`.
That will ensure all task containers are run on the same VM, and all tasks will get automatically managed and setup `env` vars, eg:
```ini
NOMAD_ADDR_backend=211.204.226.244:27344
NOMAD_ADDR_http=211.204.226.244:23945
```

However, if for some reason you want to split your tasks into 2+ `group { .. }` stanzas,
here is how you can get the containers to talk to each other (using `consul` and templating):
- https://github.com/hashicorp/nomad/issues/5455#issuecomment-482490116
You'd end up putting your 2nd `group` in a file named `job.nomad` in the top of your repo.

---

# GitHub repo integrations
## GitHub Actions
- We use GitHub Actions to create [build], [test], and [deploy] CI/CD pipelines.
- There is a lot of great information and links to example repos here: https://github.com/internetarchive/cicd#readme

## GitHub Customizing
- You can use the same `NOMAD_VAR_` options above to tailor your deploy in the [#Customizing](#Customizing) section above.  [Documentation and examples here](https://github.com/internetarchive/cicd#readme).

## GitHub Secrets
- You can add GitHub secrets to your repo from the GitHub GUI ([documentation](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-a-repository)). You then need to get those secrets to pass through to the [deploy] phase, using the `NOMAD_SECRETS` setting in the GitHub Actions workflow yaml file.
- Note that you may want to test with repository or organizational level secrets before proceeding to setup environment secrets ( [documentation around creating secrets for an environment](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-a-repository) )
- Here is an example GH repo that passes 2 GH secrets into the [deploy] phase. Each secret will wind up as environment variable that your servers can read, or your `RUN`/`CMD` entrypoint can read:
  - https://github.com/traceypooh/staticman/blob/main/.github/workflows/cicd.yml
    - [entrypoint setup](https://github.com/traceypooh/staticman/blob/main/Dockerfile)
    - [entrypoint script](https://github.com/traceypooh/staticman/blob/main/entrypoint.sh)

---

# Helpful links
- https://youtube.com/watch?v=3K1bSGN7zGA 'HashiConf Digital June 2020 - Full Opening Keynote'
- https://www.nomadproject.io/docs/install/production/deployment-guide/
- https://learn.hashicorp.com/nomad/managing-jobs/configuring-tasks
- https://www.burgundywall.com/post/continuous-deployment-gitlab-and-nomad
- https://weekly-geekly.github.io/articles/453322/index.html
- https://www.haproxy.com/blog/haproxy-and-consul-with-dns-for-service-discovery/
- https://www.youtube.com/watch?v=gf43TcWjBrE  Kelsey Hightower, HashiConf 2016
- https://blog.tjll.net/reverse-proxy-hot-dog-eating-contest-caddy-vs-nginx/#results
- https://github.com/hashicorp/consul-template/issues/200#issuecomment-76596830

## Pick your container stack / testimonials
- https://www.hashicorp.com/blog/hashicorp-joins-the-cncf/
- https://www.nomadproject.io/intro/who-uses-nomad/
  - + http://jet.com/walmart
- https://medium.com/velotio-perspectives/how-much-do-you-really-know-about-simplified-cloud-deployments-b74d33637e07
- https://blog.cloudflare.com/how-we-use-hashicorp-nomad/
- https://www.hashicorp.com/resources/ncbi-legacy-migration-hybrid-cloud-consul-nomad/
- https://thenewstack.io/fargate-grows-faster-than-kubernetes-among-aws-customers/
- https://github.com/rishidot/Decision-Makers-Guide/blob/master/Decision%20Makers%20Guide%20-%20Nomad%20Vs%20Kubernetes%20-%20Oct%202019.pdf
- https://medium.com/@trevor00/building-container-platforms-part-one-introduction-4ee2338eb11



# Multi-node architecture
![Architecture](img/architecture.drawio.svg)


# Requirements for archive.org CI/CD
- docker exec ✅
  - pop into deployed container and poke around - similar to `ssh`
  - @see [aliases](aliases)  `nom-ssh`
- docker cp ✅
  - hot-copy edited file into _running_ deploy (avoid full pipeline to see changes)
  - @see [aliases](aliases)  `nom-cp`
  - hook in VSCode
    [sync-rsync](https://marketplace.visualstudio.com/items?itemName=vscode-ext.sync-rsync)
    package to 'copy (into container) on save'
- secrets ✅
- load balancers ✅
- 2+ instances HPA ✅
- PV ✅
- http/2 ✅
- auto http => https ✅
- web sockets ✅
- auto-embed HSTS in https headers, similar to kubernetes ✅
  - eg: `Strict-Transport-Security: max-age=15724800; includeSubdomains`


# Constraints
In the past, we've made it so certain jobs are "constrained" to run on specifc 1+ cluster VM.

Here's how you can do it:
You can manually add this to 1+ VM `/etc/nomad/nomad.hcl` file:
```ini
client {
  meta {
    "kind" = "tcp-vm"
  }
}
```

You can add this as a new file named `job.nomad` in the top of a project/repo:
```ini
constraint {
  attribute = "${meta.kind}"
  operator = "set_contains"
  value = "tcp-vm"
}
```

Then deploys for this repo will *only* deploy to your specific VMs.
