# Security Policy

## Supported versions

zigfitsio is pre-1.0: only the most recent release on PyPI receives security fixes.
Older releases are not patched — upgrade to the latest version.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability reporting:

**https://github.com/anhydrous99/zigfitsio/security/advisories/new**

Do **not** open a public issue for a security report.

What to include: the affected version, a minimal reproducing FITS file or code snippet,
and the impact you believe it has (e.g. crash/DoS on untrusted input, out-of-bounds read,
data corruption on write).

You can expect an acknowledgment within 7 days. Fixes ship as a new patch release on PyPI
(published releases are immutable, so fixes always roll forward).

## Scope notes

- The library is designed to parse **untrusted FITS input** without memory unsafety or
  panics; any panic, out-of-bounds access, or unbounded resource consumption reachable
  from a crafted file is in scope.
- The Python bindings (`bindings/python`) cross a C ABI boundary; segfaults reachable
  from Python-level API misuse with attacker-controlled data are in scope.
