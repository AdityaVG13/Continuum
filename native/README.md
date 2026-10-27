# Native boundaries and C++ fallback

This directory holds the C ABI plus its adapters. The primary implementation language is [aardappel/Goose](https://github.com/aardappel/goose); C++ is the native integration and whole-program fallback language if a specific integration gate fails.

`continuum_native.h` declares byte-oriented C ABI boundaries for HTTPS, observations, an owned-profile helper/watchdog and optional object transfer. `router_web.cpp` implements the router profile calls over stock HTTP; `meta_web.cpp` implements the Meta request call over TLS via a system curl child. `continuum_native_stub.cpp` returns `CT_NOT_IMPLEMENTED` from every operation the adapters do not yet cover. `fallback_main.cpp` prints that status. `goose_bridge.c` reframes Goose slice layouts onto the ABI spans without copying. None of this contacts a production router or a provider on its own: the router adapter talks to an explicitly configured host, and the Meta adapter only runs when the Goose side submits a validated request.

Before replacing a stub, settle exact schema versions and error mapping, bound every input and queue, verify ABI layout against the pinned Goose compiler, copy any payload retained asynchronously, and specify cancel/close lifetime. Native callbacks enqueue data for the owning Goose thread. They do not enter the Goose runtime from arbitrary callback threads.

The HTTPS adapter and privileged profile helper have separate authority. Receiving model-generated text does not grant shell access. The watchdog must eventually be an independent process with durable owned-state recovery.

Each adapter parses its bounded JSON subset with a minimal strict reader and maps transport outcomes to explicit status codes (router 401 to `CT_REJECTED`, unreachable/timeout/garbage to `CT_FAILED`); transport errors never claim success. `make native-check` checks that the C++ sources parse. `make cpp-status` builds and runs the C++ fallback status entrypoint. Neither command validates a live integration; the Goose suites and the manual probes do that.
