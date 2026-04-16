---
name: find-repetition
description: Scan file(s) for repeated code patterns and suggest functions to encapsulate them
argument-hint: <file or glob>
---

Scan $ARGUMENTS for repeated code patterns. For each pattern found, show the locations where it appears, explain what the shared logic is doing, and suggest a function signature that would encapsulate it. Only flag repetition that is genuinely worth extracting — three or more occurrences, or two that are complex enough that a helper would meaningfully reduce the maintenance surface. Do not suggest abstractions for simple one-liners or cases where the repetition is coincidental rather than structural.

Additionally, look for areas of the code that manually implement helper functions that exist now, and suggest what helper function would be appropriate to replace the manually done code with.
