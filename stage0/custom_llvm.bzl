load("@prelude//cxx:cxx_toolchain_types.bzl", "LinkerType")
load("@prelude//python_bootstrap:python_bootstrap.bzl", "PythonBootstrapToolchainInfo")
load("@prelude//toolchains:cxx.bzl", "CxxToolsInfo")
load("//stage1:defs.bzl", "RustDistInfo")

# The LLVM fork that the compiler links, as a GitHub archive of the commit.
_LLVM_COMMIT = "857a5a9f231e48ea178ccda35de1c75b131a59e2"
_LLVM_SHA256 = "b91ec2ffb6644eada0915d6d91f5332d1587174439a74aa0b201767181fcc6c6"

# The build tools of the LLVM build, for x86_64 Linux.
_CMAKE_VERSION = "3.31.8"
_CMAKE_SHA256 = "630615d8e98ac33eba7fbe472626dff5c899c85af3c024585ae109166a6909d0"
_NINJA_VERSION = "1.13.1"
_NINJA_SHA256 = "0830252db77884957a1a4b87b05a1e2d9b5f658b8367f82999a941884cbe0238"

def _custom_llvm_impl(ctx: AnalysisContext) -> list[Provider]:
    if not ctx.attrs._supported_host:
        fail("the Xbox 360 LLVM builds only on x86_64 Linux hosts")

    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    install = ctx.actions.declare_output("install", dir = True)
    command = cmd_args(
        ctx.attrs._python_bootstrap_toolchain[PythonBootstrapToolchainInfo].interpreter,
        ctx.attrs._builder,
        "--source",
        source,
        "--cmake",
        ctx.attrs.cmake[DefaultInfo].default_outputs[0].project("bin/cmake"),
        "--ninja",
        ctx.attrs.ninja[DefaultInfo].default_outputs[0].project("ninja"),
        "--cc",
        ctx.attrs.cc,
        "--cxx",
        ctx.attrs.cxx,
        "--output",
        install.as_output(),
        "--jobs",
        str(ctx.attrs.jobs),
    )
    if ctx.attrs.cache:
        command.add("--cache", ctx.attrs.cache)

    # The host C and C++ compilers are not inputs of the action, so its
    # results stay on this machine.
    ctx.actions.run(
        command,
        category = "custom_llvm",
        local_only = True,
        allow_cache_upload = False,
        weight = 100,
    )
    return [
        DefaultInfo(default_output = install),
        RustDistInfo(artifacts = {"lib": install.project("lib")}),
    ]

_custom_llvm = rule(
    impl = _custom_llvm_impl,
    attrs = {
        "cache": attrs.string(default = ""),
        # Host compilers, by name on PATH or by absolute path.
        "cc": attrs.string(default = "cc"),
        "cmake": attrs.exec_dep(),
        "cxx": attrs.string(default = "c++"),
        "jobs": attrs.int(),
        "ninja": attrs.exec_dep(),
        "source": attrs.dep(),
        "_builder": attrs.source(default = "//stage0:build_custom_llvm.py"),
        "_python_bootstrap_toolchain": attrs.toolchain_dep(
            default = "//toolchains:python_bootstrap",
            providers = [PythonBootstrapToolchainInfo],
        ),
        "_supported_host": attrs.default_only(attrs.bool(default = select({
            "DEFAULT": False,
            "prelude//os:linux": select({
                "DEFAULT": False,
                "prelude//cpu:x86_64": True,
            }),
        }))),
    },
    supports_incoming_transition = True,
)

def custom_llvm(name, jobs, visibility, incoming_transition, cache = ""):
    native.http_archive(
        name = name + "-source",
        sha256 = _LLVM_SHA256,
        strip_prefix = "llvm-project-" + _LLVM_COMMIT,
        urls = ["https://github.com/landaire/llvm-project/archive/" + _LLVM_COMMIT + ".tar.gz"],
    )
    native.http_archive(
        name = name + "-cmake",
        sha256 = _CMAKE_SHA256,
        strip_prefix = "cmake-{}-linux-x86_64".format(_CMAKE_VERSION),
        urls = ["https://github.com/Kitware/CMake/releases/download/v{0}/cmake-{0}-linux-x86_64.tar.gz".format(_CMAKE_VERSION)],
    )
    native.http_archive(
        name = name + "-ninja",
        sha256 = _NINJA_SHA256,
        urls = ["https://github.com/ninja-build/ninja/releases/download/v{}/ninja-linux.zip".format(_NINJA_VERSION)],
    )
    _custom_llvm(
        name = name,
        jobs = jobs,
        cache = cache,
        cmake = ":" + name + "-cmake",
        ninja = ":" + name + "-ninja",
        source = ":" + name + "-source",
        incoming_transition = incoming_transition,
        visibility = visibility,
    )
    _llvm_cxx_tools(
        name = name + "-cxx-tools",
        llvm = ":" + name,
        visibility = visibility,
    )

def _llvm_cxx_tools_impl(ctx: AnalysisContext) -> list[Provider]:
    install = ctx.attrs.llvm[DefaultInfo].default_outputs[0]

    def tool(name):
        return cmd_args(install, format = "{}/bin/" + name)

    return [
        DefaultInfo(),
        CxxToolsInfo(
            compiler = tool("clang"),
            compiler_type = "clang",
            cxx_compiler = tool("clang++"),
            asm_compiler = tool("clang"),
            asm_compiler_type = "clang",
            rc_compiler = None,
            cvtres_compiler = None,
            archiver = tool("llvm-ar"),
            archiver_type = "gnu",
            linker = tool("clang++"),
            linker_type = LinkerType("gnu"),
        ),
    ]

# The C and C++ tools of the built LLVM, which compile and link the
# compiler's C++ code against the host's C++ standard library.
_llvm_cxx_tools = rule(
    impl = _llvm_cxx_tools_impl,
    attrs = {
        "llvm": attrs.dep(),
    },
)
