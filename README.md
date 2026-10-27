# homelab-as-code

My homelab's monitoring stack, built entirely from code. One command turns a plain
Ubuntu machine into a host running Prometheus, Grafana and node-exporter, configured and
wired up, with the result checked rather than assumed.

The claim this repository makes about itself is checked on every run: **the second apply
changes nothing.**

## Problem

A homelab grows by hand. A container started once at two in the morning, a config file
edited in place, a port opened for a test and never closed. Six months later nobody can
say what is running or why, and rebuilding it after a disk dies means remembering all of
it.

Writing it down in a README does not help, because a README cannot be executed and goes
stale the first time something changes. What is needed is a description the machine can
be rebuilt from, and a way to tell whether the machine still matches it.

## Solution

Ansible for the host, Docker Compose for the services, and a verification playbook that
asks the running stack the questions a person would ask after a deployment.

Three properties the design is actually about:

**Idempotence, proven rather than claimed.** `make idempotence` applies the playbook
twice and fails unless the second run reports `changed=0`. A task that describes an
action instead of a state fails that check immediately. It runs locally and in CI.

**Verification separate from deployment.** Deploying is not the same as working.
`playbooks/verify.yml` asks Prometheus which targets it is scraping, whether the alert
rules were loaded, whether Grafana came up with its provisioned data source, and whether
node-exporter is really measuring the host. Each answer is an assertion that can fail.

**Nothing pinned to this machine.** The inventory has one host because a homelab is one
machine until it is not. Every threshold, port, path and image tag is a variable in
`inventory/group_vars/homelab.yml`; the roles read them and no template hard-codes one.
Pointing this at a real box over SSH is a new entry in the inventory, not a change to a
role.

## What it builds

| Service | Image | Reachable at |
|---|---|---|
| Prometheus | `prom/prometheus:v3.7.3` | `127.0.0.1:9090` |
| Grafana | `grafana/grafana:12.2.1` | `127.0.0.1:3000` |
| node-exporter | `prom/node-exporter:v1.9.1` | `127.0.0.1:9100` |

Plus, on the host: the Docker daemon configured with log rotation, the stack's files
under `/opt/homelab`, and Prometheus loaded with three alert rules for the host itself.

Image tags are pinned. `latest` would mean the stack is a different stack every time it
is pulled, which is the opposite of what this repository is for.

Published ports bind to `127.0.0.1`. A homelab service reachable from the whole network
is a decision, and a decision should take an edit rather than a default.

## Setup

Needs a Debian or Ubuntu host and a control node with Python 3.11 or newer. Both can be
the same machine.

```bash
git clone https://github.com/ckuzu3/homelab-as-code.git
cd homelab-as-code

python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt   # ansible-core, ansible-lint and yamllint, pinned
make deps                         # the pinned collections

make lint
make apply
make verify
```

`make all` runs lint, apply, verify and the idempotence check in order. `make help` lists
the targets. `make destroy` takes the stack down and removes its volumes.

Pointing it at a real machine means uncommenting the SSH host in
`inventory/hosts.yml` and nothing else.

### A note on the control node tooling

`ansible-lint` brings its own copy of `ansible-core`. If the linter and the playbook run
from different environments, the linter judges code it is not the version of, and its
verdict is worth less than it looks. `requirements.txt` pins both so they come from one
virtual environment.

### Secrets

`grafana_admin_password` has a local default in `inventory/group_vars/homelab.yml`,
which is acceptable for a service bound to localhost and nowhere else. For anything
reachable from a network, that variable belongs in an encrypted file:

```bash
ansible-vault create inventory/group_vars/homelab/vault.yml
make apply EXTRA_VARS=--ask-vault-pass
```

## Proof

From a clean machine, with `/opt/homelab` and the Docker configuration removed first:

```text
=== FIRST RUN on a clean machine ===
RUNNING HANDLER [docker : Restart docker] **************************************
RUNNING HANDLER [monitoring : Recreate the monitoring stack] *******************
homelab-local              : ok=14   changed=10   unreachable=0    failed=0

=== SECOND RUN ===
homelab-local              : ok=12   changed=0    unreachable=0    failed=0

=== VERIFY ===
homelab-local              : ok=10   changed=0    unreachable=0    failed=0
```

Ten changes to build it, none to confirm it. That is the whole point, and it is why
`make idempotence` greps for exactly that line and exits non-zero when it is missing.

What the verification run actually asserted:

```text
"2 targets up: ['node', 'prometheus']"
"Prometheus loaded the homelab rule group with 3 rules."
"Grafana has the provisioned Prometheus data source."
"node-exporter reports host filesystem metrics."
```

The second line matters more than it looks. Writing a rules file is easy; having
Prometheus parse and load it is the part that silently fails, so the playbook asks
Prometheus itself rather than checking that the file exists.

## Layout

```text
ansible.cfg              inventory, roles and collections paths
inventory/
  hosts.yml              one host, and a commented example of a second over SSH
  group_vars/homelab.yml every port, path, tag and threshold
playbooks/
  site.yml               base -> docker -> monitoring
  verify.yml             does the running stack actually work
roles/
  base/                  packages the later roles assume, and /opt/homelab
  docker/                engine, daemon configuration with log rotation, service
  monitoring/            templates the stack, then brings it up with compose
Makefile                 deps, lint, check, apply, verify, idempotence, destroy
```

Roles depend on each other only through the order in `site.yml`. Nothing in `monitoring`
knows how Docker was installed.

## What I learned

- **The environment pushes back, and only running it tells you how.** node-exporter's own
  documentation mounts the host root with `rslave`, which needs that root to be a shared
  or slave mount. Inside WSL2 it is private, and Docker refuses the container outright —
  after the other two services had already started. The mount options are a variable now,
  with a default that works everywhere and a comment saying what to set on a real host.
  Nothing short of applying the playbook would have found that.
- **A linter that argues with another linter teaches you to ignore warnings.**
  `ansible-lint` printed a warning on every single run because my `yamllint` configuration
  contradicted what it expects. Three rounds of aligning the two was worth it: both are
  silent now, so the next warning will mean something.
- **A linter is only as good as the version it judges.** `ansible-lint` installs its own
  `ansible-core`. Mine was two major versions ahead of the one that would have run the
  playbooks, which means it was linting code it was not the version of. `requirements.txt`
  pins both.
- **`cache_valid_time` is not a micro-optimisation.** Without it, `apt` refreshes the
  package index on every run and reports changed, and a playbook that is never green is a
  playbook nobody reads — which defeats the idempotence check entirely.
- **Deciding what reports `changed` is the whole design.** `docker compose up` through the
  `command` module would report changed on every run; `community.docker.docker_compose_v2`
  reports what actually happened. And a rewritten `prometheus.yml` does not restart
  anything by itself, because Compose compares its own configuration and not the contents
  of a mounted file — hence the handler. Both choices exist to make the idempotence check
  meaningful rather than decorative.

## Possible extensions

- A reverse proxy with TLS in front of Grafana, which is what would make binding to
  anything other than localhost reasonable.
- Backup of the Prometheus and Grafana volumes, with a restore that is actually tested.
  A backup nobody has restored is a hope.
- More hosts. The inventory and the roles are already written for it; what is missing is
  a second machine.
- Molecule, to test the roles in a container per role rather than only end to end.
- A Grafana dashboard. Provisioned the same way the data source is, once there is one
  worth keeping.

## Known limits

- **Verified on Ubuntu 24.04 under WSL2 and on a GitHub runner.** Not on bare metal and
  not on Debian, though nothing here is specific to either.
- **The alert rules are loaded, not fired.** The verification proves Prometheus parsed
  them. It does not prove the thresholds are right; that takes an outage.
- **No Alertmanager**, so the rules have nowhere to send anything yet.
- **One host.** Everything is written for more, nothing has been tested with more.
- **The Grafana password is a default in a file.** Fine for localhost, documented above
  for anything else.

## License

MIT, see [LICENSE](LICENSE).
