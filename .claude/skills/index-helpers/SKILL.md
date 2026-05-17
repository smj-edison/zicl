---
name: index-helpers
description: Scan utility files for public helper functions and update .claude/helpers.md so future sessions know about them
---

Scan the following files for public helper functions (`pub fn`):
- src/objutil.zig
- src/Heap.zig
- src/memutil.zig
- src/strutil.zig
- src/Interp.zig

For each file, read it and collect every `pub fn` declaration along with its signature and a one-line description of what it does (inferred from the doc comment if present, otherwise from the implementation).

Then read `.claude/helpers.md` if it exists, and compare against the functions already listed there. Add any functions that are missing — do not remove or rewrite existing entries, only append new ones.

If `.claude/helpers.md` does not exist yet, create it with this header:

```
# Helper function index

Public helper functions in the utility files. Consult this before implementing
anything that might already exist.
```

Finally, if CLAUDE.md does not already mention `.claude/helpers.md`, add a line to its "Key Files" section pointing to it.
