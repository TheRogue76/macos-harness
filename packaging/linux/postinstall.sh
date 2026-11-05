#!/bin/sh
# Starts the helper for every user through systemd's socket activation, from their next login.
systemctl --global enable otto.socket >/dev/null 2>&1 || true
