# Hong Scanner single-container contract (Northflank Phase-0, PR-2):
# one always-running process — the read-only API server
# (tools/api/serve.py, contract: tools/api/README.md §1/§5).
#
# Build context contract (tools/container/README.md §2): this Dockerfile
# COPYs relative paths only. A Docker COPY can never reach outside the
# build context (leading/trailing ".." path components are normalized
# away — docs.docker.com). Whoever builds the image stages the needed
# files into a fresh directory first (mktemp) and passes THAT directory
# as the context:
#   Dockerfile · bin/hongscanner · tools/api/serve.py
#   calendars/CALENDAR_INDEX.sha256
# The production image is built the same way by the attestation job
# (PR-5) from the attested CI_BUILD_OUT binary. This file is the shared
# build contract, never a build-from-source recipe.
#
# Binary contract (tools/container/README.md §3): test binaries and the
# production binary are separate artifacts. An image carrying a locally
# compiled (test) binary MUST carry the
# org.hongscanner.image-purpose=ci-test label — a not-for-deployment
# marker asserted by tests/test_container_contract.sh; the production
# image (PR-5) carries no such marker. The dev build left at the
# repository root (./hongscanner) is an accident leftover: never use,
# delete or overwrite it.
#
# Calendar trust boundary (tools/container/README.md §4): the
# git-tracked calendars/CALENDAR_INDEX.sha256 (canonical main source)
# is baked into the image. The actual calendars/*.json are gitignored
# user data and never enter an image or a build context
# (.dockerignore); in operation the Northflank persistent volume
# supplies them and is cross-checked against the baked index (run
# enforced from PR-4).
FROM python:3.13-slim

# serve.py is standard library only (http.server) — no pip installs,
# ever (tools/api/README.md §0).
COPY tools/api/serve.py /opt/hongscanner/serve.py
COPY bin/hongscanner /opt/hongscanner/bin/hongscanner
COPY calendars/CALENDAR_INDEX.sha256 /opt/hongscanner/CALENDAR_INDEX.sha256

# Code lives under /opt/hongscanner, data under /var/lib/hongscanner:
# runs/ and notify/ are persistent-volume mount points (README §5) and
# never carry baked content — the ledger in particular is
# volume-supplied, never baked. The runs root must exist: serve.py
# exits 2 without an existing --runs directory.
RUN groupadd --system hongscanner \
 && useradd --system --gid hongscanner \
      --home-dir /var/lib/hongscanner --shell /usr/sbin/nologin \
      hongscanner \
 && mkdir -p /var/lib/hongscanner/runs /var/lib/hongscanner/notify \
 && chown -R hongscanner:hongscanner /var/lib/hongscanner \
 && chmod 0755 /opt/hongscanner/bin/hongscanner

USER hongscanner
WORKDIR /opt/hongscanner
EXPOSE 8080
STOPSIGNAL SIGTERM

# Phase-0 CMD. PR-4 replaces it with the cloud_supervisor ENTRYPOINT;
# the image layout (paths, user, volumes) is the stable surface.
# --bind 0.0.0.0 is container-only behind the Northflank platform
# ingress: this API has no authentication of its own, access control
# for 0.0.0.0 is delegated to the platform ingress Basic Auth, and
# direct internet exposure of a non-loopback bind is a contract
# violation (tools/api/README.md §1/§5). Local operation keeps the
# default 127.0.0.1.
CMD ["python3", "/opt/hongscanner/serve.py", \
     "--bind", "0.0.0.0", "--port", "8080", \
     "--runs", "/var/lib/hongscanner/runs", \
     "--ledger", "/var/lib/hongscanner/notify/ledger.hcj.jsonl"]
