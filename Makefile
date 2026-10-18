EMACS=emacs
AUTOLOADS_FILE=lisp/elneo-autoloads.el
# Where `make server-install' copies the binary; must be on PATH as
# `elneo-server-command' finds it (or adjust that defcustom).
SERVER_INSTALL ?= $(HOME)/bin/elneo-server

.PHONY: all autoloads byte-compile clippy elisp-test clean server server-fmt server-test server-install

all: autoloads

clean:
	@rm -f lisp/*.elc
	@cargo clean --manifest-path server/Cargo.toml 2>/dev/null || true

autoloads:
	@$(EMACS) -Q --batch --eval "\
	 (loaddefs-generate '(\"lisp\") \"$(AUTOLOADS_FILE)\"))"

# elneo-alert.el and elneo-transient.el have external dependencies
# (alert.el, transient.el) that live outside this repository; compile
# them only when loadable, or a plain `make byte-compile' fails for
# anyone without them installed.
CORE_EL := $(filter-out lisp/elneo-alert.el lisp/elneo-transient.el,$(wildcard lisp/*.el))

byte-compile: autoloads
	@if $(EMACS) -Q --batch --eval "(require 'alert)" >/dev/null 2>&1; then \
		$(EMACS) -Q -L lisp --batch -f batch-byte-compile lisp/*.el; \
	else \
		echo "alert.el not loadable; skipping lisp/elneo-alert.el"; \
		$(EMACS) -Q -L lisp --batch -f batch-byte-compile $(CORE_EL); \
	fi

# Each test file is a self-contained batch script that kills Emacs with
# a non-zero status on failure; they (require) the modules they test.
elisp-test: autoloads
	@for t in $(wildcard test/*.el); do \
		echo "=== $$t ==="; \
		$(EMACS) -Q --batch -L lisp -l $$t || exit 1; \
	done

clippy:
	@cargo clippy --all-targets --manifest-path server/Cargo.toml -- -D warnings

server:
	@cargo build --release --manifest-path server/Cargo.toml

server-install: server
	install -m 755 server/target/release/elneo-server $(SERVER_INSTALL)

server-fmt:
	@cargo fmt --manifest-path server/Cargo.toml

# The fmt gate runs before the tests: a tree rustfmt would rewrite
# fails here, locally, not only in CI.
server-test:
	@cargo fmt --check --manifest-path server/Cargo.toml \
		|| { echo "server tree is not rustfmt-clean — run make server-fmt"; exit 1; }
	@cargo test --manifest-path server/Cargo.toml
