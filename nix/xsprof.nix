{ stdenv, lib, cmake, ninja, bear, pkg-config, fmt, nlohmann_json, catch2_3, libbpf, elfutils, zstd }:

stdenv.mkDerivation (finalAttrs: {
  pname = "xsprof";
  version = "0.1.0";
  src = ./..;

  nativeBuildInputs = [ cmake ninja bear pkg-config ];
  buildInputs = [ fmt nlohmann_json catch2_3 libbpf elfutils zstd ];

  cmakeFlags = [ "-DCMAKE_BUILD_TYPE=RelWithDebInfo" ];

  doCheck = true;

  meta = with lib; {
    description = "Linux Scheduler & Memory Profiler (C++ rewrite of zig-scheduler)";
    license = licenses.mit;
    platforms = platforms.linux;
  };
})
