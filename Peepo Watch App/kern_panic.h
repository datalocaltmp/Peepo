//
//  kern_panic.h
//  Peepo Watch App
//
//  Created by Luke on 2026-01-21.
//

#ifndef kern_panic_h
#define kern_panic_h

#include <stdio.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*console_log_cb_t)(const char *msg);

void set_console_logger(console_log_cb_t cb);
void console_log(const char *msg);
static void sleep_ms(uint64_t ms);

int kern_stuff();

#endif /* kern_panic_h */
