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

  # used in conjunction with PG and PV_DB variables (below)
  POSTGRESQL_PASSWORD = ""

  # only used for github repos
  GITHUB__IMAGE = ""

  # There are more variables immediately after this - but they are "lists" or "maps" and need
  # special definitions to not have defaults or overrides be treated as strings.
}

# Persistent Volume(s).  To enable, coordinate a free slot with your nomad cluster administrator
# and then set like, for PV slot 3 like:
#   NOMAD_VAR_PV='{ pv3 = "/pv" }'
#   NOMAD_VAR_PV_DB='{ pv9 = "/bitnami/wordpress" }'
variable "PV" {
  type = map(string)
  default = {}
}
variable "PV_DB" {
  type = map(string)
  default = {}
}

variable "PORTS" {
  # Note: to use a secondary port > 5000, right now, you have to make the main/http port be
  # greater than it.  Additionally, these are all public ports, right out to the browser.
  # So for a *nomad cluster* -- anything not 5000 must be unique across all projects deployed there.
  # Examples:
  #   NOMAD_VAR_PORTS='{ 5000 = "http" }'
  #   NOMAD_VAR_PORTS='{ 5000 = "http", 666 = "cool-ness" }'
  #   NOMAD_VAR_PORTS='{ 8888 = "http", 8012 = "backend", 7777 = "extra-service" }'
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
  #   NOMAD_VAR_BIND_MOUNTS='["/opt/something", "/tmp/beer"]'
  # As of now you have to pass in 2 and only 2... 🤦‍♀️
  type = list(string)
  default = ["/usr/games", "/usr/local/games"]
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



locals {
  # Ignore all this.  really :)
  job_names = [ "${var.SLUG}" ]

  # Too convoluted -- but remove map key/val for the port 5000
  # get numeric sort to work right by 0-padding to 5 digits so that keys() returns like: [x, y, 5000]
  ports_sorted = "${zipmap(formatlist("%05d", keys(var.PORTS)), values(var.PORTS))}"
  ports_not_5000 = "${zipmap(
    formatlist("%d", slice(  keys(local.ports_sorted), 0, length(keys(var.PORTS)) - 1)),
    slice(values(local.ports_sorted), 0, length(keys(var.PORTS)) - 1))}"

  # NOTE: 3rd arg is hcl2 quirk needed in case first two args are empty maps as well
  pvs = merge(var.PV, var.PV_DB, {})

  # Make it so that later we can constrain deploy to server kind of _either_ pv or worker
  # If either PV or PV_DB is in use, constrain deployment to the single "pv" node in the cluster
  kinds = concat([for k in keys(local.pvs): "pv"], ["worker"])

  # If job is using secrets and CI/CD Variables named like "NOMAD_SECRET_*" then set this
  # string to a KEY=VAL line per CI/CD variable.  If job is not using secrets, set to "".
  kv = join("\n", [for k, v in var.NOMAD_SECRETS : join("", concat([k, "='", v, "'"]))])
}


# VARS.NOMAD--INSERTS-HERE


# NOTE: for main or master branch: NOMAD_VAR_SLUG === CI_PROJECT_PATH_SLUG
job "NOMAD_VAR_SLUG" {
  datacenters = ["dc1"]

  dynamic "group" {
    for_each = local.job_names
    labels = ["${group.value}"]
    content {
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
          for_each = merge(var.PORTS, var.PG, {})
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
      }

      dynamic "service" {
        for_each = local.ports_not_5000
        content {
          # service.key == portnumber
          # service.value == portname
          name = "${var.SLUG}-${service.value}"
          tags = ["urlprefix-${var.HOSTNAMES[0]}:${service.key}/"]
          canary_tags = ["urlprefix-canary-${var.HOSTNAMES[0]}:${service.key}/"]
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

          config {
            # Effectively use GITHUB__IMAGE if set, otherwise use GitLab vars interpolated string
            image = element([for s in [var.GITHUB__IMAGE, "${var.CI_REGISTRY_IMAGE}/${var.CI_COMMIT_REF_SLUG}:${var.CI_COMMIT_SHA}"] : s if s != ""], 0)
            image_pull_timeout = "20m"
            network_mode = "${var.NETWORK_MODE}"

            auth {
              # GitLab docker login user/pass are pretty unstable.  If admin has set `..R2..` keys in
              # the group [Settings] [CI/CD] [Variables] - then use deploy token-based alternatives.
              server_address = "${var.CI_REGISTRY}"

              # Effectively use CI_R2_* variant if set; else use CI_REGISTRY_* PAIR
              username = element([for s in [var.CI_R2_USER, var.CI_REGISTRY_USER] : s if s != ""], 0)
              password = element([for s in [var.CI_R2_PASS, var.CI_REGISTRY_PASSWORD] : s if s != ""], 0)
            }

            ports = [for portnumber, portname in var.PORTS : portname]

            # The MEMORY var now becomes a **soft limit**
            # We will 10x that for a **hard limit**
            memory_hard_limit = "${var.MEMORY * 10}"

            mounts = [{
              type = "bind"
              readonly = true
              source = "${var.BIND_MOUNTS[0]}"
              target = "${var.BIND_MOUNTS[0]}"
            }, {
              type = "bind"
              readonly = true
              source = "${var.BIND_MOUNTS[1]}"
              target = "${var.BIND_MOUNTS[1]}"
            }]
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
            command = "/usr/bin/consul"
            args = [
              "kv", "put", var.SLUG, local.kv
            ]
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



      # Optional add-on postgres DB.  @see README.md for more details to enable.
      dynamic "task" {
        # task.key == DB port number
        # task.value == DB name like 'db'
        for_each = var.PG
        labels = ["${var.SLUG}-db"]
        content {
          driver = "docker"

          config {
            image = "docker.io/bitnami/postgresql:11.7.0-debian-10-r9"
          }

          # https://www.nomadproject.io/docs/job-specification/template#environment-variables
          template {
            data = <<EOH
POSTGRESQL_PASSWORD="${var.POSTGRESQL_PASSWORD}"
EOH
            destination = "secrets/file.env"
            env         = true
          }

          service {
            name = "${var.SLUG}-db"
            port = "${task.value}"

            check {
              expose   = true
              type     = "tcp"
              interval = "2s"
              timeout  = "2s"
            }

            check {
              # This posts container's bridge IP address (starting with "172.") into
              # an expected file that other docker container can reach this
              # DB docker container with.
              type     = "script"
              name     = "setup"
              command  = "/bin/sh"
              args     = ["-c", "hostname -i |tee /alloc/data/${var.CI_PROJECT_PATH_SLUG}-db.ip"]
              interval = "1h"
              timeout  = "10s"
            }

            check {
              type     = "script"
              name     = "db-ready"
              command  = "/opt/bitnami/postgresql/bin/pg_isready"
              args     = ["-Upostgres", "-h", "127.0.0.1", "-p", "${task.key}"]
              interval = "10s"
              timeout  = "10s"
            }
          } # end service

          volume_mount {
            volume      = "${element(keys(var.PV_DB), 0)}"
            destination = "${element(values(var.PV_DB), 0)}"
            read_only   = false
          }
        } # end content
      } # end dynamic "task"
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

  migrate {
    max_parallel = 3
    health_check = "checks"
    min_healthy_time = "15s"
    healthy_deadline = "5m"
  }


  # This allows us to more easily partition nodes (if desired) to run normal jobs like this (or not)
  dynamic "constraint" {
    for_each = slice(local.kinds, 0, 1)
    content {
      attribute = "${meta.kind}"
      set_contains = "${constraint.value}"
    }
  }

  # JOB.NOMAD--INSERTS-HERE
} # end job
