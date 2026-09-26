# -*- coding: utf-8 -*-
"""Where things live, resolved from this file's own location.

The suites used to sit beside app.py and the workflow JSONs and found
them as siblings; two also carried an absolute, machine-specific path
that worked on exactly one computer. Moving into the repo broke both.
One resolver here means a future move touches this file, not eight.
"""
import os

HERE      = os.path.dirname(os.path.abspath(__file__))   # portal/tests
PORTAL    = os.path.dirname(HERE)                        # portal
REPO      = os.path.dirname(PORTAL)                      # repo root
WORKFLOWS = os.path.join(REPO, "n8n", "workflows")
DOCS      = os.path.join(REPO, "docs")

# Directories whose shell scripts follow this project's conventions.
# Deliberately NOT the whole repo: scripts/ and hybrid-app/ predate these
# rules, and sweeping them in would report failures against code this
# suite was never written for.
SCRIPT_DIRS = [os.path.join(REPO, d) for d in ("ops", "platform", "portal", "n8n")]


def wf(name):
    """A workflow JSON by its short name, e.g. wf('provision.json')."""
    return os.path.join(WORKFLOWS, name)


def portal(name):
    return os.path.join(PORTAL, name)
