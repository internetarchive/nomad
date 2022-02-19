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

  # NOTE: if repo is public, you can ignore these next 4 registry related vars
  CI_REGISTRY_USER = ""                                     # set for each pipeline and ..
  CI_REGISTRY_PASSWORD = ""                                 # .. allows pull from private registry
  # optional (but suggested!) CI/CD group or project vars:
  CI_R2_USER = ""                                           # optional more reliable alternative ..
  CI_R2_PASS = ""                                           # .. to 1st user/pass (see README.md)


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

  # Pass in "ro" or "rw" if you want an NFS /home/ mounted into container, as ReadOnly or ReadWrite
  HOME = ""

  NETWORK_MODE = "bridge"

  # only used for github repos
  CI_GITHUB_IMAGE = ""

  CONSUL_PATH = "/usr/bin/consul"

  FORCE_PULL = false

  # There are more variables immediately after this - but they are "lists" or "maps" and need
  # special definitions to not have defaults or overrides be treated as strings.
}

# Persistent Volume(s).  To enable, coordinate a free slot with your nomad cluster administrator
# and then set like, for PV slot 3 like:
#   NOMAD_VAR_PV='{ pv3 = "/pv" }'
#   NOMAD_VAR_PV='{ pv9 = "/bitnami/wordpress" }'
variable "PV" {
  type = map(string)
  default = {}
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
  # This autogenerates from https://gitlab.com/internetarchive/nomad/-/blob/master/.gitlab-ci.yml
  # but you can override to 1 or more custom hostnames if desired, eg:
  #   NOMAD_VAR_HOSTNAMES='["www.example.com", "site.example.com"]'
  type = list(string)
  default = ["group-project-branch-slug.example.com"]
}

variable "BIND_MOUNTS" {
  # Pass in a list of [host VM => container] direct pass through of readonly volumes, eg:
  #   NOMAD_VAR_BIND_MOUNTS='[{type = "bind", readonly = true, source = "/usr/games", target = "/usr/games"}]'
  type = list(map(string))
  default = []
}

variable "PG" {
  # Setup a postgres DB like NOMAD_VAR_PG='{ 5432 = "db" }' - or override port num if desired
  type = map(string)
  default = {}
}

variable "NOMAD_SECRETS" {
  # this is automatically populated with NOMAD_SECRET_ env vars by @see .gitlab-ci.yml
  type = map(string)
  default = {}
}


variable "NOT_PV" {
  # this is temporary until NFS server is setup for persistent volumes
  type = list(string)
  default = ["not pv"]
}


locals {
  # Ignore all this.  really :)
  job_names = [ "${var.SLUG}" ]

  # Copy hashmap, but remove map key/val for the main/default port (defaults to 5000).
  # Then split hashmap in two: one for HTTP port mappings; one for TCP (only; rare) port mappings.
  ports_main       = {for k, v in var.PORTS:                 k  => v  if v == "http"}
  ports_extra_tmp  = {for k, v in var.PORTS:                 k  => v  if v != "http"}
  ports_extra_http = {for k, v in local.ports_extra_tmp:     k  => v  if k > -2}
  ports_extra_tcp  = {for k, v in local.ports_extra_tmp: abs(k) => v  if k < -1}

  # Now create a hashmap of *all* ports to be used, but abs() any portnumber key < -1
  ports_all = merge(local.ports_main, local.ports_extra_http, local.ports_extra_tcp, var.PG, {})

  # NOTE: 2rd arg is hcl2 quirk needed in case first two args are empty maps as well
  pvs = merge(var.PV, {})

  # Make it so that later we can constrain deploy to server kind of _either_ pv or !pv kind server.
  # If PV is in use, constrain deployment to the single "pv" node in the cluster.
  kinds = concat([for k in keys(local.pvs): "pv"])
  # So if local.kinds is empty list (the default), set this to ["not pv"]; else set to []
  kinds_not = slice(var.NOT_PV, 0, min(length(var.NOT_PV), max(0, (1 - length(local.kinds)))))

  # Effectively use CI_GITHUB_IMAGE if set, otherwise use GitLab vars interpolated string
  docker_image = element([for s in [var.CI_GITHUB_IMAGE, "${var.CI_REGISTRY_IMAGE}/${var.CI_COMMIT_REF_SLUG}:${var.CI_COMMIT_SHA}"] : s if s != ""], 0)

  # GitLab docker login user/pass are pretty unstable.  If admin has set `..R2..` keys in
  # the group [Settings] [CI/CD] [Variables] - then use deploy token-based alternatives.
  # Effectively use CI_R2_* variant if set; else use CI_REGISTRY_* PAIR
  docker_user = [for s in [var.CI_R2_USER, var.CI_REGISTRY_USER    ] : s if s != ""]
  docker_pass = [for s in [var.CI_R2_PASS, var.CI_REGISTRY_PASSWORD] : s if s != ""]
  # Make [""] (array of length 1, val empty string) if all docker password vars are ""
  docker_no_login = [for s in [join("", [var.CI_R2_PASS, var.CI_REGISTRY_PASSWORD])]: s if s == ""]

  # If job is using secrets and CI/CD Variables named like "NOMAD_SECRET_*" then set this
  # string to a KEY=VAL line per CI/CD variable.  If job is not using secrets, set to "".
  kv = join("\n", [for k, v in var.NOMAD_SECRETS : join("", concat([k, "='", v, "'"]))])
}


# VARS.NOMAD--INSERTS-HERE


# NOTE: for main or master branch: NOMAD_VAR_SLUG === CI_PROJECT_PATH_SLUG
job "NOMAD_VAR_SLUG" {
  datacenters = ["dc1"]

  group "NOMAD_VAR_SLUG" {
      count = var.COUNT

      update {
        # https://learn.hashicorp.com/tutorials/nomad/job-rolling-update
        max_parallel  = 1
        # https://learn.hashicorp.com/tutorials/nomad/job-blue-green-and-canary-deployments
        canary = var.COUNT
        auto_promote  = true
        min_healthy_time  = "30s"
        healthy_deadline  = "5m"
        progress_deadline = "10m"
        auto_revert   = true
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
        # second line automatically redirects any http traffic to https
        tags = concat([for HOST in var.HOSTNAMES :
          "urlprefix-${HOST}:443/"], [for HOST in var.HOSTNAMES :
          "urlprefix-${HOST}:80/ redirect=308,https://${HOST}$path"])

        canary_tags = concat([for HOST in var.HOSTNAMES :
          "urlprefix-canary-${HOST}:443/"], [for HOST in var.HOSTNAMES :
          "urlprefix-canary-${HOST}:80/ redirect=308,https://canary-${HOST}/"])

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

        connect { native = true }
      }

      dynamic "service" {
        for_each = local.ports_extra_http
        content {
          # service.key == portnumber
          # service.value == portname
          name = "${var.SLUG}-${service.value}"
          tags = ["urlprefix-${var.HOSTNAMES[0]}:${service.key}/"]
          port = "${service.value}"
          check {
            name     = "alive"
            type     = "${var.CHECK_PROTOCOL}"
            path     = "${var.CHECK_PATH}"
            port     = "http"
            interval = "10s"
            timeout  = "2s"
          }
        }
      }
      dynamic "service" {
        for_each = local.ports_extra_tcp
        content {
          # service.key == portnumber
          # service.value == portname
          name = "${var.SLUG}-${service.value}"
          tags = ["urlprefix-:${service.key} proto=tcp"]
          port = "${service.value}"
          check {
            name     = "alive"
            type     = "${var.CHECK_PROTOCOL}"
            path     = "${var.CHECK_PATH}"
            port     = "http"
            interval = "10s"
            timeout  = "2s"
          }
        }
      }


      dynamic "task" {
        for_each = local.job_names
        labels = ["${task.value}"]
        content {
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
              ports = [for portnumber, portname in var.PORTS : portname]
              mounts = var.BIND_MOUNTS
              # The MEMORY var now becomes a **soft limit**
              # We will 10x that for a **hard limit**
              memory_hard_limit = "${var.MEMORY * 10}"

              force_pull = true
            }
          }
          dynamic "config" {
            for_each = slice(local.docker_pass, 0, min(1, length(local.docker_pass)))
            content {
              image = "${local.docker_image}"
              image_pull_timeout = "20m"
              network_mode = "${var.NETWORK_MODE}"
              ports = [for portnumber, portname in var.PORTS : portname]
              mounts = var.BIND_MOUNTS
              # The MEMORY var now becomes a **soft limit**
              # We will 10x that for a **hard limit**
              memory_hard_limit = "${var.MEMORY * 10}"

              auth {
                server_address = "${var.CI_REGISTRY}"
                username = element(local.docker_user, 0)
                password = "${config.value}"
              }

              force_pull = var.FORCE_PULL
            }
          }

          resources {
            memory = "${var.MEMORY}"
            cpu    = "${var.CPU}"
          }


          dynamic "volume_mount" {
            for_each = setintersection([var.HOME], ["ro"])
            content {
              volume      = "home-${volume_mount.key}"
              destination = "/home"
              read_only   = true
            }
          }
          dynamic "volume_mount" {
            for_each = setintersection([var.HOME], ["rw"])
            content {
              volume      = "home-${volume_mount.key}"
              destination = "/home"
              read_only   = false
            }
          }

          dynamic "volume_mount" {
            # volume_mount.key == slot, eg: "/pv3"
            # volume_mount.value == dest dir, eg: "/pv" or "/bitnami/wordpress"
            for_each = local.pvs
            content {
              volume      = "${volume_mount.key}"
              destination = "${volume_mount.value}"
              read_only   = false
            }
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
        }
      } # end dynamic "task"

      dynamic "task" {
        # when a job has CI/CD secrets - eg: CI/CD Variables named like "NOMAD_SECRET_..."
        # then here is where we dynamically insert them into consul (as a single JSON k/v string)
        for_each = slice(keys(var.NOMAD_SECRETS), 0, min(1, length(keys(var.NOMAD_SECRETS))))
        labels = ["kv"]
        content {
          driver = "exec"
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

      dynamic "volume" {
        for_each = setintersection([var.HOME], ["ro"])
        labels = [ "home-${volume.key}" ]
        content {
          type      = "host"
          source    = "home-${volume.key}"
          read_only = true
        }
      }
      dynamic "volume" {
        for_each = setintersection([var.HOME], ["rw"])
        labels = [ "home-${volume.key}" ]
        content {
          type      = "host"
          source    = "home-${volume.key}"
          read_only = false
        }
      }

      dynamic "volume" {
        # volume.key == slot, eg: "/pv3"
        # volume.value == dest dir, eg: "/pv" or "/bitnami/wordpress"
        labels = [ volume.key ]
        for_each = local.pvs
        content {
          type      = "host"
          read_only = false
          source    = "${volume.key}"
        }
      }
    }


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

  migrate {
    max_parallel = 3
    health_check = "checks"
    min_healthy_time = "15s"
    healthy_deadline = "5m"
  }


  # This allows us to more easily partition nodes (if desired) to run normal jobs like this (or not)
  dynamic "constraint" {
    for_each = slice(local.kinds, 0, min(1, length(local.kinds)))
    content {
      attribute = "${meta.kind}"
      operator = "set_contains"
      value = "${constraint.value}"
    }
  }
  dynamic "constraint" {
    for_each = slice(local.kinds_not, 0, min(1, length(local.kinds_not)))
    content {
      attribute = "${meta.kind}"
      operator = "regexp"
      value = "^(lb,*|worker,*)*$"
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
