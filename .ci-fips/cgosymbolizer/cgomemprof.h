#include <stddef.h>
#include "backtrace.h"

#ifndef CGOMEMPROF_H
#define CGOMEMPROF_H

// EnableMemoryProfiling enables memory profiling.
int EnableMemoryProfiling();

// DisableMemoryProfiling disables memory profiling.
int DisableMemoryProfiling();

// DumpMemoryProfileIntoFile dumps the memory profile into the specified
// filename.
int DumpMemoryProfileIntoFile(const char *filename);

// DumpStatsIntoFile dumps the memory statistics into the specified filename.
int DumpStatsIntoFile(const char *filename, const char* opts);

char*  GetSymbol(uintptr_t addr);

// implemet by jemalloc
extern int mallctl(const char *name, void *oldp, size_t *oldlenp, void *newp,
                   size_t newlen);

extern int malloc_stats_print(void (*write_cb)(void *, const char *), void *cbopaque,
                               const char *opts);

int IsJemallocProfEnabled();

int IsJemallocStatsEnabled();

size_t GetAllocatedMemory();

size_t GetActiveMemory();

size_t GetMetadataMemory();

size_t GetMetadataThpMemory();

size_t GetResidentMemory();

size_t GetMappedMemory();

size_t GetRetainedMemory();

size_t GetZeroReallocs();

size_t GetBackgroundThreadNumThreads();

size_t GetBackgroundThreadNumRuns();

size_t GetBackgroundThreadRunInterval();

#endif // CGOMEMPROF_H