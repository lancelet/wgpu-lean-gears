// Process entry for both targets. Initialises the Lean runtime and every
// imported module, then runs `gearsMain` on *this* thread (see Main.lean).
#include <lean/lean.h>

lean_object* initialize_gears_Main(uint8_t builtin);
lean_object* gears_main(void);

int main(int argc, char** argv) {
  (void)argc; (void)argv;
  lean_object* res = initialize_gears_Main(1 /* builtin */);
  lean_io_mark_end_initialization();
  if (lean_io_result_is_ok(res)) {
    lean_dec_ref(res);
    lean_init_task_manager();
    res = gears_main();
  }
  int ok = lean_io_result_is_ok(res);
  if (!ok) lean_io_result_show_error(res);
  lean_dec_ref(res);
  return ok ? 0 : 1;
}
