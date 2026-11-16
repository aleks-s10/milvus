//go:build with_jemalloc && linux
// +build with_jemalloc,linux

#include "cgomemprof.h"
#include <stdbool.h>
#include <stdlib.h>
#include <dlfcn.h>
#include "backtrace.h"

extern struct backtrace_state* cgoBacktraceState;

#ifndef RTLD_DEFAULT
#define RTLD_DEFAULT ((void*)0)
#endif

int EnableMemoryProfiling() {
  bool enable = true;
  return mallctl("prof.active", NULL, NULL, &enable, sizeof(enable));
}

int DisableMemoryProfiling() {
  bool enable = false;
  return mallctl("prof.active", NULL, NULL, &enable, sizeof(enable));
}

int DumpMemoryProfileIntoFile(const char *filename) {
  return mallctl("prof.dump", NULL, NULL, &filename, sizeof(const char *));
}

int DumpStatsIntoFile(const char *filename, const char* opts) {
    FILE *file = fopen(filename, "w");
    if (file == NULL) {
        return -1;
    }
    int code = malloc_stats_print((void (*)(void *, const char *))fprintf, file, opts);
    if (code != 0) {
        fclose(file);
        return code;
    }
    fclose(file);
    return 0;
}

void syminfoCallback(void *data, uintptr_t pc, const char *symname, uintptr_t symval, uintptr_t symsize) {
    char* buf = (char*)data;
    if (symname != NULL) {
        snprintf(buf, 4096, "0x%lx\t%s",pc, symname);
    } else {
        snprintf(buf, 4096, "0x%lx\t??", pc);
    }
}

void errorCallback(void *data, const char *msg, int errnum) {
    fprintf(stderr, "Error: %s (code: %d)\n", msg, errnum);
}

char* GetSymbol(uintptr_t addr) {
    char* buf = malloc(4096);
    backtrace_syminfo(cgoBacktraceState, addr, syminfoCallback, errorCallback, buf);
    return buf;
}

int IsJemallocProfEnabled() {
    bool enabled = false;
    size_t size = sizeof(enabled);
    int code = mallctl("opt.prof", &enabled, &size, NULL, 0);
    if (code != 0) {
        fprintf(stderr, "mallctl failed with code: %d\n", code);
        return -1;
    }
    return enabled ? 1 : 0;
}

int IsJemallocStatsEnabled() {
    bool enabled = false;
    size_t size = sizeof(enabled);
    int code = mallctl("config.stats", &enabled, &size, NULL, 0);
    if (code != 0) {
        fprintf(stderr, "mallctl failed with code: %d\n", code);
        return -1;
    }
    return enabled ? 1 : 0;
}

size_t GetAllocatedMemory() {
    size_t allocated = 0;
    size_t size = sizeof(size_t);
    if (mallctl("stats.allocated", &allocated, &size, NULL, 0) != 0) {
        return 0;
    }
    return allocated;
}

size_t GetActiveMemory() {
    size_t active = 0;
    size_t size = sizeof(size_t);
    if (mallctl("stats.active", &active, &size, NULL, 0) != 0) {
        return 0;
    }
    return active;
}

size_t GetMetadataMemory() {
    size_t metadata = 0;
    size_t size = sizeof(size_t);
    if (mallctl("stats.metadata", &metadata, &size, NULL, 0) != 0) {
        return -1;
    }
    return metadata;
}

size_t GetMetadataThpMemory() {
    size_t metadata_thp = 0;
    size_t size = sizeof(size_t);
    if (mallctl("stats.metadata_thp", &metadata_thp, &size, NULL, 0) != 0) {
        return 0;
    }
    return metadata_thp;
}

size_t GetResidentMemory() {
    size_t resident = 0;
    size_t size = sizeof(size_t);
    if (mallctl("stats.resident", &resident, &size, NULL, 0) != 0) {
        return 0;
    }
    return resident;
}

size_t GetMappedMemory() {
    size_t mapped = 0;
    size_t size = sizeof(size_t);
    if (mallctl("stats.mapped", &mapped, &size, NULL, 0) != 0) {
        return 0;
    }
    return mapped;
}

size_t GetRetainedMemory() {
    size_t retained = 0;
    size_t size = sizeof(size_t);
    if (mallctl("stats.retained", &retained, &size, NULL, 0) != 0) {
        return -1;
    }
    return retained;
}

size_t GetZeroReallocs() {
    size_t zero_reallocs = 0;
    size_t size = sizeof(size_t);
    if (mallctl("stats.zero_reallocs", &zero_reallocs, &size, NULL, 0) != 0) {
        return 0;
    }
    return zero_reallocs;
}

size_t GetBackgroundThreadNumThreads() {
    size_t num_threads = 0;
    size_t size = sizeof(size_t);
    if (mallctl("stats.background_thread.num_threads", &num_threads, &size, NULL, 0) != 0) {
        return 0;
    }
    return num_threads;
}

size_t GetBackgroundThreadNumRuns() {
    size_t num_runs = 0;
    size_t size = sizeof(size_t);
    if (mallctl("stats.background_thread.num_runs", &num_runs, &size, NULL, 0) != 0) {
        return 0;
    }
    return num_runs;
}

size_t GetBackgroundThreadRunInterval() {
    size_t run_interval = 0;
    size_t size = sizeof(size_t);
    if (mallctl("stats.background_thread.run_interval", &run_interval, &size, NULL, 0) != 0) {
        return 0;
    }
    return run_interval;
}