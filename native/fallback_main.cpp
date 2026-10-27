#include "continuum_native.h"
#include <iostream>
#include <string_view>

// C++ fallback entrypoint, not a second implementation of the controller.
int main(int argc, char **argv) {
    if (argc > 2 || (argc == 2 && std::string_view(argv[1]) != "--status")) {
        std::cerr << "Usage: continuum-cpp-fallback --status\n";
        return 2;
    }
    ct_handle handle = 0;
    const auto status = ct_meta_open({nullptr, 0}, &handle);
    std::cout << "Continuum C++ fallback: Meta session API not_implemented ("
              << status << "). The request path is ct_meta_request; this entrypoint makes no live call.\n";
    return status == CT_NOT_IMPLEMENTED && handle == 0 ? 0 : 1;
}
