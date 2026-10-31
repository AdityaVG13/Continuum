// Continuum native inspection interface
#ifndef CONTINUUM_INSPECT_H
#define CONTINUUM_INSPECT_H

#include "continuum_native.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef CN_API
#define CN_API
#endif

// Read-only topology/traffic inspection for agent-aware optimization
CN_API int cn_inspect_qdisc(const char *path_id, char *out_json, int out_json_cap);
CN_API int cn_inspect_net(const char *path_id, char *out_json, int out_json_cap);
CN_API int cn_inspect_proc(const char *path_id, char *out_json, int out_json_cap);
CN_API int cn_discover_full(const char *path_id, const char *scope_id, char *out_json, int out_json_cap);

#ifdef __cplusplus
}
#endif

#endif
