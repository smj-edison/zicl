---
name: find-repetition
description: Scan file(s) for repeated code patterns and suggest functions to encapsulate them
argument-hint: <file or glob>
---

Scan $ARGUMENTS for two kinds of issues:

## 1. Repeated constructs worth extracting

For each pattern found, show the locations where it appears, explain what the shared logic is doing, and suggest a function signature that would encapsulate it. Only flag repetition that is genuinely worth extracting -- three or more occurrences, or two that are complex enough that a helper would meaningfully reduce the maintenance surface. Do not suggest abstractions for simple one-liners or cases where the repetition is coincidental rather than structural.

## 2. Manual implementations of existing helpers

Read `.claude/helpers.md` first. Then scan the target files for code that manually implements logic already covered by a helper in the index. For each instance found, cite the helper from `.claude/helpers.md` that should replace it and show a before/after sketch.

Common patterns to watch for in this codebase:

- **Shimmer boilerplate** -- Code that does `var new: OptionalHandle = .none; try shimmerToX(...); handle.swapIfNew(new);` when an in-place wrapper like `getInteger`, `getFloat`, `getBoolean`, `getIndex`, `shimmerToList`, `getListLength`, `getCodepointLength`, or `resolveHash` already exists on `Interp`.
- **Dict access patterns** -- Manual key lookups followed by `dictLookupFollowRefs` or `dictGetTable` when `Interp.getDictValue`, `getDictValueOrError`, `getDictValueRecursively`, `getDictValueRecursivelyOrError`, `putDictValue`, `putDictValueRecursively`, `removeDictValue`, `removeDictValueRecursively`, `getDictValueInPlace`, or `putDictValueInPlace` would handle the shimmer and error plumbing.
- **List construction** -- `createObject` + manual field initialization when `newList`, `newListWithCapacity`, or `listAppendAssumeCapacity` would suffice.
- **String allocation** -- `createString` + `setNormalString` when `newString`, `newStringFmt`, `newStringToFill`, or `setStringOwning` would work.
- **Ref-count dance** -- Manual `incrRefCount`/`decrRefCount` pairs when `borrow()`, `dupOrRef()`, `reference()`, or `referenceTakeOwnership()` express the intent more directly.
- **Error-details plumbing** -- Creating a local `ErrorDetails` and passing it through multiple layers when `interp.wrapError` or `interp.wrapShimmerFn` could collapse the boilerplate.
- **Range/index resolution** -- Manual index arithmetic when `Heap.ListIndex.asAbsoluteIndex`, `Range.fromIndexes`, `getRange`, or `getRangeInPlace` already exists.
- **Expression evaluation** -- Manual tokenization or AST walking when `evalExpression`, `evalExpressionInPlace`, or `getBoolFromExpression` should be used.
- **Scope capture** -- Manual dict construction from call frames when `captureScope` or `captureCurrentScope` already does it.

When reporting a subsumed pattern, include:
1. The helper name from `.claude/helpers.md`.
2. The file and line range of the manual implementation.
3. A one-line explanation of what the manual code is doing.
4. A brief replacement sketch showing how the helper simplifies it.

Be conservative: only flag cases where the replacement is clearly equivalent and actually shorter or clearer. Do not suggest replacing code that uses the helper's internals intentionally or that has subtle behavioral differences.
