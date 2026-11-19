# Plugin CMakeLists for building nova-lm into rime.dll on Windows (librime's merged-plugin mode).
# Windows librime cannot load external plugin DLLs (plugins_module.cc: "TODO ... DLL plugins on Windows"),
# so nova-lm goes in as an in-tree plugin, like librime-lua and librime-octagram.
#
# build-win.bat copies this file to librime/plugins/nova-lm/CMakeLists.txt, next to nova_lm.cc and tree_lm.h.
# ggml (static, CPU backend linked in) must be installed first; NOVA_GGML_DIR is its install prefix.
# Build ggml with -DGGML_LLAMAFILE=ON (off by default, ~12% faster GPT-2 on x86) and -DGGML_CPU_REPACK=ON (harmless on
# x86: tree_lm.h only uses the repack buffer on ARM, where ggml has a Q8_0 layout). OpenMP gave no gain.
set(NOVA_GGML_DIR "C:/nova/ggml-install" CACHE PATH "ggml install prefix (static libs, built by build-win.bat)")

add_library(rime-nova-lm-objs OBJECT nova_lm.cc)
target_include_directories(rime-nova-lm-objs PRIVATE ${NOVA_GGML_DIR}/include)
target_compile_definitions(rime-nova-lm-objs PRIVATE NOMINMAX _USE_MATH_DEFINES)
if(MSVC)
  target_compile_options(rime-nova-lm-objs PRIVATE /utf-8 /O2)
endif()
if(BUILD_SHARED_LIBS)
  set_target_properties(rime-nova-lm-objs PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()

set(nova_ggml_libs
  ${NOVA_GGML_DIR}/lib/ggml.lib
  ${NOVA_GGML_DIR}/lib/ggml-cpu.lib
  ${NOVA_GGML_DIR}/lib/ggml-base.lib)

set(plugin_name rime-nova-lm PARENT_SCOPE)
set(plugin_objs $<TARGET_OBJECTS:rime-nova-lm-objs> PARENT_SCOPE)
set(plugin_deps ${rime_library} ${nova_ggml_libs} PARENT_SCOPE)
set(plugin_modules "nova_lm" PARENT_SCOPE)
