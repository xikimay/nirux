#include "NiruxTestBootstrap.h"

// Before any test, with or without --filter: dyld runs this on the main
// thread as xctest loads the test bundle, which links this target.
__attribute__((constructor)) static void NiruxTestBootstrapLoad(void) {
    NiruxTestBootstrapDidLoad();
}
