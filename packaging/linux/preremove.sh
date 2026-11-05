#!/bin/sh
# Stops starting the helper through systemd before the package's files go.
systemctl --global disable otto.socket >/dev/null 2>&1 || true
