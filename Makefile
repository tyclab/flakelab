.PHONY: install-hooks lint fmt lint-nix test

# One-time per clone — installs the pre-commit framework hooks.
install-hooks:
	@command -v pre-commit >/dev/null 2>&1 || { echo "Error: pre-commit not installed. Enter 'nix develop', which ships it."; exit 1; }
	@if git config --get core.hooksPath >/dev/null 2>&1; then \
		echo "⚠️  core.hooksPath is set ($$(git config --get core.hooksPath)). Unsetting for pre-commit compatibility."; \
		git config --unset-all core.hooksPath || true; \
	fi
	pre-commit install
	# Install the pre-push hook too. Without it, a hook later given
	# `stages: [pre-push]` would silently never run.
	pre-commit install --hook-type pre-push
	@echo "✅ pre-commit hooks installed. Run 'make lint' to check the whole tree."

# Run all linters against the entire tree.
lint:
	pre-commit run --all-files

# Format the Nix sources. Needs nix — on a nix-less host, CI's lint job is the
# gate (see .github/workflows/ci.yml).
fmt:
	nix fmt

# The nix gates, locally: CI's lint job (fmt + diff) plus the two linters
# that are flake checks now. Built from the flake rather than `nix shell
# nixpkgs#statix`, so this runs the versions flake.lock pins — the same ones
# CI's `nix flake check` runs, instead of whatever the local registry resolves.
lint-nix:
	nix fmt
	git diff --exit-code
	nix build --no-link .#checks.x86_64-linux.statix .#checks.x86_64-linux.deadnix

# The offline suites: real scripts against throwaway fixtures, no network and no
# credentials, seconds each. test-provision-nix is deliberately not here — it
# builds an image and imports a distro, and that wipes host interop.
#
# Every suite runs, then the target fails if any of them did. One recipe line per
# suite would stop make at the first red one, and a single red suite would then
# hide every suite after it — including the ones this repo's own contribution
# guide says to run after touching them.
test:
	@rc=0; for suite in test-gitchecker test-gitcleaner test-gitpublisher test-nix-backup test-nix-overlay-generate; do \
		echo "==> $$suite"; \
		files/scripts/$$suite || rc=1; \
	done; \
	exit $$rc
