.PHONY: help setup test test-core test-app test-remote run logs clean clean-full rebuild

help:
	@echo "Test Environment Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  make setup        - Setup Docker test environment (uses cached image)"
	@echo "  make test         - Run all tests (setup first, auto cleanup after)"
	@echo "  make test-core    - Run core lib tests only"
	@echo "  make test-app     - Run application-specific tests only"
	@echo "  make test-remote  - Run remote tests only (requires setup)"
	@echo "  make run          - Interactive shell in container"
	@echo "  make logs         - View container logs"
	@echo "  make rebuild      - Force rebuild of Docker image"
	@echo "  make clean        - Stop and remove containers"
	@echo "  make clean-full   - Full cleanup (containers + images + keys)"

setup:
	@./setup-test-env.sh

test:
	@echo "Running setup (idempotent)..."
	@./setup-test-env.sh
	@echo ""
	@echo "Running all tests..."
	@$(MAKE) test-core test-app test-remote
	@echo ""
	@echo "Cleaning up..."
	@$(MAKE) clean

test-core:
	@echo "Running core library tests..."
	@./run-core-tests.sh

test-app:
	@echo "Running application-specific tests..."
	@./run-app-tests.sh

test-remote:
	@echo "Running remote installation tests..."
	@./run-remote-tests.sh

run:
	@if ! docker ps | grep -q dotfiles-test-server; then \
		echo "Error: Test server not running. Run 'make setup' first."; \
		exit 1; \
	fi
	@echo "Starting interactive shell in test container..."
	@echo "Exit with 'exit' or Ctrl+D"
	@ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-i ssh-key -p 2222 testuser@localhost

logs:
	@cd docker && docker-compose logs -f

rebuild:
	@echo "Forcing rebuild of Docker image..."
	@cd docker && docker-compose build --no-cache

clean:
	@./cleanup-test-env.sh

clean-full:
	@./cleanup-test-env.sh --full
