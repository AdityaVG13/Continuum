GOOSE ?= goose
CXX ?= c++
BUILD := .build
HOST_OS ?= $(shell uname -s)
export GOOSE_HOME := $(abspath $(BUILD)/goose-cache)
GOOSE_TESTS := sim_loop sim_controller foundation toolbind metamorphic golden conformance_matrix fuzz_tooljson leap_logic

.PHONY: all check status sim daemon tui owner-check service-check setup-check continuity-check loop loop-router router-cli test web-e2e web-e2e-run meta-live meta-check native-check cpp-status transport-check asus-check host-check leap leap-e2e install help clean

# Install the single entry point on PATH. `continuum` with no arguments opens
# the setup TUI, which discovers this host and walks the device lifecycle.
PREFIX ?= $(HOME)/.local
install: $(BUILD)/continuum
	install -d $(PREFIX)/bin
	install -m 0755 $(BUILD)/continuum $(PREFIX)/bin/continuum
	# Prompts and tool schemas are read at runtime; bin/continuum finds them in
	# ../share/continuum when started outside the checkout.
	install -d $(PREFIX)/share/continuum/docs $(PREFIX)/share/continuum/fixtures
	cp -R docs/prompts $(PREFIX)/share/continuum/docs/
	cp -R schemas $(PREFIX)/share/continuum/
	cp -R fixtures/corpus $(PREFIX)/share/continuum/fixtures/
	@printf '%s\n' "installed $(PREFIX)/bin/continuum and $(PREFIX)/share/continuum"

# Release archive: the same prefix tree `install` writes, plus install.sh, the
# one-line installer the release page points at. Asset names carry no version
# so releases/latest/download/<name> always resolves.
DIST := $(BUILD)/dist
.PHONY: install dist
dist: $(BUILD)/continuum
	@test -n "$(MACOS_SIGN_IDENTITY)" || { printf '%s\n' 'dist: set MACOS_SIGN_IDENTITY; a release binary is signed'; exit 1; }
	$(MAKE) --no-print-directory install PREFIX=$(abspath $(DIST))/continuum-macos-arm64
	/usr/bin/codesign --force --sign "$(MACOS_SIGN_IDENTITY)" --identifier org.continuum.controller --timestamp=none $(DIST)/continuum-macos-arm64/bin/continuum
	/usr/bin/codesign --verify --strict $(DIST)/continuum-macos-arm64/bin/continuum
	COPYFILE_DISABLE=1 tar -C $(DIST) -czf $(DIST)/continuum-macos-arm64.tar.gz continuum-macos-arm64
	install -m 0755 install.sh $(DIST)/install.sh
	cd $(DIST) && shasum -a 256 continuum-macos-arm64.tar.gz install.sh > SHA256SUMS.txt
	@printf '%s\n' "release assets in $(DIST): continuum-macos-arm64.tar.gz install.sh SHA256SUMS.txt"

all: help

$(BUILD):
	mkdir -p $(BUILD)

.PHONY: check-all

# One entry for the full local gate: every target a release must pass, in order.
# Wall time is dominated by device-time drills that must actually elapse (a lease
# that expires unaided, a post-apply settle window) and by live sampling loops;
# the CPU cost is small.
check-all:
	$(MAKE) check test owner-check service-check setup-check continuity-check device-check measure-check signing-check
	@printf '%s\n' 'CHECK_ALL_GREEN'

check:
	$(GOOSE) check src/main.goose

# The pinned .build sidecar cannot express Apple framework flags. Emit C
# and use the same explicit native link as the existing leap executable.
PLATFORM_LIBS :=
define SIGN_BINARY
endef
ifeq ($(HOST_OS),Darwin)
PLATFORM_LIBS := -framework Security -framework CoreFoundation -framework SystemConfiguration
# Public certificate selection only; no private keys or passwords in this file.
# Keep it local and apply it after every production link, not only once by hand.
-include $(BUILD)/signing.mk
MACOS_SIGN_IDENTITY ?=
ifneq ($(strip $(MACOS_SIGN_IDENTITY)),)
ifeq ($(strip $(MACOS_SIGN_IDENTITY)),-)
$(error MACOS_SIGN_IDENTITY must name a certificate; ad-hoc signatures change identity on rebuild)
endif
define SIGN_BINARY
	/usr/bin/codesign --force --sign "$(MACOS_SIGN_IDENTITY)" --identifier "$(1)" --timestamp=none "$(2)"
	/usr/bin/codesign --verify --strict --verbose=2 "$(2)"
endef
endif
endif

.PHONY: sign signing-check
sign:
ifeq ($(HOST_OS),Darwin)
	@test -n "$(MACOS_SIGN_IDENTITY)" || { printf '%s\n' 'sign: set MACOS_SIGN_IDENTITY to a certificate name or fingerprint (or use .build/signing.mk)'; exit 1; }
	$(MAKE) $(BUILD)/continuum $(BUILD)/continuum-leap
	$(call SIGN_BINARY,org.continuum.controller,$(BUILD)/continuum)
	$(call SIGN_BINARY,org.continuum.leap,$(BUILD)/continuum-leap)
else
	@printf '%s\n' 'sign: Apple signing is not required on this platform'
endif

signing-check:
	python3 tests/signing.py

$(BUILD)/continuum.c: $(wildcard src/*.goose) src/main.build | $(BUILD)
	$(GOOSE) -o $@ --standalone src/main.goose

$(BUILD)/continuum_c.o: $(BUILD)/continuum.c
	$(CC) -O2 -c $< -o $@

DEVICE_NATIVE := native/leap_bridge.c native/asus_web.cpp
PROGRAM_NATIVE := native/program.cpp
PROBE_NATIVE := native/probe.cpp
$(BUILD)/continuum: $(BUILD)/continuum_c.o $(wildcard native/*.c native/*.cpp native/*.h) Makefile $(wildcard $(BUILD)/signing.mk)
	$(CXX) -std=c++20 -O2 $(BUILD)/continuum_c.o native/goose_bridge.c native/setup_bridge.c native/router_web.cpp native/meta_web.cpp native/discovery.cpp native/terminal.cpp native/continuity.cpp native/service.cpp $(PROGRAM_NATIVE) native/host_macos.cpp $(DEVICE_NATIVE) native/commission_ssh.cpp $(PROBE_NATIVE) $(PLATFORM_LIBS) -o $@
	$(call SIGN_BINARY,org.continuum.controller,$@)

tui: $(BUILD)/continuum
	./$(BUILD)/continuum --tui

$(BUILD)/continuum-setup-test: $(BUILD)/continuum_c.o tests/setup_meta.cpp $(wildcard native/*.c native/*.cpp native/*.h)
	$(CXX) -std=c++20 -O2 $(BUILD)/continuum_c.o native/goose_bridge.c native/setup_bridge.c native/router_web.cpp native/discovery.cpp native/terminal.cpp native/continuity.cpp native/service.cpp $(PROGRAM_NATIVE) native/vault.cpp tests/setup_meta.cpp $(DEVICE_NATIVE) native/commission_ssh.cpp tests/host_fake.cpp $(PROBE_NATIVE) $(PLATFORM_LIBS) -o $@

$(BUILD)/continuum-service-test: $(BUILD)/continuum_c.o tests/service_host.cpp tests/setup_meta.cpp $(wildcard native/*.c native/*.cpp native/*.h)
	$(CXX) -std=c++20 -O2 $(BUILD)/continuum_c.o native/goose_bridge.c native/setup_bridge.c native/router_web.cpp native/terminal.cpp native/continuity.cpp native/service.cpp $(PROGRAM_NATIVE) native/vault.cpp tests/service_host.cpp tests/setup_meta.cpp $(DEVICE_NATIVE) tests/commission_host.cpp tests/host_fake.cpp $(PROBE_NATIVE) $(PLATFORM_LIBS) -o $@

owner-check: $(BUILD)/continuum $(BUILD)/continuum-setup-test
	python3 tests/owner_programs.py $(BUILD)/continuum $(BUILD)/continuum-setup-test

service-check: $(BUILD)/continuum $(BUILD)/continuum-service-test
	python3 tests/service_cli.py $(BUILD)/continuum $(BUILD)/continuum-service-test

.PHONY: device-check measure-check
device-check: $(BUILD)/continuum-leap-test $(BUILD)/router_double $(BUILD)/continuum-service-test
	python3 tests/commission_cli.py $(BUILD)/continuum-leap-test $(BUILD)/router_double $(BUILD)/continuum-service-test
	python3 tests/enroll_cli.py $(BUILD)/continuum-service-test $(BUILD)/router_double

measure-check: $(BUILD)/continuum
	python3 tests/measure_cli.py $(BUILD)/continuum

continuity-check: $(BUILD)/continuum-setup-test
	python3 tests/continuity_cli.py $(BUILD)/continuum-setup-test

setup-check: $(BUILD)/continuum $(BUILD)/continuum-setup-test
	python3 tests/setup_tui.py $(BUILD)/continuum

status: $(BUILD)/continuum
	./$(BUILD)/continuum --status

sim: $(BUILD)/continuum
	./$(BUILD)/continuum --sim

daemon: $(BUILD)/continuum
	./$(BUILD)/continuum --daemon

loop: $(BUILD)/continuum
	./$(BUILD)/continuum --loop

# Same live model/task entry as `make loop`, pointed at the C++ double.
# Needs MODEL_API_KEY and spends bounded calls. Abstention is permitted;
# the model's actual choice, not a scripted revision bump, drives the run.
loop-router: $(BUILD)/continuum $(BUILD)/router_double
	@test -n "$$MODEL_API_KEY" || { echo 'loop-router: MODEL_API_KEY required'; exit 1; }
	@ROUTER_PASSWORD=test-only-pw $(BUILD)/router_double 18095 >/dev/null 2>&1 & pid=$$!; \
	for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -A "OpenAI File Downloader, XaiImageApiFetch/1.0" -o /dev/null http://127.0.0.1:18095/api/status && break; sleep 1; done; \
	ROUTER_HOST=127.0.0.1 ROUTER_PORT=18095 ROUTER_PASSWORD=test-only-pw $(BUILD)/continuum --loop; rc=$$?; \
	kill $$pid 2>/dev/null; wait $$pid 2>/dev/null; exit $$rc

# Operator tuner against the C++ double. status must match an independent
# QoS read, apply must leave the setting, restore must retire that revision.
router-cli: $(BUILD)/continuum $(BUILD)/router_double tests/router_cli.sh
	@sh tests/router_cli.sh $(BUILD)/continuum $(BUILD)/router_double 18096

# The shared session reaches C++ at runtime even in recorded mode. Use
# the compiler's native build route, not libtcc's unresolved C++ imports.
$(BUILD)/test-%: tests/%.goose $(wildcard src/*.goose tests/*.build native/*.c native/*.cpp native/*.h) | $(BUILD)
	$(GOOSE) build $< -o $@

test: $(addprefix $(BUILD)/test-,$(GOOSE_TESTS))
	@set -e; for suite in $(GOOSE_TESTS); do env -u MODEL_API_KEY ./$(BUILD)/test-$$suite; done

# End-to-end: Goose loop -> C++ transport -> C++ virtual router
# (tests/router_double.cpp, no wizard). Self-contained: the recipe
# spawns the double with a test-only password and tears it down.
$(BUILD)/web_e2e.c: tests/router_web_e2e.goose $(wildcard src/*.goose) | $(BUILD)
	$(GOOSE) -o $@ --standalone tests/router_web_e2e.goose

# The emitted C is C, not C++ (exact-fit string initializers), so it gets
# its own object from the C driver; the bridge and transport link as C++.
$(BUILD)/web_e2e_c.o: $(BUILD)/web_e2e.c
	$(CC) -O2 -c $< -o $@

$(BUILD)/web_e2e: $(BUILD)/web_e2e_c.o native/goose_bridge.c native/router_web.cpp native/meta_web.cpp native/continuum_native.h
	$(CXX) -O2 $(BUILD)/web_e2e_c.o native/goose_bridge.c native/router_web.cpp native/meta_web.cpp -o $@

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

$(BUILD)/native_meta_check: tests/native_meta_check.cpp native/meta_web.cpp native/continuum_native.h | $(BUILD)
	$(CXX) -std=c++20 -Wall -Wextra -Werror tests/native_meta_check.cpp native/meta_web.cpp -o $@

meta-check: $(BUILD)/native_meta_check
	./$(BUILD)/native_meta_check

native-check:
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/continuum_native_stub.cpp native/fallback_main.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/meta_web.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/router_web.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/asus_web.cpp native/commission_ssh.cpp tests/commission_host.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/vault.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/host_macos.cpp
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only native/discovery.cpp native/terminal.cpp native/continuity.cpp native/service.cpp native/program.cpp tests/setup_meta.cpp
	$(CC) -Wall -Wextra -Werror -fsyntax-only native/setup_bridge.c
	$(CXX) -std=c++20 -Wall -Wextra -Werror -fsyntax-only -x c++ native/setup_bridge.c
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
$(BUILD)/native_asus_check: tests/native_asus_check.cpp native/asus_web.cpp native/asus_commission.h native/commission_ssh.cpp native/commission_ssh.h native/vault.cpp native/continuum_native.h | $(BUILD)
	$(CXX) -std=c++20 -Wall -Wextra -Werror -Inative tests/native_asus_check.cpp native/asus_web.cpp native/commission_ssh.cpp native/vault.cpp -o $@

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
# because it writes test-owned login Keychain items and removes them again.
# It never joins a real network; rejoin uses invalid interfaces or a child
# command double that checks stdin delivery and DHCP evidence.
$(BUILD)/native_host_check: tests/native_host_check.cpp native/host_macos.cpp native/continuum_native.h | $(BUILD)
	$(CXX) -std=c++20 -Wall -Wextra -Werror -Inative tests/native_host_check.cpp native/host_macos.cpp -framework Security -framework CoreFoundation -o $@

host-check: $(BUILD)/native_host_check
ifeq ($(HOST_LAB),1)
	$(BUILD)/native_host_check
	$(BUILD)/native_host_check --rejoin-check
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

$(BUILD)/continuum-leap: $(BUILD)/leap_c.o native/goose_bridge.c native/leap_bridge.c native/router_web.cpp native/asus_web.cpp native/asus_commission.h native/commission_ssh.cpp native/commission_ssh.h native/host_macos.cpp native/continuum_native.h Makefile $(wildcard $(BUILD)/signing.mk)
	$(CXX) -std=c++20 -O2 $(BUILD)/leap_c.o native/goose_bridge.c native/leap_bridge.c native/router_web.cpp native/asus_web.cpp native/commission_ssh.cpp native/host_macos.cpp $(PLATFORM_LIBS) -o $@
	$(call SIGN_BINARY,org.continuum.leap,$@)

leap: $(BUILD)/continuum-leap
	./$(BUILD)/continuum-leap

# Headless leap e2e uses the real executor with fake host/vault and the C++
# wizard in both branches. Enrollment is a capability, not setup readiness:
# commissioning decisions belong to Meta in the main program, not this executor.
$(BUILD)/continuum-leap-test: $(BUILD)/leap_c.o native/goose_bridge.c native/leap_bridge.c native/router_web.cpp native/asus_web.cpp native/asus_commission.h native/commission_ssh.h native/vault.cpp tests/host_fake.cpp tests/commission_host.cpp
	$(CXX) -std=c++20 -O2 $(BUILD)/leap_c.o native/goose_bridge.c native/leap_bridge.c native/router_web.cpp native/asus_web.cpp native/vault.cpp tests/host_fake.cpp tests/commission_host.cpp -o $@

.PHONY: commission-check
$(BUILD)/commission-ssh-check: tests/commission_ssh.cpp native/commission_ssh.cpp native/commission_ssh.h | $(BUILD)
	$(CXX) -std=c++20 -Wall -Wextra -Werror tests/commission_ssh.cpp native/commission_ssh.cpp -o $@

$(BUILD)/commission-keychain-check: tests/commission_keychain.cpp native/asus_web.cpp native/asus_commission.h native/commission_ssh.cpp native/host_macos.cpp native/continuum_native.h | $(BUILD)
	$(CXX) -std=c++20 -Wall -Wextra -Werror tests/commission_keychain.cpp native/asus_web.cpp native/commission_ssh.cpp native/host_macos.cpp -framework Security -framework CoreFoundation -o $@

commission-check: $(BUILD)/continuum-leap-test $(BUILD)/router_double $(BUILD)/commission-ssh-check $(BUILD)/commission-keychain-check
	$(BUILD)/commission-keychain-check
	python3 -c 'import subprocess,uuid; r=subprocess.run(["$(BUILD)/commission-ssh-check", "$(BUILD)/commission-ssh-"+uuid.uuid4().hex]); raise SystemExit(r.returncode)'
	python3 tests/commission_cli.py $(BUILD)/continuum-leap-test $(BUILD)/router_double

leap-e2e: $(BUILD)/continuum-leap-test $(BUILD)/router_double
	@ok=1; \
	for wz in 1 session; do \
	  ROUTER_PASSWORD=test-only-pw ROUTER_WIZARD=$$wz $(BUILD)/router_double 18094 >/dev/null 2>&1 & pid=$$!; \
	  for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -A "OpenAI File Downloader, XaiImageApiFetch/1.0" -o /dev/null http://127.0.0.1:18094/api/status && break; sleep 1; done; \
	  base="ROUTER_HOST=127.0.0.1 ROUTER_PORT=18094 SSID_STEM=LeapLab CONTROL_RIDES_WIFI=0"; \
	  env $$base $(BUILD)/continuum-leap-test > $(BUILD)/leap-e2e.log 2>&1 || ok=0; \
	  grep -q "dry run complete" $(BUILD)/leap-e2e.log || ok=0; \
	  env $$base LEAP_EXECUTE=1 $(BUILD)/continuum-leap-test > $(BUILD)/leap-e2e.log 2>&1; rc=$$?; \
	  [ $$rc = 3 ] || ok=0; \
	  grep -q "OUTCOME Verified" $(BUILD)/leap-e2e.log || ok=0; \
	  grep -q "ENROLLMENT_OK" $(BUILD)/leap-e2e.log || ok=0; \
	  grep -q "INITIAL_SETUP_INCOMPLETE" $(BUILD)/leap-e2e.log || ok=0; \
	  if grep -q "LEAP_OK" $(BUILD)/leap-e2e.log; then ok=0; fi; \
	  if env $$base LEAP_EXECUTE=1 $(BUILD)/continuum-leap-test > $(BUILD)/leap-e2e.log 2>&1; then ok=0; fi; \
	  grep -q "LEAP_FAILED phase=discover" $(BUILD)/leap-e2e.log || ok=0; \
	  kill $$pid 2>/dev/null; wait $$pid 2>/dev/null; \
	done; \
	if [ $$ok = 1 ]; then echo LEAP_E2E_ALL_GREEN; else echo LEAP_E2E_RED "see $(BUILD)/leap-e2e.log"; exit 1; fi

help:
	@echo 'Continuum: a Meta-directed network controller. Goose primary, C++ native boundaries.'
	@echo 'make check         Typecheck the Goose sources'
	@echo 'make sign          Sign/verify production binaries on macOS (MACOS_SIGN_IDENTITY); no router operations'
	@echo 'make signing-check Check stable signing/build policy without credentials or Apple tools'
	@echo 'make tui           Interactive key/models setup, host discovery and bounded Meta investigation'
	@echo 'make setup-check   Real PTY setup/discovery/service-start acceptance; no provider calls or Keychain writes'
	@echo 'make service-check Live host waits/resources, shutdown and authored incident/budget acceptance'
	@echo 'make device-check  Meta-directed setup/dialogue, selected service changes, reboot consent and resident identity acceptance (authored OS/Meta boundaries)'
	@echo 'make measure-check Idle vs loaded RTT and goodput evidence against a live endpoint; refuses a thin sample'
	@echo 'make continuity-check Cross-process commit/resume and stale-output rejection; authored model only'
	@echo 'make status        Build and print implementation status'
	@echo 'make sim           Deterministic sim transcript (no network)'
	@echo 'make daemon        Deterministic daemon transcript (no network, no model calls)'
	@echo 'make loop          Supervised Meta controller + validated Meta task (needs MODEL_API_KEY; synthetic observations)'
	@echo 'make loop-router   Same live entry against the C++ double (needs MODEL_API_KEY; bounded paid calls)'
	@echo 'make router-cli    Tuner commands against the C++ double (status, apply, restore)'
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
