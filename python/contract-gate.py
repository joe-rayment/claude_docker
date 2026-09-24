#!/usr/bin/env python3
# contract-gate hook entry. The code lives in contract_gate.py: Python caches the bytecode
# of a module it imports, but recompiles a script it runs directly on
# every call.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import contract_gate  # noqa: E402

contract_gate.run()
