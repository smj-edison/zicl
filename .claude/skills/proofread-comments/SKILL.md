---
name: proofread-comments
description: Proofread comments in the given file(s) against the Style guide in CLAUDE.md
argument-hint: <file or glob>
---

Read CLAUDE.md and extract the "Style guide" section. Then read $ARGUMENTS and proofread every comment against those rules. For each violation, show the file and line number, quote the offending comment, explain which rule it breaks, and suggest a corrected version. Do not flag comments that are already correct.
