"""Whether a canary run ended infra_unavailable, read from its verdict files.

canary.yml passes exit 2 as inconclusive only when this says so, so a run
that never started (bad arguments, no evidence) can't read as green.

  verdicts.py infra <file name> <field> <evidence dir>
"""

import json
import sys
from pathlib import Path

INFRA = "infra_unavailable"


def any_infra(root, name, field):
    """True when some verdict file says infra_unavailable; False without any file."""
    return any(json.loads(path.read_text(encoding="utf-8")).get(field) == INFRA for path in Path(root).rglob(name))


if __name__ == "__main__":
    if len(sys.argv) != 5 or sys.argv[1] != "infra":
        sys.exit(__doc__)
    sys.exit(0 if any_infra(sys.argv[4], sys.argv[2], sys.argv[3]) else 1)
