# One entry point for every check, so a green terminal and a green pipeline mean the
# same thing. ANSIBLE lets CI point at the same binaries without editing this file.
ANSIBLE ?= ansible-playbook
ANSIBLE_LINT ?= ansible-lint
YAMLLINT ?= yamllint
GALAXY ?= ansible-galaxy
# CI uses this to say that Docker is already installed by the runner image.
EXTRA_VARS ?=

.PHONY: help deps lint check apply verify idempotence all destroy

help:
	@echo "deps         install the pinned collections"
	@echo "lint         yamllint and ansible-lint"
	@echo "check        a dry run with a diff, changes nothing"
	@echo "apply        build the homelab"
	@echo "verify       ask the running stack whether it works"
	@echo "idempotence  apply twice and fail unless the second run changes nothing"
	@echo "all          lint, apply, verify, idempotence"
	@echo "destroy      take the stack down and remove its volumes"

deps:
	$(GALAXY) collection install -r requirements.yml -p collections

lint:
	$(YAMLLINT) .
	$(ANSIBLE_LINT)

check:
	$(ANSIBLE) playbooks/site.yml --check --diff $(EXTRA_VARS)

apply:
	$(ANSIBLE) playbooks/site.yml $(EXTRA_VARS)

verify:
	$(ANSIBLE) playbooks/verify.yml $(EXTRA_VARS)

# The claim this repository makes about itself, checked rather than asserted. The second
# run must report changed=0: anything else means a task describes an action instead of a
# state, and the playbook would fight the machine on every run.
idempotence:
	$(ANSIBLE) playbooks/site.yml $(EXTRA_VARS)
	$(ANSIBLE) playbooks/site.yml $(EXTRA_VARS) | tee /tmp/homelab-second-run.log
	@grep -qE 'changed=0[[:space:]]+unreachable=0[[:space:]]+failed=0' /tmp/homelab-second-run.log 		&& echo "Idempotent: the second run changed nothing." 		|| { echo "NOT idempotent: the second run reported changes."; exit 1; }

all: lint apply verify idempotence

destroy:
	docker compose -f /opt/homelab/monitoring/compose.yaml -p homelab down --volumes
