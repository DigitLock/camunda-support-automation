# STAND_HOST comes from the shell environment (e.g. user@vm-hostname), never from a tracked file.
.PHONY: sync deploy

sync:
ifndef STAND_HOST
	$(error STAND_HOST is not set; export STAND_HOST=user@host first)
endif
	rsync -az --delete --exclude '.git' --exclude '.env' --exclude '.DS_Store' ./ $(STAND_HOST):/opt/camunda-support-automation/

deploy: sync
	ssh $(STAND_HOST) 'cd /opt/camunda-support-automation/infra && docker compose up -d --wait'