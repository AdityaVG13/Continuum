#ifndef CONTINUUM_COMMISSION_SSH_H
#define CONTINUUM_COMMISSION_SSH_H
#include <string>

// Private native boundary, not exported to Goose/model tools. Only the ASUS
// adapter supplies fixed generated programs. Passwords travel over a private
// PTY, never argv/environment. known_hosts is an owner-private regular file;
// first contact uses recorded TOFU, subsequent changed keys are rejected.
struct ct_commission_connection {
    std::string host, source, user, password, known_hosts;
    int port = 22;
};
bool ct_commission_ssh(const ct_commission_connection &connection,
                       const std::string &program, std::string &output,
                       int timeout_seconds, std::string *diagnostic = nullptr);
#endif
