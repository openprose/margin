"""MarginBench tool servers.

Server modules are deliberately not imported here. Prime starts them with
``python -m`` in an isolated runtime, and eager imports would execute the
module once before its server entry point is run.
"""
