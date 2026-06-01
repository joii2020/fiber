CARGO_TARGET_DIR ?= target
COVERAGE_PROFRAW_DIR ?= ${CARGO_TARGET_DIR}/coverage
GRCOV_OUTPUT ?= coverage-report.info
GRCOV_EXCL_START = ^\s*((log::|tracing::)?(trace|debug|info|warn|error)|(debug_)?assert(_eq|_ne|_error_eq))!\($$
GRCOV_EXCL_STOP  = ^\s*\)(;)?$$
GRCOV_EXCL_LINE = ^\s*(\})*(\))*(;)*$$|\s*((log::|tracing::)?(trace|debug|info|warn|error)|(debug_)?assert(_eq|_ne|_error_eq))!\(.*\)(;)?$$

NATIVE_PACKAGES = -p fnn -p fiber-bin -p fnn-cli -p fiber-store -p fiber-types -p fiber-json-types
# fiber-types excluded because fiber-store depends on fiber-types@0.8.1 from
# crates.io, making "-p fiber-types" ambiguous. Checked separately.
NATIVE_NO_FIBER_TYPES = -p fnn -p fiber-bin -p fnn-cli -p fiber-store -p fiber-json-types
WASM_PACKAGES = -p fiber-wasm -p fiber-wasm-db-worker -p fiber-wasm-db-common

ANDROID_API ?= 23
ANDROID_ABIS ?= arm64-v8a
ANDROID_FEATURES ?= sqlite
ANDROID_NDK_HOME ?= $(NDK_HOME)
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
ANDROID_HOST_TAG ?= $(if $(filter Linux,$(UNAME_S)),linux-x86_64,$(if $(filter Darwin,$(UNAME_S)),$(if $(filter arm64,$(UNAME_M)),darwin-arm64,darwin-x86_64),unknown))
ANDROID_OUT_DIR ?= $(CARGO_TARGET_DIR)/android

.PHONY: build-metrics-prof
build-metrics-prof:
	RUSTFLAGS="${RUSTFLAGS} --cfg tokio_unstable -Cforce-frame-pointers=yes" cargo +nightly build --profile prof --features "metrics pprof"

.PHONY: android-so
android-so:
	@if [ -z "$(ANDROID_NDK_HOME)" ]; then \
		echo "ANDROID_NDK_HOME or NDK_HOME must point to an Android NDK"; \
		exit 1; \
	fi
	@if [ "$(ANDROID_HOST_TAG)" = "unknown" ]; then \
		echo "Unsupported Android NDK host: $$(uname -s)-$$(uname -m)"; \
		exit 1; \
	fi
	@set -e; \
	ndk_bin="$(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/$(ANDROID_HOST_TAG)/bin"; \
	shim_dir="$$(pwd)/$(CARGO_TARGET_DIR)/android-toolchain-shims"; \
	mkdir -p "$$shim_dir"; \
	for abi in $(ANDROID_ABIS); do \
		case "$$abi" in \
			arm64-v8a) target="aarch64-linux-android"; linker_prefix="aarch64-linux-android"; env_target="AARCH64_LINUX_ANDROID" ;; \
			armeabi-v7a) target="armv7-linux-androideabi"; linker_prefix="armv7a-linux-androideabi"; env_target="ARMV7_LINUX_ANDROIDEABI" ;; \
			x86_64) target="x86_64-linux-android"; linker_prefix="x86_64-linux-android"; env_target="X86_64_LINUX_ANDROID" ;; \
			x86) target="i686-linux-android"; linker_prefix="i686-linux-android"; env_target="I686_LINUX_ANDROID" ;; \
			*) echo "Unsupported Android ABI: $$abi"; exit 1 ;; \
		esac; \
		linker="$$ndk_bin/$${linker_prefix}$(ANDROID_API)-clang"; \
		linkerxx="$$ndk_bin/$${linker_prefix}$(ANDROID_API)-clang++"; \
		if [ ! -x "$$linker" ]; then \
			echo "Android linker not found or not executable: $$linker"; \
			exit 1; \
		fi; \
		ln -sf "$$linker" "$$shim_dir/$${target}-clang"; \
		ln -sf "$$linkerxx" "$$shim_dir/$${target}-clang++"; \
		ln -sf "$$ndk_bin/llvm-ar" "$$shim_dir/$${target}-ar"; \
		ln -sf "$$ndk_bin/llvm-ranlib" "$$shim_dir/$${target}-ranlib"; \
		echo "Building fiber-ffi for $$abi ($$target)"; \
		rustup target add "$$target"; \
		env \
			PATH="$$shim_dir:$$ndk_bin:$$PATH" \
			ANDROID_NDK_HOME="$(ANDROID_NDK_HOME)" \
			ANDROID_NDK_ROOT="$(ANDROID_NDK_HOME)" \
			CC_$$(printf '%s' "$$target" | tr '-' '_')="$$linker" \
			CXX_$$(printf '%s' "$$target" | tr '-' '_')="$$linkerxx" \
			AR_$$(printf '%s' "$$target" | tr '-' '_')="$$ndk_bin/llvm-ar" \
			RANLIB_$$(printf '%s' "$$target" | tr '-' '_')="$$ndk_bin/llvm-ranlib" \
			AR="$$ndk_bin/llvm-ar" \
			RANLIB="$$ndk_bin/llvm-ranlib" \
			CARGO_TARGET_$${env_target}_LINKER="$$linker" \
			BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/$(ANDROID_HOST_TAG)/sysroot --target=$$target -D__ANDROID_API__=$(ANDROID_API)" \
			cargo build --release -p fiber-ffi --target "$$target" --no-default-features --features "$(ANDROID_FEATURES)"; \
		mkdir -p "$(ANDROID_OUT_DIR)/$$abi"; \
		cp "$(CARGO_TARGET_DIR)/$$target/release/libfiber_ffi.so" "$(ANDROID_OUT_DIR)/$$abi/libfiber_ffi.so"; \
	done

.PHONY: test
test:
	RUST_LOG=off cargo nextest run --no-fail-fast $(NATIVE_NO_FIBER_TYPES)
	RUST_LOG=off cargo nextest run --no-fail-fast --no-default-features --features sqlite $(NATIVE_NO_FIBER_TYPES)
	RUST_LOG=off cargo nextest run --no-fail-fast -p fiber-types

.PHONY: check
check:
	cargo check --locked
	cargo check --release --locked
	cargo check --package fnn --no-default-features --features rocksdb
	cargo check --no-default-features --features sqlite $(NATIVE_NO_FIBER_TYPES)
	rustup target add wasm32-unknown-unknown
	cargo check --target wasm32-unknown-unknown -p fiber-types --all-features

.PHONY: clippy
clippy:
	cargo clippy --all-targets --all-features $(NATIVE_NO_FIBER_TYPES) -- -D warnings
	cargo clippy --no-default-features --features sqlite $(NATIVE_NO_FIBER_TYPES) -- -D warnings
	# fiber-types checked separately to avoid "-p fiber-types" ambiguity with crates.io dep
	cd crates/fiber-types && cargo clippy -- -D warnings
	cargo clippy $(WASM_PACKAGES) --target wasm32-unknown-unknown -- -D warnings

.PHONY: bless
bless:
	cargo clippy --fix --allow-dirty --allow-staged --all --all-targets --all-features
	cargo clippy --fix --allow-dirty --allow-staged $(WASM_PACKAGES) --target wasm32-unknown-unknown -- -D warnings
	cargo fmt --all

.PHONY: fmt
fmt:
	cargo fmt --all -- --check

coverage-clean:
	rm -rf "${CARGO_TARGET_DIR}/*.profraw" "${GRCOV_OUTPUT}" "${GRCOV_OUTPUT:.info=}"

coverage-install-tools:
	rustup component add llvm-tools-preview
	grcov --version || cargo install --locked grcov

coverage-run-unittests:
	mkdir -p "${COVERAGE_PROFRAW_DIR}"
	rm -f "${COVERAGE_PROFRAW_DIR}/*.profraw"
	RUSTFLAGS="${RUSTFLAGS} -Cinstrument-coverage" \
		RUST_LOG=off \
		LLVM_PROFILE_FILE="${COVERAGE_PROFRAW_DIR}/unittests-%p-%m.profraw" \
			cargo test -p fnn -p fiber-bin

coverage-collect-data:
	grcov "${COVERAGE_PROFRAW_DIR}" --binary-path "${CARGO_TARGET_DIR}/debug/" \
		-s . -t lcov --branch --ignore-not-existing \
		--ignore "/*" \
		--ignore "*/tests/*" \
		--ignore "*/tests.rs" \
		--excl-br-start "${GRCOV_EXCL_START}" --excl-br-stop "${GRCOV_EXCL_STOP}" \
		--excl-start    "${GRCOV_EXCL_START}" --excl-stop    "${GRCOV_EXCL_STOP}" \
		--excl-br-line  "${GRCOV_EXCL_LINE}" \
		--excl-line     "${GRCOV_EXCL_LINE}" \
		-o "${GRCOV_OUTPUT}"

coverage-generate-report:
	genhtml --ignore-errors inconsistent --ignore-errors corrupt --ignore-errors range --ignore-errors unmapped -o "${GRCOV_OUTPUT:.info=}" "${GRCOV_OUTPUT}"

coverage: coverage-run-unittests coverage-collect-data coverage-generate-report

RPC_GEN_VERSION = 0.1.22
.PHONY: gen-rpc-doc
gen-rpc-doc:
	@if ! command -v fiber-rpc-gen >/dev/null 2>&1 || [ "$$(fiber-rpc-gen --version | awk '{print $$2}')" != "$(RPC_GEN_VERSION)" ]; then \
        echo "Installing fiber-rpc-gen $(RPC_GEN_VERSION)..."; \
        cargo install fiber-rpc-gen --version $(RPC_GEN_VERSION) --force; \
	fi
	fiber-rpc-gen ./crates/fiber-lib/src/ --extra-types-dir ./crates/fiber-types/src/ --json-types-dir ./crates/fiber-json-types/src/ --exclude-modules utils
	if grep -q "TODO: add desc" ./crates/fiber-lib/src/rpc/README.md; then \
        echo "Warning: There are 'TODO: add desc' in src/rpc/README.md, please add documentation comments to resolve them"; \
		exit 1; \
    fi

.PHONY: check-dirty-rpc-doc
check-dirty-rpc-doc: gen-rpc-doc
	git diff --exit-code ./crates/fiber-lib/src/rpc/README.md

MIGRATION_CHECK_VERSION := 0.5.3
install-migration-check:
	@if ! command -v migration-check >/dev/null 2>&1 || [ "$$(migration-check --version | awk '{print $$2}')" != "$(MIGRATION_CHECK_VERSION)" ]; then \
		echo "Installing migration-check $(MIGRATION_CHECK_VERSION)..."; \
		cargo install migration-check --version $(MIGRATION_CHECK_VERSION) --force; \
	fi

.PHONY: check-migrate
check-migrate: install-migration-check
	migration-check -s ./crates/fiber-lib/src -s ./crates/fiber-types/src -t ./crates/fiber-types/src -o ./crates/fiber-lib/src/store/.schema.json

.PHONY: update-migrate-check
update-migrate-check: install-migration-check
	migration-check -s ./crates/fiber-lib/src -s ./crates/fiber-types/src -t ./crates/fiber-types/src -o ./crates/fiber-lib/src/store/.schema.json -u

.PHONY: benchmark-test
benchmark-test:
	cargo criterion --features bench

.PHONY: wasm-test
wasm-test:
	export WORKING_DIR=$(shell pwd) && cd ./.github/wasm-test-runner && npm install && node ./index.js

FUZZ_DURATION ?= 30
.PHONY: fuzz
fuzz:
	@rustup toolchain list | grep -q nightly || rustup toolchain install nightly
	@cargo +nightly fuzz --version >/dev/null 2>&1 || cargo +nightly install cargo-fuzz
	@cd crates/fiber-lib && \
	for target in $$(cargo +nightly fuzz list); do \
		echo "=== Fuzzing $$target for $(FUZZ_DURATION)s ===" && \
		cargo +nightly fuzz run "$$target" -- -max_total_time=$(FUZZ_DURATION) || exit 1; \
	done
	@echo "All fuzz targets passed."
