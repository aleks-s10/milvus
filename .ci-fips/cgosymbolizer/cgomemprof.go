//go:build with_jemalloc && linux
// +build with_jemalloc,linux

package cgosymbolizer

// #cgo pkg-config: jemalloc
//
// #include "cgomemprof.h"
// #include "stdlib.h"
import "C"

import (
	"fmt"
	"sync"
	"unsafe"
)

var mu sync.RWMutex

// IsJemallocProfEnabled returns true if jemalloc profiling is enabled.
func IsJemallocProfEnabled() bool {
	enabled := C.IsJemallocProfEnabled()
	return int(enabled) == 1
}

// IsJemallocStatsEnabled returns true if jemalloc stats is enabled.
func IsJemallocStatsEnabled() bool {
	enabled := C.IsJemallocStatsEnabled()
	return int(enabled) == 1
}

// EnableMemoryProfiling enables memory profiling at runtime.
func EnableMemoryProfiling() error {
	mu.Lock()
	defer mu.Unlock()

	if code := C.EnableMemoryProfiling(); code != 0 {
		return fmt.Errorf("EnableMemoryProfiling failed with code %d", code)
	}
	return nil
}

// DisableMemoryProfiling disables memory profiling at runtime.
func DisableMemoryProfiling() error {
	mu.Lock()
	defer mu.Unlock()

	if code := C.DisableMemoryProfiling(); code != 0 {
		return fmt.Errorf("DisableMemoryProfiling failed with code %d", code)
	}
	return nil
}

// DumpMemoryProfileIntoFile dumps memory profile into file.
func DumpMemoryProfileIntoFile(filename string) error {
	mu.RLock()
	defer mu.RUnlock()

	cfilename := C.CString(filename)
	defer C.free(unsafe.Pointer(cfilename))
	if code := C.DumpMemoryProfileIntoFile(cfilename); code != 0 {
		return fmt.Errorf("DumpMemoryProfileIntoFile failed with code %d", int(code))
	}
	return nil
}

func DumpStatsIntoFile(filename string, opts string) error {
	cfilename := C.CString(filename)
	defer C.free(unsafe.Pointer(cfilename))
	copts := C.CString(opts)
	defer C.free(unsafe.Pointer(copts))
	if code := C.DumpStatsIntoFile(cfilename, copts); code != 0 {
		return fmt.Errorf("DumpStatsIntoFile failed with code %d", int(code))
	}
	return nil
}

// GetSymbol returns the symbol name of the given address.
func GetSymbol(addr uint64) string {
	result := C.GetSymbol(C.uintptr_t(addr))
	r := C.GoString(result)
	C.free(unsafe.Pointer(result))
	return r
}

func GetAllocatedMemory() uint64 {
	return uint64(C.GetAllocatedMemory())
}

func GetActiveMemory() uint64 {
	return uint64(C.GetActiveMemory())
}

func GetMetadataMemory() uint64 {
	return uint64(C.GetMetadataMemory())
}

func GetMetadataThpMemory() uint64 {
	return uint64(C.GetMetadataThpMemory())
}

func GetResidentMemory() uint64 {
	return uint64(C.GetResidentMemory())
}

func GetMappedMemory() uint64 {
	return uint64(C.GetMappedMemory())
}

func GetRetainedMemory() uint64 {
	return uint64(C.GetRetainedMemory())
}

func GetZeroReallocs() uint64 {
	return uint64(C.GetZeroReallocs())
}

func GetBackgroundThreadNumThreads() uint64 {
	return uint64(C.GetBackgroundThreadNumThreads())
}

func GetBackgroundThreadNumRuns() uint64 {
	return uint64(C.GetBackgroundThreadNumRuns())
}

func GetBackgroundThreadRunInterval() uint64 {
	return uint64(C.GetBackgroundThreadRunInterval())
}
