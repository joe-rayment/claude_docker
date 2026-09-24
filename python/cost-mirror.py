#!/usr/bin/env python3
# cost-mirror entry (UserPromptSubmit hook, and the --report /
# --refresh-pricing / --ingest-delegate-receipt commands). The code lives in
# cost_mirror.py: Python caches the bytecode of a module it imports, but
# recompiles a script it runs directly on every call.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import cost_mirror  # noqa: E402

cost_mirror.run()
