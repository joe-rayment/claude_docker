#!/usr/bin/env python3
# delegation-gate hook entry. The code lives in delegation_gate.py: Python caches the bytecode
# of a module it imports, but recompiles a script it runs directly on
# every call.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import delegation_gate  # noqa: E402

delegation_gate.run()
