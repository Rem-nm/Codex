"""REM Web Panel support package.

The first Web Panel slice is deliberately read-only.  It exposes a small
business API through a root-owned Unix-socket Manager Core and keeps the HTTP
process unprivileged.  Protocol credentials remain in the existing manager
state and are never read by the HTTP process.
"""
