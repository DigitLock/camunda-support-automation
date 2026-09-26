# STAND_HOST comes from the shell environment (e.g. user@vm-hostname), never from a tracked file.
.PHONY: sync deploy check-public fault-on fault-off fault-status

sync:
ifndef STAND_HOST
	$(error STAND_HOST is not set; export STAND_HOST=user@host first)
endif
	# --delete removes anything on the stand that is not in the repo; only the exact name .env
	# is excluded, so a config backup next to it (infra/.env.bak) would be deleted on the
	# next deploy (seen in Phase 6.1). Keep backups outside the deploy directory; the
	# .env.bak* exclude is a safety net, not the place for them (docs/ops/install.md).
	rsync -az --delete --exclude '.git' --exclude '.env' --exclude '.env.bak*' --exclude '.DS_Store' --exclude '.venv' --exclude '__pycache__' --exclude '*.pyc' ./ $(STAND_HOST):/opt/camunda-support-automation/

# No --wait: it treats successfully exited one-shot containers (kafka-init) as failures
# when nothing depends on them (docker/compose#10596); health gating stays on depends_on.
# Profiles come from COMPOSE_PROFILES in infra/.env on the VM.
deploy: sync
	ssh $(STAND_HOST) 'cd /opt/camunda-support-automation/infra && docker compose up -d --build'
# Public-repository check: exit 0 = clean (grep's "no match" inverted), 1 = a match was
# printed above. The pattern comes from the owner's shell environment (like STAND_HOST) —
# it names what the repository must not contain, so it is never a tracked string.
check-public:
ifndef PUBLIC_CHECK_PATTERN
	$(error PUBLIC_CHECK_PATTERN is not set; export it first)
endif
	@! grep -rniIE "$$PUBLIC_CHECK_PATTERN" . --exclude-dir=.git --exclude-dir=.venv

# Phase 6.1 scenario A2: runtime outage toggle of the mock booking-api on the stand. The
# image is scratch (no shell/curl) and the port is not published, so the binary's own
# -fault flag talks to the running service. STATUS overrides the default 503:
#   make fault-on            make fault-on STATUS=500        make fault-off / fault-status
fault-on fault-off fault-status:
ifndef STAND_HOST
	$(error STAND_HOST is not set; export STAND_HOST=user@host first)
endif
	ssh $(STAND_HOST) 'cd /opt/camunda-support-automation/infra && docker compose exec -T booking-api /app -fault $(patsubst fault-%,%,$@)$(if $(STATUS),:$(STATUS))'
