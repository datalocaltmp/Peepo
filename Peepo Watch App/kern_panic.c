//
//  kern_panic.c
//  Peepo Watch App
//
//  Created by datalocaltmp on 2026-01-21.
//
//  Console-logging plumbing used by darksword (printf -> sharedConsole bridge).
//  (The old kern_stuff()/kern_panic() KERNEL-FUN panic tests were removed.)

#include "kern_panic.h"
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

void sleep_ms(uint64_t ms) {
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000ULL;
    nanosleep(&ts, NULL);
}
