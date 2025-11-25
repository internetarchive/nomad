# Variables used below and their defaults if not set externally
variables {
  # GitHub (GH) and GitLab (GL) do things slightly differently.
  # Some defaults are filled in w/ example repo "hello-js" in group "internetarchive".
  # GitHub:
  #   normally `deploy.sh` in the same dir as this file use `$GITHUB_REPOSITORY` to setup
  #   what's needed for these first 7-8 vars.
  # GitLab:
  #   these all pass through from  [deploy] phase.
  #   all 8-9 of these first vars get replaced during normal GitLab CI/CD from CI/CD variables.
  CI_REGISTRY = "ghcr.io"                              # registry hostname
  CI_REGISTRY_IMAGE = "ghcr.io/internetarchive"        # registry image location
  CI_REGISTRY_TAG = "main"                             # GH: branch name; GL: commit sha
  CI_COMMIT_REF_SLUG = "hello-js"                      # GH: repo name; GL: branch name. slugged
  CI_COMMIT_SHA = "main"                               # GH: branch name; GL: commit sha
  CI_PROJECT_PATH_SLUG = "internetarchive-hello-js"    # repo and group it is part of, slugged

  # NOTE: if repo is public, you can ignore these next 3 registry related vars
  # These next 2 get set automatically in gitlab pipelines
  CI_REGISTRY_USER = ""                                     # set for each pipeline and ..
  CI_REGISTRY_PASSWORD = ""                                 # .. allows pull from private registry
  # optional CI/CD gitlab/github registry read token, allowing rerun of deploy phase anytime later
  CI_REGISTRY_READ_TOKEN = ""                               # preferred name


  # This autogenerates from `deploy.sh` in the same dir (look for `export NOMAD_VAR_SLUG`).
  # It normally has "-$CI_COMMIT_REF_SLUG" appended, but is omitted for "main" or "master" branches.
  # You should not change this.
  SLUG = "internetarchive-hello-js"


  # The remaining vars can be optionally set/overriden via:
  #   [github] a github action, eg: https://github.com/internetarchive/cicd
  #   [gitlab] the repo's `.gitlab-ci.yml` file, or its Settings > CI/CD > Variables
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
  # Note: use -1 for your port to tell nomad & docker to *dynamically* assign you a random high port
  #       then your repo can read the environment variable: NOMAD_PORT_http upon startup to know
  #       what your main daemon HTTP listener should listen on.
  #
  # Note: if your port *only* talks TCP directly (or some variant of it, like IRC) and *not* HTTP,
  #       then make your port number (key) *negative AND less than -1*.
  #       Don't worry -- we'll use the abs() of it;
  #       negative numbers makes them easily identifiable and partition-able below ;-)
  #
  # Examples:
  #   NOMAD_VAR_PORTS='{ 5000 = "http" }'
  #   NOMAD_VAR_PORTS='{ -1 = "http" }'
  #   NOMAD_VAR_PORTS='{ 5000 = "http", 666 = "cool-ness" }'
  #   NOMAD_VAR_PORTS='{ 8888 = "http", 8012 = "backend", 7777 = "extra-service" }'
  #   NOMAD_VAR_PORTS='{ 5000 = "http", -7777 = "irc" }'
  type = map(string)
  default = { 5000 = "http" }
}

variable "HOSTNAMES" {
  # This autogenerates from https://github.com/internetarchive/nomad/blob/main/ci.yml
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

locals {
  # Ignore all this.  really :)

  # Split the ports hashmap into three hashmaps:
  #  - just the key/val for the main/default port (defaults to 5000)
  #  - extra HTTPS port mappings
  #  - TCP (only; rare) port mappings
  ports_main        = {for k, v in var.PORTS:     k  => v  if v == "http"}
  ports_extra_https = {for k, v in var.PORTS:     k  => v  if v != "http" && k > -2}
  ports_extra_tcp   = {for k, v in var.PORTS: abs(k) => v  if v != "http" && k < -1}
  # 1st docker container configures all ports *unless* MULTI_CONTAINER is true, then just main port
  ports_docker = values(var.MULTI_CONTAINER ? local.ports_main : var.PORTS)

  # Now create a hashmap of *all* ports to be used, but abs() any portnumber key < -1
  ports_all = merge(local.ports_main, local.ports_extra_https, local.ports_extra_tcp, {})

  # Use CI_GITHUB_IMAGE if set, otherwise use GitLab vars interpolated string
  docker_image = var.CI_GITHUB_IMAGE != "" ? var.CI_GITHUB_IMAGE : "${var.CI_REGISTRY_IMAGE}/${var.CI_COMMIT_REF_SLUG}:${var.CI_REGISTRY_TAG}"
  # "

  # GitLab docker login user/pass timeout rather quickly.  If admin set CI_REGISTRY_READ_TOKEN key
  # in the group/repo [Settings] [CI/CD] [Variables] - then use a token-based alternative to deploy.
  # Effectively, use CI_REGISTRY_READ_TOKEN variant if set; else use CI_REGISTRY_* PAIR
  docker_user = var.CI_REGISTRY_READ_TOKEN != "" ? "deploy-token" : var.CI_REGISTRY_USER
  docker_pass = [for s in [var.CI_REGISTRY_READ_TOKEN, var.CI_REGISTRY_PASSWORD] : s if s != ""]
  # Make [true] (array of length 1) if all docker password vars are ""
  docker_no_login = length(local.docker_pass) > 0 ? [] : [true]


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

  tags = merge(
    {for portnum, portname in local.ports_extra_https: portname => [
      # If the main deploy hostname is `card.example.com`, and a 2nd port is named `backend`,
      # then make its hostname be `card-backend.example.com`
      "https://${local.host0}-${portname}.${local.host0domain}"
    ]},
    {for portnum, portname in local.ports_extra_tcp: portname => []}
  )
}


# VARS.NOMAD--INSERTS-HERE


# NOTE: for main or master branch: NOMAD_VAR_SLUG === CI_PROJECT_PATH_SLUG
job "NOMAD_VAR_SLUG" {
  datacenters = ["dc1"]
  namespace = "${var.NAMESPACE}"

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

  dynamic "group" {
    for_each = [ "${var.SLUG}" ]
    labels = ["${group.value}"]
    content {
      count = var.COUNT

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

        tags = [for HOST in var.HOSTNAMES: "https://${HOST}"]

        canary_tags = [for HOST in var.HOSTNAMES: "https://canary-${HOST}"]

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
        for_each = merge(local.ports_extra_https, local.ports_extra_tcp)
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
            memory_hard_limit = "${var.MEMORY * 10}" # NOTE: not podman driver compatible
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
            memory_hard_limit = "${var.MEMORY * 10}" # NOTE: not podman driver compatible

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


        template {
          # Secrets get stored in consul kv store, with the key [SLUG], when your project has set a
          # CI/CD variable like NOMAD_SECRET_[SOMETHING].
          # Setup the nomad job to dynamically pull secrets just before the container starts -
          # and insert them into the running container as environment variables.
          change_mode = "noop"
          destination = "secrets/kv.env"
          env         = true
          data = "{{ key \"${var.SLUG}\" }}"
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
