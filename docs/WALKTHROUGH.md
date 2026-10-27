# Walkthrough

Why this repository is shaped the way it is. The README says what it does; this says why,
and where it stops.

## 1. What "as code" has to mean to be worth anything

A repository full of YAML is not infrastructure as code. It becomes that when three
things are true, and all three are checkable:

1. Running it twice changes nothing the second time.
2. The result can be asked whether it works, separately from having been deployed.
3. Rebuilding on a different machine needs an inventory entry, not an edit to a role.

Each of those is a target in the Makefile. `make idempotence` greps the second run's recap
for `changed=0 unreachable=0 failed=0` and exits non-zero otherwise. That line is the
contract.

## 2. The hard part is deciding what reports `changed`

Ansible reports `changed` when a module says state moved. That makes idempotence a
property of the modules you pick and how you use them, not something that happens.

**Compose.** `docker compose up -d` through `ansible.builtin.command` reports changed every
single run, because `command` has no idea what it did. `community.docker.docker_compose_v2`
knows the difference between creating a container and finding one already there. Using it
is the difference between a check that means something and one that is always red.

**Package installation.** `apt` with `update_cache: true` and no `cache_valid_time`
refreshes the package index on every run, which takes seconds and reports changed.
`cache_valid_time: 3600` makes the refresh conditional, and the task goes green.

**Image pulls.** `pull: always` would reach out on every run to be told the same digest
for a pinned tag. `pull: missing` fetches once.

**The handler.** This one is the subtle one and it is a correctness issue, not a
cosmetic one. Compose decides whether to recreate a container by comparing its own
configuration — the compose file, the environment, the image. It does not look inside a
file that happens to be bind-mounted. So a changed `prometheus.yml` would be written to
disk, reported as `changed`, and then completely ignored by the running container. The
playbook would be green and the stack would be stale.

```yaml
- name: Write the Prometheus configuration
  ansible.builtin.template:
    ...
  notify: Recreate the monitoring stack
```

The handler runs `docker_compose_v2` with `recreate: always`, once, at the end of the
play, and only if something notified it. That is why the clean run shows two handlers
firing and the second run shows none.

## 3. Verification is a separate playbook, on purpose

`site.yml` makes the machine match the description. `verify.yml` asks the result whether
it works. Keeping them apart means verification can be run without touching anything,
which is what you want at three in the morning.

What it asserts, and why each one:

- **Prometheus reports itself healthy** — the container is up and past startup, which
  `docker ps` cannot tell you.
- **At least two targets, all of them `up`** — the stack can be running while Prometheus
  fails to reach node-exporter over the compose network. This is the check that catches a
  name resolution or network mistake.
- **The `homelab` rule group is loaded, with three rules** — this is the one I would point
  at. Writing a rules file always succeeds. Having Prometheus *parse and load* it is the
  part that fails silently, and the only way to know is to ask Prometheus. In an earlier
  project of mine the alert rules shipped unverified and the README had to say so; here
  they are checked, and that difference is the whole reason this assertion exists.
- **Grafana's database is `ok` and the data source was provisioned** — a provisioned data
  source is a file Grafana may or may not have accepted. Asking its API is the difference.
- **node-exporter reports `node_filesystem_size_bytes`** — the container can be running and
  measuring nothing if the host mount is wrong, which is exactly what happened here once.

The retries matter. Containers take seconds to be ready, so the first two tasks use
`until` with thirty attempts. Without that, the verification is a race it loses about half
the time.

## 4. The bug that only applying it could find

The first apply on a clean machine failed like this:

```
Error response from daemon: path / is mounted on / but it is not a shared or slave mount
```

node-exporter's documented compose snippet mounts the host root with `ro,rslave`, so that
filesystems mounted after the container starts are still visible. That propagation mode
requires the host's root to be a shared or slave mount. systemd makes it so on an ordinary
Linux host. Inside WSL2 the root is private, and Docker refuses the container.

Two services had already started by then, which is its own lesson: a partial deployment is
the normal failure mode, not an exotic one.

The fix is a variable rather than a hard-coded value either way:

```yaml
# Set this to "ro,rslave" on a real host.
node_exporter_rootfs_mount_options: "ro"
```

The default works everywhere and costs only visibility of mounts created after the
container starts. Hard-coding `rslave` would have made the repository work on the author's
imagination and not on the author's machine; hard-coding `ro` without the comment would
have quietly diverged from upstream's advice with no trace of why.

## 5. Two linters that argued

`ansible-lint` passed with the `production` profile from the first run, but printed a
warning every time: my `.yamllint` contradicted what it requires. It took three rounds to
settle, because each fix revealed the next requirement:

1. `comments-indentation` must be off
2. `braces.max-spaces-inside` must be 1, and both octal checks on
3. `comments.min-spaces-from-content` must be 1

This was worth chasing rather than suppressing. A tool that prints a warning on every
single run trains everybody to stop reading its output, and then the warning that matters
arrives in the same stream and is ignored. Both are silent now.

A related one: `ansible-lint` installs its own `ansible-core` as a dependency. The copy in
my environment was `2.21.5` while the system's was `2.16.3` — so the linter was judging
code against a different version of the thing that would run it. `requirements.txt` pins
both, and the README says why in one paragraph.

Removing `stdout_callback = yaml` belongs in the same category: the `yaml` callback moved
out of `ansible-core` into `community.general`, and adding a collection for prettier
output is not a trade worth making when the only line this project reads from a run is the
recap.

## 6. Variables, and the line between a role and a deployment

Nothing in a role is specific to my machine. Every port, path, image tag, retention and
bind address lives in `inventory/group_vars/homelab.yml`. A template reads them; none of
them appears twice.

That is what makes the inventory the only thing to change for a second host. The commented
SSH entry in `hosts.yml` is not decoration — it is the proof that `ansible_connection:
local` is a property of one host rather than an assumption in the roles.

`docker_manage_packages` came out of CI and is the clearest example. A GitHub runner has
Docker from Docker's own repository; installing `docker.io` there means apt fighting over
which package owns the binary. The variable lets the role configure and start a daemon it
did not install, which is also true of plenty of real hosts.

## 7. Secrets

`grafana_admin_password` sits in a file in the repository with the value `admin`. That is a
defensible default for a service published only on `127.0.0.1`, and it would be
indefensible for anything else, so the README documents the vault path rather than leaving
it as an exercise.

The honest framing: this is a homelab, the service is bound to localhost, and pretending
otherwise by scattering vault files through a demonstration repository would make it harder
to read for no real gain. The moment a reverse proxy appears, the password moves.

## 8. What is not tested, and why

- **Only two environments.** Ubuntu 24.04 under WSL2, and the GitHub runner. Nothing here
  is specific to either, but "should work on Debian" is a guess until someone runs it.
- **The alert thresholds.** Prometheus loads the rules; nobody has made them fire. Ten
  percent free disk and fifteen minutes of memory pressure are judgement, not measurement.
- **No Alertmanager**, so a firing rule currently has nowhere to go. Adding it is another
  service in the same template and another assertion in `verify.yml`.
- **Restore.** There is no backup role, and a backup nobody has restored is a hope rather
  than a plan. That is the first thing I would add next, with the restore tested in CI
  against a throwaway volume.
- **Roles in isolation.** Everything is tested end to end. Molecule would test each role in
  its own container, which matters once a role is used by more than one playbook.

## 9. A note about the development environment

The repository is edited on Windows and applied from Ubuntu under WSL2, which produced two
problems worth recording because they look like bugs in the code.

Python writing files on Windows produces CRLF line endings. Ansible tolerates them; a
Makefile does not, and a shell heredoc does not. Everything is normalised to LF, and
`.gitattributes` keeps it that way.

Ansible ignores an `ansible.cfg` that sits in a world-writable directory, which is a
sensible protection and a confusing one: `/mnt/c` is mounted `777` by default, so the
configuration was silently not read. Adding `options = "metadata,umask=22,fmask=11"` to
`/etc/wsl.conf` gives the mount real permissions. The comment at the top of `ansible.cfg`
says so, because the next person to hit it will spend an hour otherwise.

## 10. If I had to extend this tomorrow

A new service is a block in `compose.yaml.j2`, its variables in `group_vars`, and an
assertion in `verify.yml`. A new host is a line in the inventory. A new role is a directory
and one line in `site.yml`.

The two things I would do before calling this finished for a real homelab: a backup role
with a restore that runs in CI, and a reverse proxy with TLS so that binding to something
other than localhost is a reasonable thing to do.
