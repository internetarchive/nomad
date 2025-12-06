# Minimal basic project, using env variables, with defaults if not set.
# Run like:   nomad run hello-world.hcl

# Variables used below and their defaults if not set externally
variables {
  # These all pass through from the github action, or gitlab's CI/CD variables.
  # Some defaults filled in w/ example repo "hello-js" in group "internetarchive"
  CI_REGISTRY_IMAGE = "ghcr.io/internetarchive/hello-js:main" # registry image location
  CI_COMMIT_REF_SLUG = "main"                                 # branch name, slugged
  CI_PROJECT_PATH_SLUG = "internetarchive-hello-js"           # repo and group it is part of, slugged
  # NOTE: see `project.nomad` in this dir if your registry image is private and needs to login

  # Switch this, locally edit your /etc/hosts, or otherwise.  as is, webapp will appear at:
  #   https://internetarchive-hello-js-main.x.example.com/
  BASE_DOMAIN = "x.example.com"
}

job "hello-world" {
  datacenters = ["dc1"]
  group "group" {
    network {
      port "http" {
        to = 5000
      }
    }
    service {
      tags = ["https://${var.CI_PROJECT_PATH_SLUG}-${var.CI_COMMIT_REF_SLUG}.${var.BASE_DOMAIN}"]
      port = "http"
      check {
        type     = "http"
        port     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }
    }
    task "web" {
      driver = "docker"

      config {
        image = "${var.CI_REGISTRY_IMAGE}"
        ports = [ "http" ]
      }
    }
  }
}
