#pragma once

#include <stdint.h>

/* Opaque handle to a heap object. ZICL_HANDLE_NONE (zero) is the null sentinel. */
typedef struct
{
    uint64_t _opaque;
} ZiclHandle;
#define ZICL_HANDLE_NONE ((ZiclHandle){0})

typedef enum ZiclReturnCode
{
    ZICL_OK = 0,
    ZICL_ERROR = 1,
    ZICL_RETURN = 2,
    ZICL_BREAK = 3,
    ZICL_CONTINUE = 4,
    ZICL_SIGNAL = 5,
    ZICL_EXIT = 6,
    ZICL_OOM = 7,
} ZiclReturnCode;

typedef struct ZiclInterp ZiclInterp;

int ziclInitGlobals(void);
int ziclInitLocalHeap(void);
void ziclDeinitAll(void);

ZiclInterp *ziclInterpCreate(void);
void ziclInterpDestroy(ZiclInterp *interp);

ZiclHandle ziclNewString(const char *ptr, int len);
const char *ziclString(ZiclHandle object);
void ziclDecrRefCount(ZiclHandle handle);

ZiclReturnCode ziclEvalObject(ZiclInterp *interp, ZiclHandle script);
ZiclHandle ziclGetResult(ZiclInterp *interp);
