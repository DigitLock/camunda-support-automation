# STAND_HOST comes from the shell environment (e.g. user@vm-hostname), never from a tracked file.
.PHONY: sync deploy check-public

sync:
ifndef STAND_HOST
	$(error STAND_HOST is not set; export STAND_HOST=user@host first)
endif
	rsync -az --delete --exclude '.git' --exclude '.env' --exclude '.DS_Store' --exclude '.venv' --exclude '__pycache__' --exclude '*.pyc' ./ $(STAND_HOST):/opt/camunda-support-automation/

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
	@! grep -rniE "$$PUBLIC_CHECK_PATTERN" . --exclude-dir=.git --exclude-dir=.venv
