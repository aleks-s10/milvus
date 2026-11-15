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
W=$(mktemp -d)
for ref in "$FOLLY" "$AWSIO"; do
  conan cache path "$ref" >/dev/null 2>&1 || conan download "$ref" -r default-conan-local2 --only-recipe >/dev/null
done
cp -r "$(conan cache path "$FOLLY")" "$W/folly"
cp -r "$(conan cache path "$AWSIO")" "$W/awsio"
for name in folly awsio; do
  ref=$([ $name = folly ] && echo "$FOLLY" || echo "$AWSIO")
  es=$(conan cache path "$ref" --folder export_source 2>/dev/null || true)
  # export_sources() copies files from the recipe folder into src/, so put them back at the top level.
  [ -n "$es" ] && [ -d "$es/src" ] && cp -r "$es/src/." "$W/$name/" || true
done

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
print("recipes patched")
EOF

rev() { conan export "$1" "${@:2}" 2>&1 | tee /dev/stderr | grep -oE 'Exported: [^#]+#[0-9a-f]+' | tail -1 | sed 's/.*#//'; }
FR=$(rev "$W/folly" --name folly --version 2026.04.20.00 --user milvus --channel dev)
AR=$(rev "$W/awsio" --name aws-c-io --version 1.1.1)
[ -n "$FR" ] && [ -n "$AR" ] || { echo "export failed"; exit 1; }
echo "folly patched revision: $FR"; echo "aws-c-io patched revision: $AR"

python3 - "$FR" "$AR" <<'EOF'
import sys, re
fr, ar = sys.argv[1], sys.argv[2]
p = "internal/core/conanfile.py"; s = open(p).read()
# folly is a direct requirement that other packages also require at the original revision:
# move it out of the requires tuple and force the patched revision on the whole graph.
s = re.sub(r'\n\s*"folly/2026\.04\.20\.00@milvus/dev#[0-9a-f]+",', '', s, count=1)
s = re.sub(r'\n\s*self\.requires\("(folly|aws-c-io)/[^"]+", (force|override)=True\)', '', s)
anchor = '        self.requires("aws-crt-cpp/'
assert anchor in s, "aws-crt-cpp requires anchor"
s = s.replace(anchor, f'        self.requires("folly/2026.04.20.00@milvus/dev#{fr}", force=True)\n'
                      f'        self.requires("aws-c-io/1.1.1#{ar}", override=True)\n' + anchor, 1)
open(p, "w").write(s)
print("conanfile pinned")
EOF
grep -nE 'folly/2026|aws-c-io|sasl|s3-crt|with_libsodium|byo_crypto|libsodium' internal/core/conanfile.py
