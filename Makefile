# Where `make server-install' copies the binary; must be on PATH as
# `elneo-server-command' finds it (or adjust that defcustom).
SERVER_INSTALL ?= $(HOME)/bin/elneo-server

.PHONY: clean server server-fmt server-test server-install

clean:
	@cargo clean --manifest-path server/Cargo.toml 2>/dev/null || true

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
