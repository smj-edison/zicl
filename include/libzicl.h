#pragma once

#include <stdint.h>

/* Opaque handle to a heap object. ZICL_HANDLE_NONE (zero) is the null sentinel. */
typedef uint64_t Zicl_Handle;
#define ZICL_NULL_HANDLE ((Zicl_Handle)0)

#define ZICL_OK 0
#define ZICL_ERR 1
#define ZICL_RETURN 2
#define ZICL_BREAK 3
#define ZICL_CONTINUE 4
#define ZICL_SIGNAL 5
#define ZICL_EXIT 6
#define ZICL_OOM 7

typedef struct Zicl_Interp Zicl_Interp;

typedef int (*Zicl_CCommandFn)(Zicl_Interp *interp, int argc, Zicl_Handle *argv);

void Zicl_SetGlobalStdout(int fd);
void Zicl_SetGlobalStderr(int fd);

int Zicl_InitGlobals(void);
int Zicl_InitLocalHeap(void);
void Zicl_DeinitAll(void);
void Zicl_LeakCheckAll(void);

Zicl_Interp *Zicl_CreateInterp(void);
void Zicl_InterpDestroy(Zicl_Interp *interp);

Zicl_Handle Zicl_NewString(const char *ptr, int len);
const char *Zicl_String(Zicl_Handle object);
const char *Zicl_GetString(Zicl_Handle object, int *len);
void Zicl_DecrRefCount(Zicl_Handle handle);

/* Number functions */
int Zicl_GetLong(Zicl_Interp *interp, Zicl_Handle *handle, long *out);
int Zicl_GetDouble(Zicl_Interp *interp, Zicl_Handle *handle, double *out);
int Zicl_GetBoolean(Zicl_Interp *interp, Zicl_Handle *handle, int *out);

/* List functions */
Zicl_Handle Zicl_NewList(Zicl_Handle *handles, int n_handles);
int Zicl_ListLength(Zicl_Interp *interp, Zicl_Handle *list);
int Zicl_ListAppend(Zicl_Interp *interp, Zicl_Handle *list, Zicl_Handle item);
Zicl_Handle Zicl_ListGetItem(Zicl_Handle list, uint32_t index);

/* Dict functions */
Zicl_Handle Zicl_NewDict(Zicl_Handle *handles, int n_handles);
int Zicl_DictPut(Zicl_Interp *interp, Zicl_Handle *dict, Zicl_Handle key, Zicl_Handle value);

/* Source functions */
const char *Zicl_SourceGetFilename(Zicl_Handle source);
int Zicl_SourceGetLine(Zicl_Handle source);
int Zicl_SourceSetInfo(Zicl_Handle handle, const char *filename, int line_no);

/* Interpreter functions */
int Zicl_CreateCommand(Zicl_Interp *interp, const char *name, Zicl_CCommandFn command);
int Zicl_EvalObject(Zicl_Interp *interp, Zicl_Handle script);
int Zicl_EvalFile(Zicl_Interp *interp, const char *filename);
Zicl_Handle Zicl_GetResult(Zicl_Interp *interp);
void Zicl_SetResult(Zicl_Interp *interp, Zicl_Handle handle);
void Zicl_SetResultOwning(Zicl_Interp *interp, Zicl_Handle handle);
int Zicl_SetVariable(Zicl_Interp *interp, Zicl_Handle *name, Zicl_Handle handle);
int Zicl_SetResultString(Zicl_Interp *interp, const char *str, int len);
int Zicl_SetResultBool(Zicl_Interp *interp, int value);
int Zicl_SetResultInt(Zicl_Interp *interp, long value);
void Zicl_SetEmptyResult(Zicl_Interp *interp);
int Zicl_MakeErrorMessage(Zicl_Interp *interp);
void Zicl_IncrSignalDepth(Zicl_Interp *interp);
void Zicl_DecrSignalDepth(Zicl_Interp *interp);
uint64_t Zicl_GetSigmask(Zicl_Interp *interp);
Zicl_Handle Zicl_GetScriptBeingEvaluated(Zicl_Interp *interp);

