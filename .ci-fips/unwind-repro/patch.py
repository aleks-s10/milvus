# Writes the option-3 variants of the Milvus cgosymbolizer fork's traceback.c.
# Usage: patch.py <traceback.c> <3a|3b>
import sys
p, v = sys.argv[1], sys.argv[2]
s = open(p).read()
anchor = "\t// Skip this frame, the runtime/cgo function, and the sigreturn frame.\n"
assert anchor in s, "anchor"
if v == "3a":
    guard = ("\t// Don't unwind from a signal handler: the interrupted code may have no unwind\n"
             "\t// information (for example BoringCrypto assembly), and the unwinder faults on it.\n"
             "\tif (arg->sigContext != 0) {\n\t\targ->buf[0] = 0;\n\t\treturn;\n\t}\n\n")
    s = s.replace(anchor, guard + anchor, 1)
elif v == "3b":
    hdr = ("#define _GNU_SOURCE\n#include <ucontext.h>\n"
           "struct dwarf_eh_bases { void *tbase; void *dbase; void *func; };\n"
           "extern const void *_Unwind_Find_FDE(void *pc, struct dwarf_eh_bases *bases);\n")
    s = s.replace('#include "config.h"\n', hdr + '#include "config.h"\n', 1)
    guard = ("\t// From a signal handler, only unwind if the interrupted code has unwind information.\n"
             "\t// Code without it (for example BoringCrypto assembly) makes the unwinder fault.\n"
             "\tif (arg->sigContext != 0) {\n"
             "\t\tucontext_t *uc = (ucontext_t *)arg->sigContext;\n"
             "\t\tstruct dwarf_eh_bases bases;\n"
             "#if defined(__x86_64__)\n\t\tvoid *pc = (void *)uc->uc_mcontext.gregs[REG_RIP];\n"
             "#elif defined(__aarch64__)\n\t\tvoid *pc = (void *)uc->uc_mcontext.pc;\n"
             "#else\n\t\tvoid *pc = 0;\n#endif\n"
             "\t\tif (pc == 0 || _Unwind_Find_FDE(pc, &bases) == 0) {\n\t\t\targ->buf[0] = 0;\n\t\t\treturn;\n\t\t}\n\t}\n\n")
    s = s.replace(anchor, guard + anchor, 1)
else:
    sys.exit("variant")
open(p, "w").write(s)
print(f"patched {v}")
