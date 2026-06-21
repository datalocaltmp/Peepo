#pragma once
#include <stdint.h>

void darksword_run(void);
void darksword_cancel(void);

// Reverse the kernel state darksword holds (so_count leak + corrupted icmp6 filter)
// so the app can exit() cleanly instead of panicking on socket teardown.
// UNWIRED: no UI calls this yet (EXIT button removed); kept for a future clean exit.
void darksword_cleanup(void);

// Non-zero once darksword_run() has reached WIN (kernel R/W + base established).
int  darksword_succeeded(void);

typedef struct {
    int32_t  pid;
    uint64_t proc;   // kernel proc address if known (0 for userland-sourced entries)
    char     name[32];
} ds_proc_info_t;

// Enumerate running processes into out[] (up to max). Returns count, or -1 on error.
int peepo_list_processes(ds_proc_info_t *out, int32_t max);

// Dump a target process's mapped memory to Documents/<name>_<pid>.bin (pull via
// `devicectl device copy from`). Records are [u64 va][16KB page] per mapped page.
void peepo_dump_process(uint64_t proc, const char *name);

// Path of the last successful process dump (for the on-watch hex viewer), or NULL.
const char *peepo_last_dump_path(void);

// Dump the live (exact) kernelcache from kernel memory to the app container.
// UNWIRED: DUMP KERNEL button is hidden; re-add a button to use it.
void peepo_dump_kernelcache(void);
