#include <stdio.h>
#include <assert.h>
#include "libzicl.h"

int main(void) {
    assert(Zicl_InitGlobals() == 0);
    assert(Zicl_InitLocalHeap() == 0);

    Zicl_Interp *interp = Zicl_CreateInterp();
    assert(interp);

    const char *script = "set x 40; + $x 2";
    Zicl_Handle handle = Zicl_NewString(script, -1);
    assert(handle);

    int rc = Zicl_EvalObject(interp, handle);
    Zicl_DecrRefCount(handle);
    if (rc != ZICL_OK) goto err;

    const char *result = Zicl_String(Zicl_GetResult(interp));
    printf("result: %s\n", result ? result : "(null)");

    Zicl_InterpDestroy(interp);
    Zicl_DeinitAll();
    return 0;

err:
    fprintf(stderr, "eval failed with code %d\n", rc);
    Zicl_InterpDestroy(interp);
    Zicl_DeinitAll();
    return 1;
}
