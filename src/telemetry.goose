import .contracts;
import .sim;
namespace continuum;

// TODO M03: collect bounded timestamped windows from gateway, remote echo,
// application timing and workload context; classify missing measurements as
// unknown rather than zero. Use a monotonic run clock and explicit route epoch.
// TODO M03: populate the supplied record only after collection and validation.
// This separate output shape makes absence explicit at the boundary.
struct ObservationResult { outcome: Outcome = Outcome {}, observation: Observation = Observation {} }

fn read_observation(path_id: const u8[:]) -> ObservationResult {
    // Use sim observations for lab-sim path; fall back to sim
    if path_id == "sim0" || path_id == "lab-sim" {
        let obs = sim_observe("sim0", 0);
        return ObservationResult { outcome: obs.outcome, observation: obs.observation };
    }
    if path_id.len == 0 {
        let obs = sim_observe("sim0", 0);
        return ObservationResult { outcome: obs.outcome, observation: obs.observation };
    }
    return ObservationResult { outcome: Outcome { status: Status.Failed, message: "read_observation: unknown path" } };
}
