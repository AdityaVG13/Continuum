GOOSE ?= goose
CXX ?= c++
BUILD := .build
export GOOSE_HOME := $(abspath $(BUILD)/goose-cache)

.PHONY: all check status sim daemon test web-e2e web-e2e-run meta-live native-check cpp-status transport-check asus-check host-check leap leap-e2e help clean

all: help

$(BUILD):
	mkdir -p $(BUILD)

check:
	$(GOOSE) check src/main.goose

$(BUILD)/continuum: $(wildcard src/*.goose) | $(BUILD)
	$(GOOSE) build src/main.goose --debug -o $@

status: $(BUILD)/continuum
	./$(BUILD)/continuum --status

sim:
	$(GOOSE) run src/main.goose -- --sim

daemon:
	$(GOOSE) run src/main.goose -- --daemon

test:
	$(GOOSE) run tests/sim_loop.goose
	$(GOOSE) run tests/foundation.goose
	$(GOOSE) run tests/toolbind.goose
	$(GOOSE) run tests/metamorphic.goose
	$(GOOSE) run tests/golden.goose
	$(GOOSE) run tests/conformance_matrix.goose
	$(GOOSE) run tests/fuzz_tooljson.goose
	$(GOOSE) run tests/leap_logic.goose

# End-to-end: Goose loop -> C++ transport -> C++ virtual router
# (tests/router_double.cpp, no wizard). Self-contained: the recipe
# spawns the double with a test-only password and tears it down.
$(BUILD)/web_e2e.c: tests/router_web_e2e.goose $(wildcard src/*.goose) | $(BUILD)
	$(GOOSE) -o $@ --standalone tests/router_web_e2e.goose

# The emitted C is C, not C++ (exact-fit string initializers), so it gets
# its own object from the C driver; the bridge and transport link as C++.
$(BUILD)/web_e2e_c.o: $(BUILD)/web_e2e.c
	$(CC) -O2 -c $< -o $@

$(BUILD)/web_e2e: $(BUILD)/web_e2e_c.o native/goose_bridge.c native/router_web.cpp
	$(CXX) -O2 $(BUILD)/web_e2e_c.o native/goose_bridge.c native/router_web.cpp -o $@

web-e2e: $(BUILD)/web_e2e

web-e2e-run: $(BUILD)/web_e2e $(BUILD)/router_double
	@ROUTER_PASSWORD=test-only-pw $(BUILD)/router_double 18081 >/dev/null 2>&1 & pid=$$!; \
	for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -A "OpenAI File Downloader, XaiImageApiFetch/1.0" -o /dev/null http://127.0.0.1:18081/api/status && break; sleep 1; done; \
	ROUTER_HOST=127.0.0.1 ROUTER_PORT=18081 ROUTER_PASSWORD=test-only-pw $(BUILD)/web_e2e; rc=$$?; \
	kill $$pid 2>/dev/null; wait $$pid 2>/dev/null; exit $$rc

# Manual live probe: Goose loop -> C++ Meta HTTPS transport -> provider.
# Native objects come from tests/meta_live.build. No-key run fails closed
# with no network; keyed run spends one bounded call.
$(BUILD)/meta_live: tests/meta_live.goose $(wildcard src/*.goose) | $(BUILD)
	$(GOOSE) build tests/meta_live.goose -o $@

meta-live: $(BUILD)/meta_live
	./$(BUILD)/meta_live

native-check:
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/continuum_native_stub.cpp native/fallback_main.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/meta_web.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/router_web.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/asus_web.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/vault.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/host_macos.cpp
	$(CC) -Wall -Wextra -Werror -fsyntax-only native/goose_bridge.c
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only -x c++ native/goose_bridge.c
	$(CC) -Wall -Wextra -Werror -fsyntax-only native/leap_bridge.c
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only -x c++ native/leap_bridge.c
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only tests/host_fake.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only tests/router_double.cpp

$(BUILD)/continuum-cpp-fallback: native/continuum_native.h native/continuum_native_stub.cpp native/fallback_main.cpp | $(BUILD)
	$(CXX) -std=c++20 -Wall -Wextra -Werror native/continuum_native_stub.cpp native/fallback_main.cpp -o $@

cpp-status: $(BUILD)/continuum-cpp-fallback
	./$(BUILD)/continuum-cpp-fallback --status

# Self-contained: runs the C++ transport harness against the C++ double
# with a test-only password, then tears it down.
$(BUILD)/native_transport_check: tests/native_transport_check.cpp native/router_web.cpp native/continuum_native.h | $(BUILD)
	$(CXX) -std=c++20 -Wall -Wextra -Werror -Inative tests/native_transport_check.cpp native/router_web.cpp -o $@

transport-check: $(BUILD)/native_transport_check $(BUILD)/router_double
	@ROUTER_PASSWORD=test-only-pw $(BUILD)/router_double 18091 >/dev/null 2>&1 & pid=$$!; \
	for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -A "OpenAI File Downloader, XaiImageApiFetch/1.0" -o /dev/null http://127.0.0.1:18091/api/status && break; sleep 1; done; \
	ROUTER_PASSWORD=test-only-pw $(BUILD)/native_transport_check 127.0.0.1 18091; rc=$$?; \
	kill $$pid 2>/dev/null; wait $$pid 2>/dev/null; exit $$rc

# The C++ virtual router: item-6 JSON API + ASUS QIS wizard fixture,
# fresh state per process. ROUTER_WIZARD=1|session selects the factory
# branch; ROUTER_PASSWORD is required to serve at all.
$(BUILD)/router_double: tests/router_double.cpp | $(BUILD)
	$(CXX) -std=c++20 -Wall -Wextra -Werror tests/router_double.cpp -o $@

# Self-contained: runs the ASUS ceremony harness against the C++ double
# in both wizard branches (open, then session-first).
$(BUILD)/native_asus_check: tests/native_asus_check.cpp native/asus_web.cpp native/vault.cpp native/continuum_native.h | $(BUILD)
	$(CXX) -std=c++20 -Wall -Wextra -Werror -Inative tests/native_asus_check.cpp native/asus_web.cpp native/vault.cpp -o $@

asus-check: $(BUILD)/native_asus_check $(BUILD)/router_double
	@ok=1; \
	for wz in 1 session; do \
	  name=open; if [ $$wz = session ]; then name=session; fi; \
	  ROUTER_PASSWORD=test-only-pw ROUTER_WIZARD=$$wz $(BUILD)/router_double 18092 >/dev/null 2>&1 & pid=$$!; \
	  for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -A "OpenAI File Downloader, XaiImageApiFetch/1.0" -o /dev/null http://127.0.0.1:18092/api/status && break; sleep 1; done; \
	  CONTINUUM_SECRET_TEST_ADMIN=StagedAdmin12345 \
	  CONTINUUM_SECRET_TEST_PSK=StagedPsk1234567 \
	  CONTINUUM_SECRET_TEST_ADMIN_LONG=TwentyCharsAdmin1234 \
	  $(BUILD)/native_asus_check 127.0.0.1 18092 $$name || ok=0; \
	  kill $$pid 2>/dev/null; wait $$pid 2>/dev/null; \
	done; \
	if [ $$ok = 1 ]; then echo ASUS_CHECK_ALL_GREEN; else echo ASUS_CHECK_RED; exit 1; fi

# Host backend harness (macOS): builds always, runs only with HOST_LAB=1
# because the roundtrip writes continuum.test.<pid>.* items into the real
# login keychain (deleted again in the run). Never joins a real network:
# rejoin is exercised only on its no-op and no-such-interface paths.
$(BUILD)/native_host_check: tests/native_host_check.cpp native/host_macos.cpp native/continuum_native.h | $(BUILD)
	$(CXX) -std=c++20 -Wall -Wextra -Werror -Inative tests/native_host_check.cpp native/host_macos.cpp -framework Security -framework CoreFoundation -o $@

host-check: $(BUILD)/native_host_check
ifeq ($(HOST_LAB),1)
	$(BUILD)/native_host_check
else
	@echo 'host-check: built $(BUILD)/native_host_check; skipping live run (touches the login keychain; re-run with HOST_LAB=1).'
endif

# The leap ceremony binary: Goose planner/executor -> C++ ASUS adapter
# -> macOS keychain + Wi-Fi host backend. Manual emit like web-e2e: a
# .build sidecar cannot express -framework flags. Dry run by default;
# LEAP_EXECUTE=1 writes. See src/leap_main.goose for the env knobs.
$(BUILD)/leap.c: src/leap_main.goose $(wildcard src/*.goose) | $(BUILD)
	$(GOOSE) -o $@ --standalone src/leap_main.goose

$(BUILD)/leap_c.o: $(BUILD)/leap.c
	$(CC) -O2 -c $< -o $@

$(BUILD)/continuum-leap: $(BUILD)/leap_c.o native/goose_bridge.c native/leap_bridge.c native/router_web.cpp native/asus_web.cpp native/host_macos.cpp
	$(CXX) -O2 $(BUILD)/leap_c.o native/goose_bridge.c native/leap_bridge.c native/router_web.cpp native/asus_web.cpp native/host_macos.cpp -framework Security -framework CoreFoundation -o $@

leap: $(BUILD)/continuum-leap
	./$(BUILD)/continuum-leap

# Headless leap e2e: the same Goose executor linked against the fake
# host backend (env vault, no keychain, no Wi-Fi), driven over the
# wired plan against the C++ double in both wizard branches. Dry run
# must write nothing (the execute run right after still leaps), the
# execute run must verify, and a second execute must refuse the now
# configured unit.
$(BUILD)/continuum-leap-test: $(BUILD)/leap_c.o native/goose_bridge.c native/leap_bridge.c native/router_web.cpp native/asus_web.cpp native/vault.cpp tests/host_fake.cpp
	$(CXX) -O2 $(BUILD)/leap_c.o native/goose_bridge.c native/leap_bridge.c native/router_web.cpp native/asus_web.cpp native/vault.cpp tests/host_fake.cpp -o $@

leap-e2e: $(BUILD)/continuum-leap-test $(BUILD)/router_double
	@ok=1; \
	for wz in 1 session; do \
	  ROUTER_PASSWORD=test-only-pw ROUTER_WIZARD=$$wz $(BUILD)/router_double 18094 >/dev/null 2>&1 & pid=$$!; \
	  for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -A "OpenAI File Downloader, XaiImageApiFetch/1.0" -o /dev/null http://127.0.0.1:18094/api/status && break; sleep 1; done; \
	  base="ROUTER_HOST=127.0.0.1 ROUTER_PORT=18094 SSID_STEM=LeapLab CONTROL_RIDES_WIFI=0"; \
	  env $$base $(BUILD)/continuum-leap-test > $(BUILD)/leap-e2e.log 2>&1 || ok=0; \
	  grep -q "dry run complete" $(BUILD)/leap-e2e.log || ok=0; \
	  env $$base LEAP_EXECUTE=1 $(BUILD)/continuum-leap-test > $(BUILD)/leap-e2e.log 2>&1 || ok=0; \
	  grep -q "OUTCOME Verified" $(BUILD)/leap-e2e.log || ok=0; \
	  grep -q "LEAP_OK" $(BUILD)/leap-e2e.log || ok=0; \
	  if env $$base LEAP_EXECUTE=1 $(BUILD)/continuum-leap-test > $(BUILD)/leap-e2e.log 2>&1; then ok=0; fi; \
	  grep -q "LEAP_FAILED phase=discover" $(BUILD)/leap-e2e.log || ok=0; \
	  kill $$pid 2>/dev/null; wait $$pid 2>/dev/null; \
	done; \
	if [ $$ok = 1 ]; then echo LEAP_E2E_ALL_GREEN; else echo LEAP_E2E_RED "see $(BUILD)/leap-e2e.log"; exit 1; fi

help:
	@echo 'Continuum: a Meta-directed network controller. Goose primary, C++ native boundaries.'
	@echo 'make check         Typecheck the Goose sources'
	@echo 'make status        Build and print implementation status'
	@echo 'make sim           Deterministic sim transcript (no network)'
	@echo 'make daemon        Deterministic daemon transcript (no network, no model calls)'
	@echo 'make test          Goose contract suites (sim-only, no network)'
	@echo 'make web-e2e       Build the Goose->C++->router loop binary'
	@echo 'make web-e2e-run   Run it end to end vs the C++ double (self-contained)'
	@echo 'make meta-live     One bounded Meta round trip (needs MODEL_API_KEY; fails closed without)'
	@echo 'make native-check  Syntax-check the C++ native sources'
	@echo 'make cpp-status    Build and print C++ fallback status'
	@echo 'make transport-check C++ transport harness vs C++ double (self-contained)'
	@echo 'make asus-check    ASUS ceremony harness vs C++ double (open+session)'
	@echo 'make host-check    Build the macOS host harness; runs only with HOST_LAB=1'
	@echo 'make leap-e2e      Headless leap ceremony vs C++ double (fake host backend)'
	@echo 'make leap          Build+run the leap ceremony (dry unless LEAP_EXECUTE=1; needs ROUTER_HOST + SSID_STEM)'
	@echo 'Set GOOSE=/absolute/path/to/goose for the pinned v2026.3 compiler.'

clean:
	rm -rf $(BUILD)
