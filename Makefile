GOOSE ?= goose
CXX ?= c++
BUILD := .build
export GOOSE_HOME := $(abspath $(BUILD)/goose-cache)

.PHONY: all check status sim daemon test web-e2e web-e2e-run meta-live native-check cpp-status help clean

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

# Manual end-to-end: Goose loop -> C++ transport -> virtual router.
# Needs a live lab/router_server.py and ROUTER_* in the environment, e.g.
#   ROUTER_PASSWORD='<pw>' python3 lab/router_server.py 18081   # on the lab host
#   ROUTER_HOST=<lab> ROUTER_PORT=18081 ROUTER_PASSWORD='<pw>' make web-e2e-run
$(BUILD)/web_e2e.c: tests/router_web_e2e.goose $(wildcard src/*.goose) | $(BUILD)
	$(GOOSE) -o $@ --standalone tests/router_web_e2e.goose

# The emitted C is C, not C++ (exact-fit string initializers), so it gets
# its own object from the C driver; the bridge and transport link as C++.
$(BUILD)/web_e2e_c.o: $(BUILD)/web_e2e.c
	$(CC) -O2 -c $< -o $@

$(BUILD)/web_e2e: $(BUILD)/web_e2e_c.o native/goose_bridge.c native/router_web.cpp
	$(CXX) -O2 $(BUILD)/web_e2e_c.o native/goose_bridge.c native/router_web.cpp -o $@

web-e2e: $(BUILD)/web_e2e

web-e2e-run: $(BUILD)/web_e2e
	ROUTER_HOST=$${ROUTER_HOST:-127.0.0.1} \
	ROUTER_PORT=$${ROUTER_PORT:-18081} \
	$(BUILD)/web_e2e

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
	$(CC) -Wall -Wextra -Werror -fsyntax-only native/goose_bridge.c

$(BUILD)/continuum-cpp-fallback: native/continuum_native.h native/continuum_native_stub.cpp native/fallback_main.cpp | $(BUILD)
	$(CXX) -std=c++20 -Wall -Wextra -Werror native/continuum_native_stub.cpp native/fallback_main.cpp -o $@

cpp-status: $(BUILD)/continuum-cpp-fallback
	./$(BUILD)/continuum-cpp-fallback --status

help:
	@echo 'Continuum: a Meta-directed network controller. Goose primary, C++ native boundaries.'
	@echo 'make check         Typecheck the Goose sources'
	@echo 'make status        Build and print implementation status'
	@echo 'make sim           Deterministic sim transcript (no network)'
	@echo 'make daemon        Deterministic daemon transcript (no network, no model calls)'
	@echo 'make test          Goose contract suites (sim-only, no network)'
	@echo 'make web-e2e       Build the Goose->C++->router loop binary (needs lab server to run)'
	@echo 'make web-e2e-run   Run it against ROUTER_HOST/ROUTER_PORT/ROUTER_PASSWORD'
	@echo 'make meta-live     One bounded Meta round trip (needs MODEL_API_KEY; fails closed without)'
	@echo 'make native-check  Syntax-check the C++ native sources'
	@echo 'make cpp-status    Build and print C++ fallback status'
	@echo 'Set GOOSE=/absolute/path/to/goose for the pinned v2026.3 compiler.'

clean:
	rm -rf $(BUILD)
