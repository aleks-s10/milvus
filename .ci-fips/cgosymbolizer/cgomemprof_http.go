//go:build with_jemalloc && linux
// +build with_jemalloc,linux

package cgosymbolizer

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/pprof"
	"os"
	"strconv"
)

const (
	urlPathPrefix     = "/debug/jemalloc/"
	urlPathProfPrefix = urlPathPrefix + "pprof/"
)

func init() {
	if IsJemallocStatsEnabled() {
		log.Println("jemalloc memory stats http handlers registered at " + urlPathPrefix)
		http.HandleFunc(urlPathPrefix+"stats", Stats)
	}

	if !IsJemallocProfEnabled() {
		log.Println("jemalloc memory profiling option is not enabled, cgomemprof http handler will not be registered")
		return
	}

	// manage api
	http.HandleFunc(urlPathPrefix+"active", Active)

	// memory profiling api
	http.HandleFunc(urlPathProfPrefix+"heap", Heap)
	http.HandleFunc(urlPathProfPrefix+"symbol", Symbol)
	http.HandleFunc(urlPathProfPrefix+"cmdline", pprof.Cmdline)

	log.Println("jemalloc memory profiling http handlers registered at " + urlPathPrefix)
}

// Symbol returns the symbol name of the given address.
func Symbol(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")

	// We have to read the whole POST body before
	// writing any output. Buffer the output here.
	var buf bytes.Buffer

	if r.Method == "POST" {
		b := bufio.NewReader(r.Body)
		for {
			word, err := b.ReadSlice('+')
			if err == nil {
				word = word[0 : len(word)-1] // trim +
			}
			pc, _ := strconv.ParseUint(string(word), 0, 64)
			if pc != 0 {
				symbol := GetSymbol(pc)
				fmt.Fprintf(&buf, "%s\n", symbol)
			}

			// Wait until here to check for err; the last
			// symbol will have an err because it doesn't end in +.
			if err != nil {
				if err != io.EOF {
					fmt.Fprintf(&buf, "reading request: %v\n", err)
				}
				break
			}
		}
	} else {
		// Always return that we have symbols.
		fmt.Fprintf(&buf, "num_symbols: 1\n")
	}
	w.Write(buf.Bytes())
}

// Heap dumps the memory profile into a file and serves it into http response.
func Heap(w http.ResponseWriter, r *http.Request) {
	tmpFile, err := os.CreateTemp("", "memprofile-*.dump")
	if err != nil {
		http.Error(w, fmt.Sprintf("could not create temp file to dump, %s", err), http.StatusInternalServerError)
		return
	}
	defer func() {
		tmpFile.Close()
		os.Remove(tmpFile.Name())
	}()

	if err := DumpMemoryProfileIntoFile(tmpFile.Name()); err != nil {
		http.Error(w, fmt.Sprintf("could not dump memory profile, %s", err), http.StatusInternalServerError)
		return
	}
	http.ServeFile(w, r, tmpFile.Name())
}

func Stats(w http.ResponseWriter, r *http.Request) {
	opts := r.URL.Query().Get("opts")
	tmpFile, err := os.CreateTemp("", "memstats-*.dump")
	if err != nil {
		http.Error(w, fmt.Sprintf("could not create temp file to dump, %s", err), http.StatusInternalServerError)
		return
	}
	defer func() {
		tmpFile.Close()
		os.Remove(tmpFile.Name())
	}()

	if err := DumpStatsIntoFile(tmpFile.Name(), opts); err != nil {
		http.Error(w, fmt.Sprintf("could not dump memory stats, %s", err), http.StatusInternalServerError)
		return
	}
	http.ServeFile(w, r, tmpFile.Name())
}

// Active enables or disables jemalloc memory profiling.
func Active(w http.ResponseWriter, r *http.Request) {
	enable := r.URL.Query().Get("enable")
	enableNum, err := strconv.ParseInt(enable, 10, 64)
	if err != nil {
		http.Error(w, fmt.Sprintf("invalid enable value, %s", err), http.StatusBadRequest)
		return
	}
	if enableNum != 0 {
		if err := EnableMemoryProfiling(); err != nil {
			http.Error(w, fmt.Sprintf("could not enable jemalloc memory profiling, %s", err), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("jemalloc memprof enabled"))
		log.Println("jemalloc memory profiling enabled")
	} else {
		if err := DisableMemoryProfiling(); err != nil {
			http.Error(w, fmt.Sprintf("could not disable jemalloc memory profiling, %s", err), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("jemalloc memprof disabled"))
		log.Printf("jemalloc memory profiling disabled")
	}
}
