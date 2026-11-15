#!/bin/bash
# Fork spike only: export patched folly and aws-c-io recipes into the Conan cache and pin them
# in internal/core/conanfile.py, so the build drops libsodium (folly) and s2n (aws-c-io BYO_CRYPTO).
# Idempotent: re-exporting the same patched recipe gives the same revision.
set -euo pipefail
unset LD_PRELOAD LD_LIBRARY_PATH
export PATH="$HOME/.local/bin:$PATH"
conan --version | grep -q '2\.25\.1' || pip3 install -q conan==2.25.1
[ -f "$(conan config home)/profiles/default" ] || conan profile detect >/dev/null
conan remote list | grep -q default-conan-local2 || \
  conan remote add default-conan-local2 https://milvus01.jfrog.io/artifactory/api/conan/default-conan-local2 --index 0
cd /go/src/github.com/milvus-io/milvus

FOLLY=folly/2026.04.20.00@milvus/dev#06852bea5b6449f0c4eb0df002b5779c
AWSIO=aws-c-io/1.1.1#2dd777871cf93ce4f35ba714a1ba87ef
# Packages whose sources have BYO_CRYPTO code paths and call aws-c-io's TLS functions directly
# (found by grepping every aws-* source). Their binaries must be rebuilt when aws-c-io changes mode.
BYO_CONSUMERS="aws-crt-cpp/0.44.3#43f6408847655d35224320f4774bfcb9 aws-c-auth/1.0.2#f587952f127cc579b90265a0f35056df aws-c-http/1.1.1#4ebd9cad4c949ed136f95419ce0ceee3 aws-c-s3/1.5.1#41f018ea69dd13668a2ffe76d0731742"
W=$(mktemp -d)
copy_recipe() {  # <ref> <dir>
  conan cache path "$1" >/dev/null 2>&1 || conan download "$1" -r default-conan-local2 --only-recipe >/dev/null
  cp -r "$(conan cache path "$1")" "$W/$2"
  local es; es=$(conan cache path "$1" --folder export_source 2>/dev/null || true)
  # export_sources() copies files from the recipe folder into src/, so put them back at the top level.
  [ -n "$es" ] && [ -d "$es/src" ] && cp -r "$es/src/." "$W/$2/" || true
}
copy_recipe "$FOLLY" folly
copy_recipe "$AWSIO" awsio
for ref in $BYO_CONSUMERS; do n=${ref%%/*}; copy_recipe "$ref" "c-$n"; done

python3 - "$W" <<'EOF'
import sys, re
w = sys.argv[1]

def sub(s, old, new, what):
    assert old in s, f"patch anchor not found: {what}"
    return s.replace(old, new, 1)

# folly: make libsodium optional (folly's own CMake already treats it as optional)
p = f"{w}/folly/conanfile.py"; s = open(p).read()
s = sub(s, '"fPIC": [True, False],\n    }', '"fPIC": [True, False],\n        "with_libsodium": [True, False],\n    }', "folly options")
s = sub(s, '"fPIC": True,\n    }', '"fPIC": True,\n        "with_libsodium": True,\n    }', "folly default_options")
s = sub(s, 'self.requires("libsodium/1.0.19")', 'if self.options.with_libsodium:\n            self.requires("libsodium/1.0.19")', "folly requires")
s = sub(s, '        tc = CMakeToolchain(self)\n', '        tc = CMakeToolchain(self)\n        if not self.options.with_libsodium:\n            tc.cache_variables["CMAKE_DISABLE_FIND_PACKAGE_Libsodium"] = True\n', "folly toolchain")
s = sub(s, '            "libsodium::libsodium",\n', '', "folly cpp_info requires")
s = sub(s, '        if not is_msvc(self):\n            self.cpp_info.components["libfolly"].requires.append("libdwarf::libdwarf")',
        '        if self.options.with_libsodium:\n            self.cpp_info.components["libfolly"].requires.append("libsodium::libsodium")\n'
        '        if not is_msvc(self):\n            self.cpp_info.components["libfolly"].requires.append("libdwarf::libdwarf")', "folly cpp_info sodium")
open(p, "w").write(s)
# the recipe's conan_deps.cmake finds every dependency with REQUIRED; skip libsodium when it's disabled
p = f"{w}/folly/conan_deps.cmake"; s = open(p).read()
s = sub(s, 'custom_find_package(Libsodium LIBSODIUM)\n',
        'if (NOT CMAKE_DISABLE_FIND_PACKAGE_Libsodium)\n    custom_find_package(Libsodium LIBSODIUM)\nendif()\n', "folly conan_deps.cmake")
open(p, "w").write(s)

# aws-c-io: BYO_CRYPTO option, which builds no TLS implementation and drops s2n
p = f"{w}/awsio/conanfile.py"; s = open(p).read()
s = sub(s, '"fPIC": [True, False],\n    }', '"fPIC": [True, False],\n        "byo_crypto": [True, False],\n    }', "aws-c-io options")
s = sub(s, '"fPIC": True,\n    }', '"fPIC": True,\n        "byo_crypto": False,\n    }', "aws-c-io default_options")
n = s.count('self.requires("s2n/')
assert n >= 1, "aws-c-io s2n requires"
s = s.replace('self.requires("s2n/', '(not self.options.byo_crypto) and self.requires("s2n/')
s = sub(s, '        tc.variables["BUILD_TESTING"] = False\n',
        '        tc.variables["BUILD_TESTING"] = False\n        tc.cache_variables["BYO_CRYPTO"] = bool(self.options.byo_crypto)\n', "aws-c-io toolchain")
# aws-c-io's CMake target sets BYO_CRYPTO as a PUBLIC define, but Conan doesn't pass CMake target
# definitions on: export it, so aws-crt-cpp and aws-sdk-cpp compile their BYO_CRYPTO code paths
# instead of calling TLS functions this aws-c-io build doesn't have.
s = sub(s, '        self.cpp_info.libs = ["aws-c-io"]\n',
        '        self.cpp_info.libs = ["aws-c-io"]\n        if self.options.byo_crypto:\n            self.cpp_info.defines.append("BYO_CRYPTO")\n', "aws-c-io package_info")
# aws-c-http calls aws_tls_handler_protocol, which aws-c-io defines only in its non-BYO_CRYPTO
# code. With BYO_CRYPTO no TLS context can be created, so no channel ever holds a TLS handler
# and the accessor is unreachable; define it to report no negotiated protocol.
s = sub(s, '    def build(self):\n        cmake = CMake(self)\n',
        '    def build(self):\n'
        '        if self.options.byo_crypto:\n'
        '            save(self, os.path.join(self.source_folder, "source", "milvus_byo_crypto_stubs.c"),\n'
        '                 "#include <aws/io/tls_channel_handler.h>\\n"\n'
        '                 "struct aws_byte_buf aws_tls_handler_protocol(struct aws_channel_handler *handler) {\\n"\n'
        '                 "    (void)handler;\\n"\n'
        '                 "    struct aws_byte_buf empty;\\n"\n'
        '                 "    AWS_ZERO_STRUCT(empty);\\n"\n'
        '                 "    return empty;\\n"\n'
        '                 "}\\n")\n'
        '        cmake = CMake(self)\n', "aws-c-io build stub")
open(p, "w").write(s)

# BYO_CRYPTO consumers: their sources compile differently under BYO_CRYPTO, but Conan's default
# package_id ignores a shared dependency's options, so cached non-BYO_CRYPTO binaries would be
# reused and fail to link (seen with aws-crt-cpp, then aws-c-s3). Make aws-c-io's options part of
# their package_id.
import glob, os
for d in sorted(glob.glob(f"{w}/c-*")):
    p = f"{d}/conanfile.py"; s = open(p).read()
    assert "def package_id" not in s, f"{d}: already has package_id"
    s = sub(s, '    def requirements(self):\n',
            '    def package_id(self):\n        self.info.requires["aws-c-io"].full_package_mode()\n\n    def requirements(self):\n', f"{os.path.basename(d)} package_id")
    open(p, "w").write(s)
print("recipes patched")
EOF

rev() { conan export "$1" "${@:2}" 2>&1 | tee /dev/stderr | grep -oE 'Exported: [^#]+#[0-9a-f]+' | tail -1 | sed 's/.*#//'; }
FR=$(rev "$W/folly" --name folly --version 2026.04.20.00 --user milvus --channel dev)
AR=$(rev "$W/awsio" --name aws-c-io --version 1.1.1)
[ -n "$FR" ] && [ -n "$AR" ] || { echo "export failed"; exit 1; }
echo "folly patched revision: $FR"; echo "aws-c-io patched revision: $AR"
PINS=""
for ref in $BYO_CONSUMERS; do
  n=${ref%%/*}; v=${ref#*/}; v=${v%%#*}
  r=$(rev "$W/c-$n" --name "$n" --version "$v"); [ -n "$r" ] || { echo "export failed: $n"; exit 1; }
  echo "$n patched revision: $r"; PINS="$PINS $n/$v#$r"
done

python3 - "$FR" "$AR" $PINS <<'EOF'
import sys, re
fr, ar, pins = sys.argv[1], sys.argv[2], sys.argv[3:]
p = "internal/core/conanfile.py"; s = open(p).read()
# folly is a direct requirement that other packages also require at the original revision:
# move it out of the requires tuple and force the patched revision on the whole graph.
s = re.sub(r'\n\s*"folly/2026\.04\.20\.00@milvus/dev#[0-9a-f]+",', '', s, count=1)
s = re.sub(r'\n\s*self\.requires\("(folly|aws-c-io|aws-c-auth|aws-c-http|aws-c-s3)/[^"]+", (force|override)=True\)', '', s)
for pin in pins:
    if pin.startswith("aws-crt-cpp/"):
        # direct requirement of Milvus: swap its pin in place
        s, n = re.subn(r'self\.requires\("aws-crt-cpp/0\.44\.3#[0-9a-f]+"(, force=True)?\)', f'self.requires("{pin}", force=True)', s, count=1)
        assert n == 1, "aws-crt-cpp pin"
anchor = '        self.requires("aws-crt-cpp/'
assert anchor in s, "aws-crt-cpp requires anchor"
s = s.replace(anchor, f'        self.requires("folly/2026.04.20.00@milvus/dev#{fr}", force=True)\n'
                      f'        self.requires("aws-c-io/1.1.1#{ar}", override=True)\n'
                      + "".join(f'        self.requires("{pin}", override=True)\n' for pin in pins if not pin.startswith("aws-crt-cpp/"))
                      + anchor, 1)
open(p, "w").write(s)
print("conanfile pinned")
EOF
grep -nE 'folly/2026|aws-c-io|aws-c-auth|aws-c-http|aws-c-s3|aws-crt-cpp/|sasl|s3-crt|with_libsodium|byo_crypto|libsodium' internal/core/conanfile.py
