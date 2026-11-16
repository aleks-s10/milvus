// Fork test branch only: minimal reproduction of the FIPS-build PBKDF2 crash outside Milvus.
// Same PBKDF2 code as pkg/util/crypto/pbkdf2.go, same cgo traceback helper Milvus links.
package main

/*
#include <stdint.h>
static void ccrash(void) { volatile int *p = (int *)(uintptr_t)8; *p = 1; }
*/
import "C"

import (
	"crypto/boring"
	"crypto/hmac"
	"crypto/sha512"
	"crypto/subtle"
	"encoding/binary"
	"fmt"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"time"

	_ "github.com/benesch/cgosymbolizer" // as in pkg/util/symbolizer
)

// Copied from master's pkg/util/crypto/pbkdf2.go.
func pbkdf2SHA512(password, salt []byte, iterations, keyBytes int) []byte {
	prf := hmac.New(sha512.New, password)
	hashBytes := prf.Size()
	blocks := (keyBytes + hashBytes - 1) / hashBytes
	derived := make([]byte, 0, blocks*hashBytes)
	u := make([]byte, 0, hashBytes)
	t := make([]byte, hashBytes)
	var blockIndex [4]byte
	for block := 1; block <= blocks; block++ {
		binary.BigEndian.PutUint32(blockIndex[:], uint32(block))
		prf.Reset()
		prf.Write(salt)
		prf.Write(blockIndex[:])
		u = prf.Sum(u[:0])
		copy(t, u)
		for i := 2; i <= iterations; i++ {
			prf.Reset()
			prf.Write(u)
			u = prf.Sum(u[:0])
			subtle.XORBytes(t, t, u)
		}
		derived = append(derived, t...)
	}
	return derived[:keyBytes]
}

//go:noinline
func goFrameAboveC() { C.ccrash() }

func main() {
	fmt.Printf("boringcrypto=%v go=%s\n", boring.Enabled(), runtime.Version())
	if len(os.Args) > 1 && os.Args[1] == "ccrash" {
		goFrameAboveC() // segfault in C: shows what the crash report contains
		return
	}
	dur := 60 * time.Second
	var hashes atomic.Int64
	stop := make(chan struct{})
	var wg sync.WaitGroup
	for w := 0; w < runtime.NumCPU(); w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				pbkdf2SHA512([]byte(fmt.Sprintf("pw-%d", w)), []byte("salt-0123456789ab"), 210000, 64)
				hashes.Add(1)
			}
		}(w)
	}
	// Allocation pressure: frequent GCs make the runtime signal (SIGURG) running goroutines.
	go func() {
		var sink [][]byte
		for {
			select {
			case <-stop:
				return
			default:
			}
			sink = append(sink, make([]byte, 64<<10))
			if len(sink) > 256 {
				sink = nil
			}
		}
	}()
	time.Sleep(dur)
	close(stop)
	wg.Wait()
	fmt.Printf("STRESS PASS %d hashes in %s\n", hashes.Load(), dur)
}
