// Library entry for the Continuum program: importing this file loads every
// module exactly once. Product code enters through main.goose; test roots
// under tests/ enter through here (`import lib from "../src";`) because
// Goose file-relative imports cannot climb out of tests/ with `..`.
// Namespace qualification (continuum::X) is unaffected by the entry used.
import .contracts;
import .meta_provider;
import .telemetry;
import .guardian;
import .actuator;
import .task_runner;
import .events;
import .transport;
import .controller;
import .sim;
import .policy;
import .store;
import .router;
import .daemon;
import .router_web;
import .tooljson;
import .workload;
import .meta_shape;
