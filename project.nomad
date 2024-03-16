# Variables used below and their defaults if not set externally
variables {
  # These all pass through from GitLab [build] phase.
  # Some defaults filled in w/ example repo "bai" in group "internetarchive"
  # (but all 7 get replaced during normal GitLab CI/CD from CI/CD variables).
  CI_REGISTRY = "registry.gitlab.com"                       # registry hostname
  CI_REGISTRY_IMAGE = "registry.gitlab.com/internetarchive/bai"  # registry image location
  CI_COMMIT_REF_SLUG = "master"                             # branch name, slugged
  CI_COMMIT_SHA = "latest"                                  # repo's commit for current pipline
  CI_PROJECT_PATH_SLUG = "internetarchive-bai"              # repo and group it is part of, slugged

  # NOTE: if repo is public, you can ignore these next 3 registry related vars
  CI_REGISTRY_USER = ""                                     # set for each pipeline and ..
  CI_REGISTRY_PASSWORD = ""                                 # .. allows pull from private registry
  # optional CI/CD registry read token which allows rerun of deploy phase anytime later
  CI_REGISTRY_READ_TOKEN = ""                               # preferred name


  # This autogenerates from https://gitlab.com/internetarchive/nomad/-/blob/master/.gitlab-ci.yml
  # & normally has "-$CI_COMMIT_REF_SLUG" appended, but is omitted for "main" or "master" branches.
  # You should not change this.
  SLUG = "internetarchive-bai"


  # The remaining vars can be optionally set/overriden in a repo via CI/CD variables in repo's
  # setting or repo's `.gitlab-ci.yml` file.
  # Each CI/CD var name should be prefixed with 'NOMAD_VAR_'.

  # default 300 MB
  MEMORY = 300
  # default 100 MHz
  CPU =    100

  # A repo can set this to "tcp" - can help for debugging 1st deploy
  CHECK_PROTOCOL = "http"
  # What path healthcheck should use and require a 200 status answer for succcess
  CHECK_PATH = "/"
  # Allow individual, periodic healthchecks this much time to answer with 200 status
  CHECK_TIMEOUT = "2s"
  # Dont start first healthcheck until container up at least this long (adjust for slow startups)
  HEALTH_TIMEOUT = "20s"

  # How many running containers should you deploy?
  # https://learn.hashicorp.com/tutorials/nomad/job-rolling-update
  COUNT = 1

  COUNT_CANARIES = 1

  NETWORK_MODE = "bridge"

  NAMESPACE = "default"

  # only used for github repos
  CI_GITHUB_IMAGE = ""

  CONSUL_PATH = "/usr/bin/consul"

  FORCE_PULL = false

  # For jobs with 2+ containers (and tasks) (so we can setup ports properly)
  MULTI_CONTAINER = false

  # Persistent Volume - set to a (fully qualified) dest dir inside your container, if you need a PV.
  # We suggest "/pv".
  PERSISTENT_VOLUME = ""

  /* You can overrride this for type="batch" and "cron-like" jobs (they rerun periodically & exit).
     Combine this var override, with a small `job.nomad` in your repo to setup a cron,
     with contents in the file like this, to run every hour at 15m past the hour:
        type = "batch"
        periodic {
            cron = "15 * * * * *"
            prohibit_overlap = false  # must be false cause of kv env vars task
        }
   */
  IS_BATCH = false

  # There are more variables immediately after this - but they are "lists" or "maps" and need
  # special definitions to not have defaults or overrides be treated as strings.
}

variable "PORTS" {
  # You must have at least one key/value pair, with a single value of 'http'.
  # Each value is a string that refers to your port later in the project jobspec.
  #
  # Note: these are all public ports, right out to the browser.
  #
  # Note: for a single *nomad cluster* -- anything not 5000 must be
  #       *unique* across *all* projects deployed there.
  #
  # Note: use -1 for your port to tell nomad & docker to *dynamically* assign you a random high port
  #       then your repo can read the environment variable: NOMAD_PORT_http upon startup to know
  #       what your main daemon HTTP listener should listen on.
  #
  # Note: if your port *only* talks TCP directly (or some variant of it, like IRC) and *not* HTTP,
  #       then make your port number (key) *negative AND less than -1*.
  #       Don't worry -- we'll use the abs() of it;
  #       negative numbers makes them easily identifiable and partition-able below ;-)
  #
  # Note: if you want an extra port to only use HTTP and not HTTPS, add 10000 to your desired
  #       port number (so for 18989, the public url will be http://...  mapped internally to :8989 ).
  #
  # Examples:
  #   NOMAD_VAR_PORTS='{ 5000 = "http" }'
  #   NOMAD_VAR_PORTS='{ -1 = "http" }'
  #   NOMAD_VAR_PORTS='{ 5000 = "http", 666 = "cool-ness" }'
  #   NOMAD_VAR_PORTS='{ 8888 = "http", 8012 = "backend", 7777 = "extra-service" }'
  #   NOMAD_VAR_PORTS='{ 5000 = "http", -7777 = "irc" }'
  #   NOMAD_VAR_PORTS='{ 5000 = "http", 18989 = "db" }'
  type = map(string)
  default = { 5000 = "http" }
}

variable "HOSTNAMES" {
  # This autogenerates from https://gitlab.com/internetarchive/nomad/-/blob/master/.gitlab-ci.yml
  # but you can override to 1 or more custom hostnames if desired, eg:
  #   NOMAD_VAR_HOSTNAMES='["www.example.com", "site.example.com"]'
  type = list(string)
  default = ["group-project-branch-slug.example.com"]
}

variable "VOLUMES" {
  # Pass in a list of [host VM => container] direct pass through of volumes, eg:
  #   NOMAD_VAR_VOLUMES='["/usr/games:/usr/games:ro"]'
  type = list(string)
  default = []
}

variable "NOMAD_SECRETS" {
  # this is automatically populated with NOMAD_SECRET_ env vars by @see .gitlab-ci.yml
  type = map(string)
  default = {}
}


locals {
  # Ignore all this.  really :)

  # Copy hashmap, but remove map key/val for the main/default port (defaults to 5000).
  # Then split hashmap in two: one for HTTP port mappings; one for TCP (only; rare) port mappings.
  ports_main        = {for k, v in var.PORTS:                 k          => v  if v == "http"}
  ports_extra_tmp   = {for k, v in var.PORTS:                 k          => v  if v != "http"}
  ports_extra_tmp2  = {for k, v in local.ports_extra_tmp:     k          => v  if k > -2}
  ports_extra_https = {for k, v in local.ports_extra_tmp2:    k          => v  if k < 10000}
  ports_extra_http  = {for k, v in local.ports_extra_tmp: abs(k - 10000) => v  if k > 10000}
  ports_extra_tcp   = {for k, v in local.ports_extra_tmp: abs(k)         => v  if k < -1}
  # 1st docker container configures all ports *unless* MULTI_CONTAINER is true, then just main port
  ports_docker = values(var.MULTI_CONTAINER ? local.ports_main : var.PORTS)

  # Now create a hashmap of *all* ports to be used, but abs() any portnumber key < -1
  ports_all = merge(local.ports_main, local.ports_extra_https, local.ports_extra_http, local.ports_extra_tcp, {})

  # Use CI_GITHUB_IMAGE if set, otherwise use GitLab vars interpolated string
  docker_image = var.CI_GITHUB_IMAGE != "" ? var.CI_GITHUB_IMAGE : "${var.CI_REGISTRY_IMAGE}/${var.CI_COMMIT_REF_SLUG}:${var.CI_COMMIT_SHA}"

  # GitLab docker login user/pass timeout rather quickly.  If admin set CI_REGISTRY_READ_TOKEN key
  # in the group/repo [Settings] [CI/CD] [Variables] - then use a token-based alternative to deploy.
  # Effectively, use CI_REGISTRY_READ_TOKEN variant if set; else use CI_REGISTRY_* PAIR
  docker_user = var.CI_REGISTRY_READ_TOKEN != "" ? "deploy-token" : var.CI_REGISTRY_USER
  docker_pass = [for s in [var.CI_REGISTRY_READ_TOKEN, var.CI_REGISTRY_PASSWORD] : s if s != ""]
  # Make [true] (array of length 1) if all docker password vars are ""
  docker_no_login = length(local.docker_pass) > 0 ? [] : [true]


  # If job is using secrets and CI/CD Variables named like "NOMAD_SECRET_*" then set this
  # string to a KEY=VAL line per CI/CD variable.  If job is not using secrets, set to "".
  kv = join("\n", [for k, v in var.NOMAD_SECRETS : join("", concat([k, "='", v, "'"]))])

  volumes = concat(
    var.VOLUMES,
    var.PERSISTENT_VOLUME == "" ? [] : ["/pv/${var.CI_PROJECT_PATH_SLUG}:${var.PERSISTENT_VOLUME}"],
  )

  auto_promote = var.COUNT_CANARIES > 0 ? true : false

  # make boolean-like array that can logically omit 2 `dynamic` blocks below for type=batch
  service_type = var.IS_BATCH ? [] : ["service"]

  # split the 1st hostname into non-domain and domain parts
  host0parts = split(".", var.HOSTNAMES[0])
  host0 = local.host0parts[0]
  host0domain = join(".", slice(local.host0parts, 1, length(local.host0parts)))

  legacy = var.CI_PROJECT_PATH_SLUG == "www-dweb-ipfs" ? true : (var.CI_PROJECT_PATH_SLUG == "www-dweb-webtorrent" ? true : false) # xxx

  legacy2 = local.host0domain == "staging.archive.org" || local.host0domain == "prod.archive.org" || var.HOSTNAMES[0] == "polyfill.archive.org" || var.HOSTNAMES[0] == "esm.archive.org" || var.HOSTNAMES[0] == "purl.archive.org" || var.HOSTNAMES[0] == "popcorn.archive.org" # xxx

  tags = local.legacy2 ? merge(
    {for portnum, portname in local.ports_extra_https: portname => [
      # If the main deploy hostname is `card.example.com`, and a 2nd port is named `backend`,
      # then make its hostname be `card-backend.example.com`
      "urlprefix-${local.host0}-${portname}.${local.host0domain}:443/",
      local.legacy ? "urlprefix-${var.HOSTNAMES[0]}:${portnum}/" : # xxx
        "urlprefix-${local.host0}-${portname}.${local.host0domain}:80/ redirect=308,https://${local.host0}-${portname}.${local.host0domain}$path"
    ]},
    {for portnum, portname in local.ports_extra_http: portname => [
      "urlprefix-${local.host0}-${portname}.${local.host0domain}/ proto=http"
    ]},
    {for portnum, portname in local.ports_extra_tcp: portname => [
      "urlprefix-:${portnum} proto=tcp"
    ]},
  ) : merge(
    {for portnum, portname in local.ports_extra_https: portname => [
      # If the main deploy hostname is `card.example.com`, and a 2nd port is named `backend`,
      # then make its hostname be `card-backend.example.com`
      local.legacy ? "https://${var.HOSTNAMES[0]}:${portnum}" : "https://${local.host0}-${portname}.${local.host0domain}" // xxx
    ]},
    {for portnum, portname in local.ports_extra_http: portname => [
      "http://${local.host0}-${portname}.${local.host0domain}"
    ]},
    {for portnum, portname in local.ports_extra_tcp: portname => []},
  )
}


# VARS.NOMAD--INSERTS-HERE


# NOTE: for main or master branch: NOMAD_VAR_SLUG === CI_PROJECT_PATH_SLUG
job "NOMAD_VAR_SLUG" {
  datacenters = ["dc1"]
  namespace = "${var.NAMESPACE}"

  dynamic "group" {
    for_each = [ "${var.SLUG}" ]
    labels = ["${group.value}"]
    content {
      count = var.COUNT

      dynamic "update" {
        for_each = local.service_type
        content {
          # https://learn.hashicorp.com/tutorials/nomad/job-rolling-update
          max_parallel  = 1
          # https://learn.hashicorp.com/tutorials/nomad/job-blue-green-and-canary-deployments
          canary = var.COUNT_CANARIES
          auto_promote  = local.auto_promote
          min_healthy_time  = "30s"
          healthy_deadline  = "10m"
          progress_deadline = "11m"
          auto_revert   = true
        }
      }
      restart {
        attempts = 3
        delay    = "15s"
        interval = "30m"
        mode     = "fail"
      }
      network {
        dynamic "port" {
          # port.key == portnumber
          # port.value == portname
          for_each = local.ports_all
          labels = [ "${port.value}" ]
          content {
            to = port.key
          }
        }
      }


      # The "service" stanza instructs Nomad to register this task as a service
      # in the service discovery engine, which is currently Consul. This will
      # make the service addressable after Nomad has placed it on a host and
      # port.
      #
      # For more information and examples on the "service" stanza, please see
      # the online documentation at:
      #
      #     https://www.nomadproject.io/docs/job-specification/service.html
      #
      service {
        name = "${var.SLUG}"
        task = "http"

        tags = concat(
          [for HOST in var.HOSTNAMES: local.legacy2 ? "urlprefix-${HOST}:443/" : "https://${HOST}"],
          local.legacy2 ? [for HOST in var.HOSTNAMES: "urlprefix-${HOST}:80/ redirect=308,https://${HOST}$path"] : [])

        canary_tags = concat(
          [for HOST in var.HOSTNAMES: local.legacy2 ? "urlprefix-canary-${HOST}:443/" : "https://canary-${HOST}/"],
          local.legacy2 ? [for HOST in var.HOSTNAMES: "urlprefix-canary-${HOST}:80/ redirect=308,https://canary-${HOST}/"] : [])

        port = "http"
        check {
          name     = "alive"
          type     = "${var.CHECK_PROTOCOL}"
          path     = "${var.CHECK_PATH}"
          port     = "http"
          interval = "10s"
          timeout  = "${var.CHECK_TIMEOUT}"
          check_restart {
            limit = 3  # auto-restart task when healthcheck fails 3x in a row

            # give container (eg: having issues) custom time amount to stay up for debugging before
            # 1st health check (eg: "3600s" value would be 1hr)
            grace = "${var.HEALTH_TIMEOUT}"
          }
        }
      }

      dynamic "service" {
        for_each = merge(local.ports_extra_https, local.ports_extra_http, local.ports_extra_tcp)
        content {
          # service.key == portnumber
          # service.value == portname
          name = "${var.SLUG}--${service.value}"
          task = var.MULTI_CONTAINER ? service.value : "http"
          # NOTE: Empty tags list if MULTI_CONTAINER (private internal ports like DB)
          tags = var.MULTI_CONTAINER ? [] : local.tags[service.value]

          port = "${service.value}"
          check {
            name     = "alive"
            type     = "tcp"
            path     = "${var.CHECK_PATH}"
            port     = "${service.value}"
            interval = "10s"
            timeout  = "${var.CHECK_TIMEOUT}"
          }
          check_restart {
            grace = "${var.HEALTH_TIMEOUT}"
          }
        }
      }

      task "http" {
        driver = "docker"

        # UGH - have to copy/paste this next block twice -- first for no docker login needed;
        #       second for docker login needed (job spec will assemble in just one).
        #       This is because we can't put dynamic content *inside* the 'config { .. }' stanza.
        dynamic "config" {
          for_each = local.docker_no_login
          content {
            image = "${local.docker_image}"
            image_pull_timeout = "20m"
            network_mode = "${var.NETWORK_MODE}"
            ports = local.ports_docker
            volumes = local.volumes
            force_pull = var.FORCE_PULL
            # memory_hard_limit = "${var.MEMORY * 10}" # not podman driver compatible
          }
        }
        dynamic "config" {
          for_each = slice(local.docker_pass, 0, min(1, length(local.docker_pass)))
          content {
            image = "${local.docker_image}"
            image_pull_timeout = "20m"
            network_mode = "${var.NETWORK_MODE}"
            ports = local.ports_docker
            volumes = local.volumes
            force_pull = var.FORCE_PULL
            # memory_hard_limit = "${var.MEMORY * 10}" # not podman driver compatible

            auth {
              # server_address = "${var.CI_REGISTRY}"
              username = local.docker_user
              password = "${config.value}"
            }
          }
        }

        resources {
          # The MEMORY var now becomes a **soft limit**
          # We will 10x that for a **hard limit**
          cpu    = "${var.CPU}"
          memory = "${var.MEMORY}"
          memory_max = "${var.MEMORY * 10}"
        }


        dynamic "template" {
          # Secrets get stored in consul kv store, with the key [SLUG], when your project has set a
          # CI/CD variable like NOMAD_SECRET_[SOMETHING].
          # Setup the nomad job to dynamically pull secrets just before the container starts -
          # and insert them into the running container as environment variables.
          for_each = slice(keys(var.NOMAD_SECRETS), 0, min(1, length(keys(var.NOMAD_SECRETS))))
          content {
            change_mode = "noop"
            destination = "secrets/kv.env"
            env         = true
            data = "{{ key \"${var.SLUG}\" }}"
          }
        }

        template {
          # Pass in useful hostname(s), repo & branch info to container's runtime as env vars
          change_mode = "noop"
          destination = "secrets/ci.env"
          env         = true
          data = <<EOH
CI_HOSTNAME=${var.HOSTNAMES[0]}
CI_COMMIT_REF_SLUG=${var.CI_COMMIT_REF_SLUG}
CI_PROJECT_PATH_SLUG=${var.CI_PROJECT_PATH_SLUG}
CI_COMMIT_SHA=${var.CI_COMMIT_SHA}
          EOH
        }
      } # end "task"

      dynamic "task" {
        # When a job has CI/CD secrets - eg: CI/CD Variables named like "NOMAD_SECRET_..."
        # then here is where we dynamically insert them into consul (as a single JSON k/v string).
        # NOTE: 4/2023 we switch from "exec" after a jammy ubuntu VM had cgroup perms issues.
        for_each = slice(keys(var.NOMAD_SECRETS), 0, min(1, length(keys(var.NOMAD_SECRETS))))
        labels = ["kv"]
        content {
          driver = "raw_exec"
          config {
            command = var.CONSUL_PATH
            args = [ "kv", "put", var.SLUG, local.kv ]
          }
          lifecycle {
            hook = "prestart"
            sidecar = false
          }
        }
      }

      # GROUP.NOMAD--INSERTS-HERE
    }
  } # end dynamic "group"


  reschedule {
    # Up to 20 attempts, 20s delays between fails, doubling delay between, w/ a 15m cap, eg:
    #
    # deno eval 'let tot=0; let d=20; for (let i=0; i < 20; i++) { console.warn({d, tot}); d=Math.min(900, d*2); tot += d }'
    attempts       = 10
    delay          = "20s"
    max_delay      = "1800s"
    delay_function = "exponential"
    interval       = "4h"
    unlimited      = false
  }

  spread {
    # Spread allocations equally over all nodes
    attribute = "${node.unique.id}"
  }

  dynamic "migrate" {
    for_each = local.service_type
    content {
      max_parallel = 3
      health_check = "checks"
      min_healthy_time = "15s"
      healthy_deadline = "10m"
    }
  }


  # This next part is for GitHub repos.  Since the GH docker image name DOESNT change each commit,
  # yet we need to ensure the jobspec sent to nomad "changes" each commit/pipeline,
  # auto-insert a random string.
  # Without this, nomad thinks it has already deployed the relevant registry image and jobspec,
  # referenced by and automatically created by the pipeline.
  dynamic "meta" {
    for_each = local.docker_no_login
    content {
      randomly = uuidv4()
    }
  }


  # JOB.NOMAD--INSERTS-HERE
} # end job
