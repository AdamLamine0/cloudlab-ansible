# -*- coding: utf-8 -*-
"""Delete-project: the ownership refusal, and honest reporting.

The point of this suite is NOT that a route exists. It is that:

  * the portal never decides ownership itself,
  * a refusal from n8n is reported as a refusal and never as a deletion,
  * a deletion is only claimed when n8n confirmed it,
  * the dangerous control does not exist in the page until confirmed.

Every n8n call is intercepted, so nothing here touches the cluster.
"""
import io
import json
import re
import os
import sys
import urllib.request
import _paths

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.update(PORTAL_ROLE="all", ASSET_DIR="assets", SESSION_KEY="k" * 32,
                  N8N_WEBHOOK_TOKEN="testtoken")
import app  # noqa: E402

fails = []


def t(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}" + (f"   <- {detail}" if not ok else ""))
    if not ok:
        fails.append(name)


# --------------------------------------------------------------- the stub
sent = []


class FakeResp:
    def __init__(self, payload):
        self._b = json.dumps(payload).encode()

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def stub(reply):
    def _open(req, timeout=None):
        sent.append({"url": req.full_url,
                     "body": json.loads(req.data.decode()),
                     "token": req.headers.get("X-portal-token")})
        return FakeResp(reply)
    return _open


real_open = urllib.request.urlopen

U = "amine.beji"
OTHER = "someone.else"
PROJ = [{"project": "boutique", "url": "http://tenant-boutique.apps.cloudlab.internal/",
         "created": "2026-09-08T10:00:00Z"}]

print("== the portal forwards identity, it does not assert ownership ==")
sent.clear()
urllib.request.urlopen = stub({"owned": True, "deleted": True, "message": "ok"})
status, msg = app.delete_project(U, "boutique")
urllib.request.urlopen = real_open
t("calls the delete webhook", sent and sent[0]["url"].endswith("/delete-project"))
t("sends the SESSION username, not a form field",
  sent[0]["body"].get("username") == U, sent[0]["body"])
t("sends the project name in the body (not the URL)",
  sent[0]["body"].get("project") == "boutique" and "boutique" not in sent[0]["url"])
t("sends the shared token", sent[0]["token"] == "testtoken")
t("body carries nothing that could assert ownership",
  set(sent[0]["body"]) == {"username", "project"}, sorted(sent[0]["body"]))

print()
print("== a non-owner is REFUSED, and nothing is claimed ==")
urllib.request.urlopen = stub({"owned": False, "deleted": False})
status, msg = app.delete_project(OTHER, "boutique")
urllib.request.urlopen = real_open
t("status is denied", status == "denied", status)
t("does NOT claim a deletion", "supprim" in msg.lower() and "rien n'a" in msg.lower(), msg)
t("does not confirm the project exists",
  "boutique" not in msg and "introuvable" in msg.lower(), msg)

print()
print("== n8n says it could not confirm -> the portal must not claim it ==")
for reply, label in [({"owned": True, "deleted": False,
                       "message": "La suppression a ete refusee par le cluster."},
                      "refused by the cluster"),
                     ({"owned": True}, "no deleted field at all"),
                     ({}, "empty body"),
                     ({"deleted": "true"}, "deleted is a STRING, not true")]:
    urllib.request.urlopen = stub(reply)
    status, msg = app.delete_project(U, "boutique")
    urllib.request.urlopen = real_open
    t(f"{label:34} -> not ok", status != "ok", f"{status}: {msg}")

print()
print("== only an explicit confirmation counts as deleted ==")
urllib.request.urlopen = stub({"owned": True, "deleted": True,
                               "message": "Le projet boutique ne repond plus."})
status, msg = app.delete_project(U, "boutique")
urllib.request.urlopen = real_open
t("status is ok", status == "ok", status)

print()
print("== the control is two-step, and the form does not exist until step two ==")
plain = app.render_welcome(U, projects=PROJ)
conf = app.render_welcome(U, projects=PROJ, confirm="boutique")
t("no POST form before confirming", 'action="/delete-project"' not in plain)
t("trigger is a plain link", 'href="/welcome?confirm=boutique#mes-sites"' in plain)
t("form appears only in the confirm state", 'action="/delete-project"' in conf)
t("the confirmed project is named in the body",
  'name="project" value="boutique"' in conf)
t("confirming one card does not arm the others",
  conf.count('action="/delete-project"') == 1)

print()
print("== the confirm parameter confers no authority ==")
# A project this user does not have simply matches no card. It must never
# produce a form, because the form is what can POST.
ghost = app.render_welcome(U, projects=PROJ, confirm="someone-elses-project")
t("unknown project arms nothing", 'action="/delete-project"' not in ghost)
t("unknown project is not echoed into the page", "someone-elses-project" not in ghost)

print()
print("== a failure is SHOWN, and the real list is re-read ==")
page = app.render_welcome(U, projects=PROJ,
                          message="Ce projet est introuvable dans votre espace.",
                          kind="err")
t("the message renders", "introuvable" in page)
t("rendered as an error state", "msg err" in page)
t("the project is still listed after a failed delete", "boutique" in page)

print()
print("== the workflow itself ==")
wf = json.load(io.open(_paths.wf("delete-project.json"),
    encoding="utf-8"))
urls = [(n.get("parameters", {}).get("method", "GET"),
         str(n.get("parameters", {}).get("url", ""))) for n in wf["nodes"]]
dels = [u for m, u in urls if m == "DELETE"]
# SCOPE CHANGED 2026-09-21, at the operator's explicit request: this is a
# full teardown, not stop-routing. The old assertions said the opposite
# and are replaced rather than deleted, because what they were protecting
# still needs protecting - just differently.
t("deletes the Kubernetes namespace", any("/api/v1/namespaces/" in u for u in dels))
t("purges the Nomad job too, or it outlives the project",
  any("/v1/job/" in u and "purge=true" in u for u in dels))
t("does not delete quota or rolebindings DIRECTLY",
  not any("resourcequotas" in u or "rolebindings" in u for u in dels))

# ORDERING. The Kubernetes namespace is the ownership record and the thing
# the project list reads, so it must go LAST: a Nomad failure then leaves a
# state that is still visible, still owned and still retryable. The reverse
# would strand a running Nomad job behind an ownership record that is gone.
order = {n["name"]: i for i, n in enumerate(wf["nodes"])}
conn = wf["connections"]


def reaches(src, dst):
    seen, q = {src}, [src]
    while q:
        c = q.pop()
        for g in conn.get(c, {}).get("main", []):
            for tgt in g:
                if tgt["node"] == dst:
                    return True
                if tgt["node"] not in seen:
                    seen.add(tgt["node"]); q.append(tgt["node"])
    return False


t("the Nomad job is purged BEFORE the namespace is deleted",
  reaches("Purge the Nomad job", "Delete the namespace"))
t("the Nomad namespace is dropped BEFORE the k8s one",
  reaches("Drop the Nomad namespace", "Delete the namespace"))

# The management token cannot be scoped for namespace deletion (Problem
# #138), so it lives in ONE isolated workflow reached by ID. If it ever
# appears here, that isolation is gone.
t("the Nomad MANAGEMENT token is not in this workflow",
  "nomadMgmtCred01" not in json.dumps(wf))
t("the Nomad namespace is dropped via the isolated workflow",
  any(n["type"].endswith("executeWorkflow") for n in wf["nodes"]))
names = [n["name"] for n in wf["nodes"]]
t("has an ownership gate before any delete", "Ours to delete?" in names)
t("has a refusal path", "Refuse without deleting" in names)
order = {n: i for i, n in enumerate(names)}
t("the ownership gate precedes every delete node",
  all(order["Ours to delete?"] < order[n] for n in names if n.startswith("Delete ")))
src = json.dumps(wf)
t("the ownership check fails closed",
  "unlabelled is NOT ours" in src or "FAILS CLOSED" in src)

print()
print("== the confirmation tells the truth about what it does ==")
# A destructive, irreversible action must say so before it is taken. The
# old copy said the address would stop responding, which was accurate for
# stop-routing and is now a serious understatement.
conf_page = app.render_welcome(U, projects=PROJ, confirm="boutique")
t("says the deletion is permanent", "irr&eacute;versible" in conf_page)
t("says the space and its contents are erased", "effac&eacute;s" in conf_page)
t("does not still promise the space survives", "reste en place" not in conf_page)

print()
print("== a project that is merely not answering is NOT a deleted one ==")
# A stop-routing delete leaves the namespace, so the project cannot
# disappear from a list built from namespaces. n8n now reports whether
# each project still has an Ingress, and the portal renders that.
MIX = [
    {"project": "vivant", "url": "http://tenant-vivant.apps.cloudlab.internal/",
     "created": "2026-09-08T10:00:00Z", "routing": True},
    {"project": "arrete", "url": None,
     "created": "2026-09-10T10:00:00Z", "routing": False},
    {"project": "inconnu", "url": "http://tenant-inconnu.apps.cloudlab.internal/",
     "created": "2026-09-11T10:00:00Z", "routing": None},
]
page = app.render_welcome(U, projects=MIX)
t("a stopped project is still listed", "arrete" in page)
t("it is marked stopped", "Arr&ecirc;t&eacute;" in page)
t("its dead address is NOT linked",
  "tenant-arrete.apps.cloudlab.internal" not in page)
t("it is still deletable", 'confirm=arrete' in page)
t("a routing project keeps its link",
  "tenant-vivant.apps.cloudlab.internal" in page)
t("routing=None keeps its link (we did not measure it)",
  "tenant-inconnu.apps.cloudlab.internal" in page)
# We can prove an Ingress is ABSENT. We cannot prove the app behind a
# present one answers, so there is no "Live" pill to be wrong about.
t("exactly one status pill, and it is the stopped one",
  len(re.findall(r'class="status status--off"', page)) == 1
  and not re.search(r'class="status"(?! status--off)', page))
t("the count includes stopped projects", "3 projets dans votre espace" in page)

print()
print("== the projects workflow measures routing per project ==")
mp = json.load(io.open(_paths.wf("my-projects.json"), encoding="utf-8"))
mp_src = json.dumps(mp)
names = [n["name"] for n in mp["nodes"]]
t("has an Ingress lookup", "Is it still routing?" in names)
ing = [n for n in mp["nodes"] if n["name"] == "Is it still routing?"][0]
u = ing["parameters"]["url"]
t("it is a scoped GET, not a cluster-wide list",
  "/ingresses/site" in u and "?" not in u.split("/ingresses")[0])
t("the namespace comes from the filtered list, not request input",
  "{{ $json.namespace }}" in u and "body" not in u)
t("it needs no verb beyond get",
  ing["parameters"].get("method", "GET") == "GET")
t("the empty case travels as a real item (Problem #135)", "empty: true" in mp_src)
t("a stopped project is sent with a null url", "routing === false ? null" in mp_src)
t("misaligned results report unknown, not a guess", "aligned" in mp_src)

print()
print("DELETE PATH OK" if not fails else f"{len(fails)} CHECK(S) FAILED")
sys.exit(1 if fails else 0)
