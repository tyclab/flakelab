.PHONY: install-hooks lint fmt lint-nix test

# One-time per clone.
install-hooks:
	@command -v pre-commit >/dev/null 2>&1 || { echo "Error: pre-commit not installed. Enter 'nix develop', which ships it."; exit 1; }
	@if git config --get core.hooksPath >/dev/null 2>&1; then \
		echo "⚠️  core.hooksPath is set ($$(git config --get core.hooksPath)). Unsetting for pre-commit compatibility."; \
		git config --unset-all core.hooksPath || true; \
	fi
	pre-commit install
	# Without this, a hook later given `stages: [pre-push]` never runs.
	pre-commit install --hook-type pre-push
	@echo "✅ pre-commit hooks installed. Run 'make lint' to check the whole tree."

lint:
	pre-commit run --all-files

# Needs nix; on a nix-less host CI's lint job is the gate.
fmt:
	nix fmt

# The nix gates locally. Built from the flake so the pinned linter versions run,
# not whatever the local registry resolves.
lint-nix:
	nix fmt
	git diff --exit-code
	nix build --no-link .#checks.x86_64-linux.statix .#checks.x86_64-linux.deadnix

# The offline suites. test-provision-nix is not here: it imports a distro, which
# wipes host interop. All suites run, then the target fails if any of them did.
test:
	@rc=0; for suite in test-clone-repos test-gitchecker test-gitcleaner test-gitpublisher test-nix-backup test-nix-overlay-generate test-flakelab-cli test-claude-sessions test-nix-update; do \
		echo "==> $$suite"; \
		files/scripts/$$suite || rc=1; \
	done; \
	exit $$rc
