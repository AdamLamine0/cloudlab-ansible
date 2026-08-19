# hostprobe — the Nomad half of the CloudLab hybrid app.
#
# WHY THIS RUNS ON NOMAD AND NOT ON KUBERNETES:
# it reports the state of the Nomad VM's HOST (uptime, load, memory,
# filesystem, kernel) — facts that a k3s pod on .50 structurally cannot
# observe, because .50 is a different machine and k3s does not manage
# .51 at all. This is real heterogeneous placement, not a workload split
# invented to make the architecture look hybrid.
#
# Driver: "exec", NOT "raw_exec".
#   raw_exec is deliberately disabled on prod .51
#   (nomad_enable_raw_exec: false in host_vars/nomad.yml) and this job
#   does not ask for that to change. "exec" gives chroot + namespace
#   isolation and is enabled by default on Linux.
#   The chroot includes /usr, so /usr/bin/python3 (already present —
#   Ansible requires it) is available with no artifact download.
#
# Deploy (from jumpbox or .51), as the TENANT, with the tenant's
# namespace token from Vault — this is the §18 work being used for real:
#   export NOMAD_ADDR=http://192.168.1.51:4646
#   export NOMAD_TOKEN=<user1 namespace token>
#   nomad job run -var="tenant=user1" -var="port=28001" probe.nomad.hcl
#
# Port allocation is STATIC and assigned per tenant on purpose: the k8s
# portal finds this service by an A record from Consul DNS
# (user1-hostprobe.service.consul), which carries an address but no
# port. Static ports keep the discovery path identical to the one
# already proven in Part 10 instead of adding an SRV lookup.
#   user1 -> 28001
#   user2 -> 28002

variable "tenant" {
  type        = string
  description = "Tenant name. Must match the Nomad namespace and the Consul user<N>-* service prefix."
}

variable "port" {
  type        = number
  description = "Static host port for the probe HTTP listener. user1=28001, user2=28002."
}

job "hostprobe" {
  namespace   = var.tenant
  datacenters = ["cloudlab"]
  type        = "service"

  group "probe" {
    count = 1

    network {
      port "http" {
        static = var.port
      }
    }

    # Service name is "<tenant>-hostprobe" so it falls inside the
    # user1-* / user2-* prefix the Consul tenant policies are written
    # against (Part 12, piece 1/4). Nomad itself registers this with its
    # own broad integration token — the isolation boundary is enforced
    # on the tenant tokens, which is exactly what the portal's
    # /api/isolation check exercises.
    service {
      name     = "${var.tenant}-hostprobe"
      port     = "http"
      tags     = ["hybrid-app", "tenant-${var.tenant}", "orchestrator-nomad"]
      provider = "consul"

      check {
        name     = "http-healthz"
        type     = "http"
        path     = "/healthz"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "probe" {
      driver = "exec"

      config {
        command = "/usr/bin/python3"
        args    = ["local/probe.py"]
      }

      env {
        PROBE_TENANT = var.tenant
      }

      resources {
        cpu    = 100
        memory = 96
      }

      # Delimiters are changed from {{ }} so Python's own braces are
      # never parsed as consul-template directives.
      template {
        destination     = "local/probe.py"
        left_delimiter  = "[["
        right_delimiter = "]]"
        perms           = "0644"
        data            = <<-EOH
          #!/usr/bin/env python3
          """hostprobe — reports Nomad host facts over HTTP as JSON.

          Stdlib only. Every reader is guarded: a missing or unreadable
          source degrades to null for that field instead of failing the
          whole response, because the exec driver's chroot is not
          guaranteed to expose every path on every Nomad build.
          """
          import json
          import os
          import platform
          import socket
          import time
          from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

          PORT = int(os.environ.get("NOMAD_PORT_http", "28001"))
          BIND = os.environ.get("NOMAD_IP_http", "0.0.0.0")
          TENANT = os.environ.get("PROBE_TENANT", "unknown")
          STARTED = time.time()


          def read_uptime():
              try:
                  with open("/proc/uptime") as fh:
                      return round(float(fh.read().split()[0]), 1)
              except Exception:
                  return None


          def read_load():
              try:
                  return [round(v, 2) for v in os.getloadavg()]
              except Exception:
                  return None


          def read_memory():
              try:
                  fields = {}
                  with open("/proc/meminfo") as fh:
                      for line in fh:
                          key, _, rest = line.partition(":")
                          fields[key] = int(rest.split()[0])
                  total = fields.get("MemTotal", 0)
                  available = fields.get("MemAvailable", 0)
                  used_pct = round((total - available) * 100.0 / total, 1) if total else None
                  return {
                      "total_mb": round(total / 1024),
                      "available_mb": round(available / 1024),
                      "used_percent": used_pct,
                  }
              except Exception:
                  return None


          def read_disk(path="/"):
              try:
                  st = os.statvfs(path)
                  total = st.f_blocks * st.f_frsize
                  free = st.f_bavail * st.f_frsize
                  return {
                      "path": path,
                      "total_gb": round(total / 1024 ** 3, 1),
                      "free_gb": round(free / 1024 ** 3, 1),
                      "used_percent": round((total - free) * 100.0 / total, 1) if total else None,
                  }
              except Exception:
                  return None


          def payload():
              return {
                  "tenant": TENANT,
                  "orchestrator": "nomad",
                  "reported_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  "probe_uptime_seconds": round(time.time() - STARTED, 1),
                  "host": {
                      "hostname": socket.gethostname(),
                      "kernel": platform.release(),
                      "uptime_seconds": read_uptime(),
                      "load_average": read_load(),
                      "memory": read_memory(),
                      "disk": read_disk(),
                  },
                  "nomad": {
                      "namespace": os.environ.get("NOMAD_NAMESPACE"),
                      "job": os.environ.get("NOMAD_JOB_NAME"),
                      "alloc_id": os.environ.get("NOMAD_ALLOC_ID"),
                      "node": os.environ.get("NOMAD_CLIENT_IP"),
                      "datacenter": os.environ.get("NOMAD_DC"),
                  },
              }


          class Handler(BaseHTTPRequestHandler):
              protocol_version = "HTTP/1.1"

              def _send(self, code, body, content_type="application/json"):
                  raw = body.encode("utf-8")
                  self.send_response(code)
                  self.send_header("Content-Type", content_type)
                  self.send_header("Content-Length", str(len(raw)))
                  self.end_headers()
                  self.wfile.write(raw)

              def do_GET(self):
                  path = self.path.split("?")[0].rstrip("/") or "/"
                  if path == "/healthz":
                      self._send(200, "ok", "text/plain")
                  elif path in ("/", "/api/probe"):
                      self._send(200, json.dumps(payload(), indent=2))
                  else:
                      self._send(404, json.dumps({"error": "no such path", "path": path}))

              def log_message(self, fmt, *args):
                  print("%s %s" % (self.address_string(), fmt % args), flush=True)


          if __name__ == "__main__":
              print("hostprobe tenant=%s listening on %s:%d" % (TENANT, BIND, PORT), flush=True)
              ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
        EOH
      }
    }
  }
}
