load("@prelude//cxx:cxx_toolchain_types.bzl", "LinkerType")
load("@prelude//python_bootstrap:python_bootstrap.bzl", "PythonBootstrapToolchainInfo")
load("@prelude//toolchains:cxx.bzl", "CxxToolsInfo")
load("//stage1:defs.bzl", "RustDistInfo")

# The LLVM fork that the compiler links, as a GitHub archive of the commit.
_LLVM_COMMIT = "6184f76016c590ca1ddeafa568454eb379391b79"
_LLVM_SHA256 = "ef2688b0bc24e84813cdc04c565085f6ff0e793c32f6bb55d778206e770e80ad"

# The build tools of the LLVM build, by host os and cpu.
_CMAKE_VERSION = "3.31.8"
_NINJA_VERSION = "1.13.1"
_BUILD_TOOLS = {
    "linux": {
        "x86_64": struct(
            cmake_archive = "cmake-{}-linux-x86_64.tar.gz".format(_CMAKE_VERSION),
            cmake_sha256 = "630615d8e98ac33eba7fbe472626dff5c899c85af3c024585ae109166a6909d0",
            cmake_root = "cmake-{}-linux-x86_64".format(_CMAKE_VERSION),
            ninja_archive = "ninja-linux.zip",
            ninja_sha256 = "0830252db77884957a1a4b87b05a1e2d9b5f658b8367f82999a941884cbe0238",
        ),
    },
    "macos": {
        "arm64": struct(
            cmake_archive = "cmake-{}-macos-universal.tar.gz".format(_CMAKE_VERSION),
            cmake_sha256 = "d1449f969c54d5c00886d5b643340d493dfb3c81cb39ee29b35453395c11ebf7",
            cmake_root = "cmake-{}-macos-universal/CMake.app/Contents".format(_CMAKE_VERSION),
            ninja_archive = "ninja-mac.zip",
            ninja_sha256 = "da7797794153629aca5570ef7c813342d0be214ba84632af886856e8f0063dd9",
        ),
    },
    "windows": {
        "x86_64": struct(
            cmake_archive = "cmake-{}-windows-x86_64.zip".format(_CMAKE_VERSION),
            cmake_sha256 = "81aa9964dbabd71fe02e7ec50472fd3ad56138c49944515ece9001efbff8d719",
            cmake_root = "cmake-{}-windows-x86_64".format(_CMAKE_VERSION),
            ninja_archive = "ninja-win.zip",
            ninja_sha256 = "26a40fa8595694dec2fad4911e62d29e10525d2133c9a4230b66397774ae25bf",
        ),
    },
}

def _by_host(value):
    """Selects `value(os, cpu)` for the hosts of _BUILD_TOOLS, else None."""
    return select({"DEFAULT": None} | {
        "prelude//os:" + os: select({"DEFAULT": None} | {
            "prelude//cpu:" + cpu: value(os, cpu)
            for cpu in cpus
        })
        for os, cpus in _BUILD_TOOLS.items()
    })

def _exe(name):
    return select({
        "DEFAULT": name,
        "prelude//os:windows": name + ".exe",
    })

def _custom_llvm_impl(ctx: AnalysisContext) -> list[Provider]:
    if ctx.attrs.cmake == None or ctx.attrs.ninja == None:
        fail("the Xbox 360 LLVM builds only on x86_64 Linux, arm64 macOS and x86_64 Windows hosts")

    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    install = ctx.actions.declare_output("install", dir = True)
    command = cmd_args(
        ctx.attrs._python_bootstrap_toolchain[PythonBootstrapToolchainInfo].interpreter,
        ctx.attrs._builder,
        "--source",
        source,
        "--cmake",
        ctx.attrs.cmake[DefaultInfo].default_outputs[0].project("bin/" + ctx.attrs._cmake_exe),
        "--ninja",
        ctx.attrs.ninja[DefaultInfo].default_outputs[0].project(ctx.attrs._ninja_exe),
        "--output",
        install.as_output(),
        "--jobs",
        str(ctx.attrs.jobs),
    )
    if ctx.attrs._msvc_cl:
        # The JSON of prelude//toolchains/msvc: cl.exe and its PATH, INCLUDE
        # and LIB.
        command.add("--msvc-cl", ctx.attrs._msvc_cl[DefaultInfo].default_outputs[0])
    else:
        command.add("--cc", ctx.attrs.cc, "--cxx", ctx.attrs.cxx)
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
        # Host compilers, by name on PATH or by absolute path. Windows uses
        # the cl.exe of prelude//toolchains/msvc instead.
        "cc": attrs.string(default = "cc"),
        # None on hosts without a build of the tools.
        "cmake": attrs.option(attrs.exec_dep()),
        "cxx": attrs.string(default = "c++"),
        "jobs": attrs.int(),
        "ninja": attrs.option(attrs.exec_dep()),
        "source": attrs.dep(),
        "_builder": attrs.source(default = "//stage0:build_custom_llvm.py"),
        "_cmake_exe": attrs.default_only(attrs.string(default = _exe("cmake"))),
        "_msvc_cl": attrs.default_only(attrs.option(attrs.exec_dep(), default = select({
            "DEFAULT": None,
            "prelude//os:windows": "prelude//toolchains/msvc:msvc_tools[cl.exe][json]",
        }))),
        "_ninja_exe": attrs.default_only(attrs.string(default = _exe("ninja"))),
        "_python_bootstrap_toolchain": attrs.toolchain_dep(
            default = "//toolchains:python_bootstrap",
            providers = [PythonBootstrapToolchainInfo],
        ),
    },
    supports_incoming_transition = True,
)

def custom_llvm(name, jobs, visibility, incoming_transition, cache = ""):
    native.http_archive(
        name = name + "-source",
        sha256 = _LLVM_SHA256,
        strip_prefix = "llvm-project-" + _LLVM_COMMIT,
        urls = ["https://github.com/landaire-contrib/llvm-project/archive/" + _LLVM_COMMIT + ".tar.gz"],
    )
    for os, cpus in _BUILD_TOOLS.items():
        for cpu, tools in cpus.items():
            native.http_archive(
                name = "{}-cmake-{}-{}".format(name, os, cpu),
                sha256 = tools.cmake_sha256,
                strip_prefix = tools.cmake_root,
                urls = ["https://github.com/Kitware/CMake/releases/download/v{}/{}".format(_CMAKE_VERSION, tools.cmake_archive)],
            )
            native.http_archive(
                name = "{}-ninja-{}-{}".format(name, os, cpu),
                sha256 = tools.ninja_sha256,
                urls = ["https://github.com/ninja-build/ninja/releases/download/v{}/{}".format(_NINJA_VERSION, tools.ninja_archive)],
            )
    _custom_llvm(
        name = name,
        jobs = jobs,
        cache = cache,
        cmake = _by_host(lambda os, cpu: ":{}-cmake-{}-{}".format(name, os, cpu)),
        ninja = _by_host(lambda os, cpu: ":{}-ninja-{}-{}".format(name, os, cpu)),
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
