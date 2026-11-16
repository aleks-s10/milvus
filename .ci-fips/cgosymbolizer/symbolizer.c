// Copyright 2015 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <ucontext.h>
#include <unistd.h>

#include "backtrace.h"
#include "config.h"
#include "internal.h"

static void createStateErrorCallback(void* data, const char* msg, int errnum) {}

struct backtrace_state* cgoBacktraceState;

// Initialize the backtrace state.
void cgoSymbolizerInit(char* filename) {
  cgoBacktraceState =
      backtrace_create_state(filename, 1, createStateErrorCallback, NULL);
}

struct cgoSymbolizerArg {
  uintptr_t pc;
  const char* file;
  uintptr_t lineno;
  const char* func;
  uintptr_t entry;
  uintptr_t more;
  uintptr_t data;
};

struct cgoSymbolizerMore {
  struct cgoSymbolizerMore* more;

  const char* file;
  uintptr_t lineno;
  const char* func;
};

// Called via backtrace_pcinfo.
static int callback(void* data, uintptr_t pc, const char* filename, int lineno,
                    const char* function) {
  struct cgoSymbolizerArg* arg = (struct cgoSymbolizerArg*)(data);
  struct cgoSymbolizerMore* more;
  struct cgoSymbolizerMore** pp;
  if (arg->file == NULL) {
    arg->file = filename;
    arg->lineno = lineno;
    arg->func = function;
    return 0;
  }
  more = backtrace_alloc(cgoBacktraceState, sizeof(*more), NULL, NULL);
  if (more == NULL) {
    return 1;
  }
  more->more = NULL;
  more->file = filename;
  more->lineno = lineno;
  more->func = function;
  for (pp = (struct cgoSymbolizerMore**)(&arg->data); *pp != NULL;
       pp = &(*pp)->more) {
  }
  *pp = more;
  arg->more = 1;
  return 0;
}

// Called via backtrace_pcinfo.
// Just ignore errors and let the caller indicate missing information.
static void errorCallback(void* data, const char* msg, int errnum) {}

// Called via backtrace_syminfo.
// Just set the entry field.
static void syminfoCallback(void* data, uintptr_t pc, const char* symname,
                            uintptr_t symval, uintptr_t symsize) {
  struct cgoSymbolizerArg* arg = (struct cgoSymbolizerArg*)(data);
  arg->entry = symval;
}

// For the details of how this is called see runtime.SetCgoTraceback.
void cgoSymbolizer(void* parg) {
  struct cgoSymbolizerArg* arg = (struct cgoSymbolizerArg*)(parg);
  if (arg->data != 0) {
    struct cgoSymbolizerMore* more = (struct cgoSymbolizerMore*)(arg->data);
    arg->file = more->file;
    arg->lineno = more->lineno;
    arg->func = more->func;
    arg->more = more->more != NULL;
    arg->data = (uintptr_t)(more->more);

    // If returning the last file/line, we can set the
    // entry point field.
    if (!arg->more) {
      backtrace_syminfo(cgoBacktraceState, arg->pc, syminfoCallback,
                        errorCallback, (void*)arg);
    }

    return;
  }
  arg->file = NULL;
  arg->lineno = 0;
  arg->func = NULL;
  arg->more = 0;
  if (cgoBacktraceState == NULL || arg->pc == 0) {
    return;
  }
  backtrace_pcinfo(cgoBacktraceState, arg->pc, callback, errorCallback,
                   (void*)(arg));

  // If returning only one file/line, we can set the entry point field.
  if (!arg->more) {
    backtrace_syminfo(cgoBacktraceState, arg->pc, syminfoCallback,
                      errorCallback, (void*)arg);
  }
}

void backtraceErrorCallback(void* data, const char* msg, int errnum) {
  fprintf(stderr, "Error %d occurred when getting the stacktrace: %s", errnum,
          msg);
}

int backtraceCallback(void* data, uintptr_t pc, const char* filename,
                      int lineno, const char* function) {
  fprintf(stderr, "%s\n\t%s:%d pc=0x%lx\n", function, filename, lineno, pc);
  return 0;
}

void printBacktrace(int signo, siginfo_t* info, void* context) {
  if (!cgoBacktraceState) {
    perror("cgoBacktraceState is not initialized");
    return;
  }
  ucontext_t* uc = (ucontext_t*)(context);

  fprintf(stderr, "\nSIGNAL CATCH BY NON-GO SIGNAL HANDLER\n");
  fprintf(stderr,
          "SIGNO: %d; SIGNAME: %s; SI_CODE: %d; SI_ADDR: %p\nBACKTRACE:\n",
          signo, strsignal(signo), info->si_code, info->si_addr);
  // skip the wrapHandler, sigaction.
  backtrace_full(cgoBacktraceState, 3, backtraceCallback,
                 backtraceErrorCallback, NULL);
  fprintf(stderr, "\n\n");
  fflush(stderr);
}

#define MAX_SIGNAL 32

static void (*oldSignalHandler[MAX_SIGNAL])(int signo, siginfo_t* info,
                                            void* context);

static void wrapHandler(int signo, siginfo_t* info, void* context) {
  printBacktrace(signo, info, context);
  oldSignalHandler[signo](signo, info, context);

  /* Reaching this point means the previous handler returned without killing
     the process.  Go's runtime does that for a fault on a non-Go thread when
     the process is PID 1 of a PID namespace: raisebadsignal() installs
     SIG_DFL and raise()s, but raise() is tgkill(), and the kernel discards a
     sent signal whose disposition is SIG_DFL for an init process unless it is
     force-delivered (kernel/signal.c, SIGNAL_UNKILLABLE).  It then restores
     the Go handler and returns, we return, the faulting instruction executes
     again, and the thread loops on the fault forever -- process alive, task
     never finishing.  See golang/go#59569.

     A synchronous fault *is* force-delivered, even to an init process, so for
     a kernel-raised signal (si_code > 0) restoring SIG_DFL and returning lets
     the instruction re-execute and terminate the process the normal way, core
     dump included.  A sent signal has no instruction to replay, so exit. */
  signal(signo, SIG_DFL);
  if (info != NULL && info->si_code > 0) {
    return;
  }
  {
    sigset_t only;
    sigemptyset(&only);
    sigaddset(&only, signo);
    pthread_sigmask(SIG_UNBLOCK, &only, NULL);
    raise(signo);
    _exit(128 + signo);
  }
}

void cgoInstallNonGoHandlerForSignum(int signum) {
  if (signum >= MAX_SIGNAL) {
    perror("signum is too large");
  }

  // get old signal handler, it should be a default go signal handler.
  struct sigaction old_action;
  memset(&old_action, 0, sizeof(old_action));
  sigemptyset(&old_action.sa_mask);
  if (sigaction(signum, NULL, &old_action) == -1) {
    perror("get old signal handler failed");
    exit(EXIT_FAILURE);
  }

  // check if the old signal handler is setted
  if (old_action.sa_handler == SIG_DFL) {
    fprintf(stderr,
            "Go runtime signal handler is not setted, please set it first\n");
    exit(EXIT_FAILURE);
  }

  // check if SA_ONSTACK is setted.
  if (old_action.sa_flags & SA_ONSTACK == 0) {
    fprintf(stderr, "Go runtime signal handler is setted with SA_ONSTACK\n");
    exit(EXIT_FAILURE);
  }

  oldSignalHandler[signum] = old_action.sa_sigaction;
  old_action.sa_sigaction = &wrapHandler;

  if (sigaction(signum, &old_action, NULL) == -1) {
    perror("set up new signal handler failed");
    exit(EXIT_FAILURE);
  }
}

void cgoInstallNonGoHandler() {
  cgoInstallNonGoHandlerForSignum(SIGSEGV);
  cgoInstallNonGoHandlerForSignum(SIGBUS);
  cgoInstallNonGoHandlerForSignum(SIGFPE);
}
