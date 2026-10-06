#!/usr/bin/env python3
"""Prints the SHA-1 of the valid code signing identity of a kind (e.g. "Developer ID Application") whose certificate expires last."""
import re
import subprocess
import sys

kind = sys.argv[1]
listed = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
valid = set(re.findall(r'\) ([0-9A-F]{40}) "' + re.escape(kind), listed))
dump = subprocess.run(["security", "find-certificate", "-a", "-Z", "-p", "-c", kind], capture_output=True, text=True).stdout
best = None
for sha1, pem in re.findall(r"SHA-1 hash: ([0-9A-F]{40}).*?(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)", dump, re.S):
    if sha1 not in valid:
        continue
    end = subprocess.run(["openssl", "x509", "-noout", "-enddate", "-dateopt", "iso_8601"], input=pem, capture_output=True, text=True).stdout.strip().split("=", 1)[1]
    if best is None or end > best[1]:
        best = (sha1, end)
print(best[0] if best else "")
