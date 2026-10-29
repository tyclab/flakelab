.PHONY: help install-hooks lint fmt lint-nix test

.DEFAULT_GOAL := help

help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install-hooks: ## Install the pre-commit and pre-push hooks (once per clone)
	@command -v pre-commit >/dev/null 2>&1 || { echo "Error: pre-commit not installed. Enter 'nix develop', which ships it."; exit 1; }
	@if git config --get core.hooksPath >/dev/null 2>&1; then \
		echo "⚠️  core.hooksPath is set ($$(git config --get core.hooksPath)). Unsetting for pre-commit compatibility."; \
		git config --unset-all core.hooksPath || true; \
	fi
	pre-commit install
	# Without this, a hook later given `stages: [pre-push]` never runs.
	pre-commit install --hook-type pre-push
	@echo "✅ pre-commit hooks installed. Run 'make lint' to check the whole tree."

lint: ## Run the pre-commit suite over the whole tree (CI's lint job)
	pre-commit run --all-files

# Needs nix; on a nix-less host CI's lint job is the gate.
fmt: ## Format the tree with nix fmt
	nix fmt

# Built from the flake so the pinned linter versions run.
lint-nix: ## nix fmt must change nothing, then statix and deadnix
	nix fmt
	git diff --exit-code
	nix build --no-link .#checks.x86_64-linux.statix .#checks.x86_64-linux.deadnix

# The offline suites. test-provision-nix imports a distro and needs a disposable
# session. All suites run, then the target fails if any of them did.
test: ## Run every offline suite (the required local gate)
	@rc=0; for suite in test-clone-repos test-gh-repos test-gitchecker test-gitcleaner test-gitpublisher test-nix-backup test-nix-overlay-generate test-flakelab-cli test-claude-sessions test-notify test-questions test-web test-mcp test-nix-update test-claude-plugin-orphans test-nix-doctor test-switch-result test-wsl-init-cgroup test-xdg-open test-activate-hooks test-report-stale-repos test-nix-provision; do \
		echo "==> $$suite"; \
		files/scripts/$$suite || rc=1; \
	done; \
	exit $$rc
