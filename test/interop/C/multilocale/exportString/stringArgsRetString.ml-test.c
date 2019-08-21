#include "lib/TestLibrary.h"

int main(int argc, char** argv) {
  chpl_library_init(argc, argv);
  char* msg = stringArgsRetString("Greetings", ", computer!");
  printf("%s\n", msg);
  free(msg);
  chpl_library_finalize();
  return 0;
}
