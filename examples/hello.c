#include <stdio.h>
#include <assert.h>
#include "libzicl.h"

int main(void) {
    assert(ziclInitGlobals() == 0);
    assert(ziclInitLocalHeap() == 0);

    ZiclInterp *interp = ziclInterpCreate();
    assert(interp);

    const char *script = "set x 40; + $x 2";
    ZiclHandle handle = ziclNewString(script, -1);
    assert(handle._opaque != ZICL_HANDLE_NONE._opaque);

    ZiclReturnCode rc = ziclEvalObject(interp, handle);
    ziclDecrRefCount(handle);
    if (rc != ZICL_OK) {
        fprintf(stderr, "eval failed with code %d\n", rc);
        ziclInterpDestroy(interp);
        ziclDeinitAll();
        return 1;
    }

    const char *result = ziclString(ziclGetResult(interp));
    printf("result: %s\n", result ? result : "(null)");

    ziclInterpDestroy(interp);
    ziclDeinitAll();
    return 0;
}
