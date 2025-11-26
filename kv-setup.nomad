variable "NOMAD_SECRETS" {
  # This can be passed in via a GitHub Action, or
  # is automatically populated with NOMAD_SECRET_ env vars from GitLab via deploy.sh in this dir.
  type = map(string)
  default = {}
}
locals {
  # If job is using secrets and CI/CD Variables named like "NOMAD_SECRET_*" then set this
  # string to a KEY=VAL line per CI/CD variable.  If job is not using secrets, set to "".
  kv = join("\n", [for k, v in var.NOMAD_SECRETS : join("", concat([k, "='", v, "'"]))])
}

job "kv-NOMAD_VAR_SLUG-kv" {
  datacenters = ["dc1"]
  type = "batch"
  group "kv" {

    task "kv-put" {
      driver = "raw_exec"
      config {
        command = "/usr/bin/consul"
        args = [ "kv", "put", "NOMAD_VAR_SLUG", local.kv ]
      }
      restart {
        # basic restart policy in case consul is temporarily unavailable
        attempts = 3
        delay    = "5s"
        mode     = "delay"
      }
    }

    task "kv-verify" {
      # Verify key exists with consistent read across all consul servers. Runs after kv-put succeeds.
      lifecycle {
        hook    = "poststart"
        sidecar = false
      }
      driver = "raw_exec"
      config {
        command = "bash"
        args = ["-c", "/usr/bin/consul kv get -stale=false NOMAD_VAR_SLUG >/dev/null && echo SUCCESS"]
      }
      restart {
        attempts = 15
        delay    = "2s"
        mode     = "delay"
      }
    }
  }
}
