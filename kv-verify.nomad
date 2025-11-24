task "kv-verify" {
  # Before the main job runs, ensure the consul kv store is updated on all consul nodes
  # (ie: has reached consistency) so that when we try to read it in project.nomad:
  #   data = "{{ key \"${var.SLUG}\" }}"
  # the key/vals will get read & used properly.
  lifecycle {
    hook    = "prestart"
    sidecar = false
  }
  driver = "raw_exec"
  config {
    command = "bash"
    args    = ["-c", "/usr/bin/consul kv get -stale=false ${var.SLUG} >/dev/null && echo SUCCESS"]
  }
  restart {
    attempts = 15  # 30s total
    delay    = "2s"
    mode     = "delay"
  }
}
