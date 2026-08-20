---
name: index-helpers
description: Scan utility files for public helper functions and update .claude/helpers.md so future sessions know about them
---

Scan every file matching `src/*.zig` for public helper functions (`pub fn`), except files under `src/commands/*.zig` -- with one exception: also scan `src/commands/common.zig`.

For each file, read it and collect every `pub fn` declaration along with its signature and a one-line description of what it does (inferred from the doc comment if present, otherwise from the implementation).

Then read `.claude/helpers.md` if it exists, and compare against the functions already listed there. Add any functions that are missing. If a listed function no longer exists under its old name (renamed or moved), fix that entry in place rather than leaving it stale; if a documented file no longer exists at all, remove its section. Otherwise, don't rewrite or reorganize existing entries, only append new ones.

If `.claude/helpers.md` does not exist yet, create it with this header:

```
# Helper function index

Public helper functions in the utility files. Consult this before implementing
anything that might already exist.
```

Finally, if CLAUDE.md does not already mention `.claude/helpers.md`, add a line to its "Key Files" section pointing to it.
