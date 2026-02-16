# Upvar, Dict Sugar, and Variable Caching in Jim Tcl

Reference implementation: jimtcl (`jim.c`)

## Core Data Structures

### Jim_VarVal (jim.h:478-482)

The variable value container. Dual-purpose:

- **Normal variable:** `objPtr` holds the actual value, `linkFramePtr` is NULL.
- **Upvar link:** `objPtr` holds the **name** of the target variable (as a string object), `linkFramePtr` points to the target call frame.

```c
typedef struct Jim_VarVal {
    Jim_Obj *objPtr;
    struct Jim_CallFrame *linkFramePtr;
    int refCount;
} Jim_VarVal;
```

### Variable Name Object Cache (jim.h:321-326)

Any `Jim_Obj` used as a variable name can shimmer to `variableObjType`, caching:

- `vv`: Direct pointer to the resolved `Jim_VarVal`
- `callFrameId`: The frame's epoch at resolution time (for cache validation)
- `global`: Whether the name was `::` prefixed

### Dict Sugar Object (jim.h:357-360)

A `Jim_Obj` with type `dictSubstObjType` stores:

- `varNameObjPtr`: The variable name part (e.g., `"local"`)
- `indexObjPtr`: The key part (e.g., `"key"`)

## Variable Storage

Variables live in `CallFrame->vars`, a hash table where:

- **Key:** `Jim_Obj*` (variable name, matched by string)
- **Value:** `Jim_VarVal*`

The cached `Jim_VarVal*` stored in a name object's internalRep is a **shortcut pointer**
to the same struct stored as the hash table value. Both point to the same allocation.

## Epoch Caching

### Mechanism

Each `Jim_CallFrame` has a unique `id` from `interp->callFrameEpoch`. When a
variable name is resolved, the name object caches the `Jim_VarVal*` alongside the
frame's current `id`.

On subsequent access, `SetVariableFromAny` (jim.c:4561-4566) checks whether the
cached `callFrameId` still matches the frame's current `id`. If it matches, the
cached `Jim_VarVal*` is used directly, skipping the hash lookup.

### Invalidation

Any successful `unset` in a frame bumps that frame's epoch (jim.c:4983):

```c
framePtr->id = interp->callFrameEpoch++;
```

This invalidates **all** cached variable lookups for that frame, not just the
unset variable. On next access, every variable name targeting that frame must
re-resolve via hash lookup (`JimFindVariable` at jim.c:4596).

## Upvar Implementation

### Link Creation (jim.c:4844-4848)

`Jim_SetVariableLink` creates the link by:

1. Calling `Jim_SetVariable(interp, localName, targetName)` -- stores the target
   variable's **name** as if it were the value.
2. Setting `vv->linkFramePtr = targetCallFrame` on the resulting `Jim_VarVal`.

The target name becomes an **isolated object** -- it's not a hash key anywhere,
it's just stored in the `Jim_VarVal.objPtr` field. Despite being isolated, it can
still shimmer to `variableObjType` and cache its own resolution.

### Link Following

`Jim_GetVariable` (jim.c:4871-4884) and `Jim_SetVariable` (jim.c:4701-4713) both
check `linkFramePtr`. When non-NULL:

1. Save `interp->framePtr`
2. Switch to `vv->linkFramePtr`
3. Recursively call themselves with `vv->objPtr` (the target variable name)
4. Restore `interp->framePtr`

This is fully recursive -- upvar chains of any depth are followed.

### Constraint: No Dict Sugar in Local Name

`Jim_SetVariableLink` (jim.c:4770-4774) rejects dict sugar syntax in the **local**
variable name. `upvar foreignvar local(key)` is an error. The target name has no
such restriction.

## Dict Sugar Implementation

### Detection (jim.c:4576-4578)

`SetVariableFromAny` checks if a variable name ends with `)` and contains `(`.
If so, it returns the special code `JIM_DICT_SUGAR` instead of resolving the variable.

### Get: `$var(key)`

1. `JimDictSugarGet` (jim.c:5097) parses the name into variable and key parts.
2. `JimDictExpandArrayVariable` calls `Jim_GetVariable` with just the variable
   name part (e.g., `"local"`).
3. Calls `Jim_DictKey` to look up the key in the returned dict value.

### Set: `set var(key) val`

1. `JimDictSugarSet` (jim.c:5035) parses the name into variable and key parts.
2. Calls `Jim_SetDictKeysVector` (jim.c:8029), which:
   a. **Gets** the current dict via `Jim_GetVariable` (follows upvar if needed)
   b. Duplicates if shared (`Jim_IsShared`)
   c. Modifies the dict with `Jim_DictAddElement`
   d. **Sets** the modified dict back via `Jim_SetVariable` (follows upvar again)

### Unset: `unset var(key)`

`Jim_UnsetVariable` (jim.c:4949-4951) detects dict sugar and delegates to
`JimDictSugarSet` with a NULL value.

## Upvar + Dict Sugar Interaction

Dict sugar and upvar operate at **different levels**:

- Dict sugar is syntactic: it splits `local(key)` into a variable name and a key.
- Upvar is resolved when that variable name is looked up.

When accessing `$local(key)` where `local` is upvar'd:

1. Dict sugar splits into `var="local"`, `key="key"`
2. `Jim_GetVariable("local")` follows the upvar link to the target frame
3. Returns the dict from the target frame
4. Key is looked up in that dict

When setting `set local(key) val`:

1. Dict sugar splits, then `Jim_SetDictKeysVector` is called
2. It **gets** the dict via `Jim_GetVariable("local")` -- upvar followed
3. Modifies the dict
4. **Sets** back via `Jim_SetVariable("local", ...)` -- upvar followed again
5. The modified dict is written to the target frame

## Edge Cases

### Unset Through Upvar

`unset local` where `local` is upvar'd (jim.c:4957-4961):

- Follows the link and unsets the **target** variable.
- Bumps the **target** frame's epoch, not the local frame's.
- The local link `Jim_VarVal` is **NOT removed** from the local frame's hash table.
  It becomes a dangling link (target no longer exists).

### Set After Unset Through Upvar

`set local val` after the target was unset through the link:

- `SetVariableFromAny("local")` succeeds (link still in local hash table).
- Follows the link to the target frame.
- Recursive `Jim_SetVariable` on the target name finds it missing (`JIM_ERR`).
- Falls through to `JimCreateVariable` (jim.c:4694), **recreating** the variable
  in the target frame.

### Upvar Chain Caching

For an upvar→upvar chain (e.g., `z` → `y` → `x` → value), each link's target
name is an isolated `Jim_Obj*` stored in `Jim_VarVal.objPtr`. Each of these
isolated name objects can independently cache its resolution.

A 2-link chain has 3 potentially cached lookups, each validated against a
different frame's epoch:

- `"z"` cached against frame C's epoch
- `"y"` (isolated, in VarVal) cached against frame B's epoch
- `"x"` (isolated, in VarVal) cached against frame A's epoch

An epoch bump in any single frame only invalidates caches targeting that frame.

### Unset of Unrelated Variable Invalidates All Local Caches

Because `unset` bumps the **entire frame's** epoch (jim.c:4983), unsetting any
variable in a frame invalidates cached lookups for **every** variable in that
frame. The `Jim_VarVal` structs remain in the hash table; only the shortcut
cache in name objects is invalidated, forcing a hash re-lookup on next access.