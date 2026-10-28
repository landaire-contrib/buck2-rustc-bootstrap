load("@prelude//python_bootstrap:python_bootstrap.bzl", "PythonBootstrapToolchainInfo")
load("//stage1:defs.bzl", "RustDistInfo")

_LLVM_COMMIT = "aa06e8ebabae50f409c60fd8717ae57201a5034f"
_LLVM_SHA256 = "02536e247e88ef77fc355bcd2f40ed94422737e168815c79a2f6addb30cf806c"


def _custom_llvm_impl(ctx: AnalysisContext) -> list[Provider]:
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    output = ctx.actions.declare_output("custom-llvm", dir = True)
    command = cmd_args(
        ctx.attrs._python_bootstrap_toolchain[PythonBootstrapToolchainInfo].interpreter,
        ctx.attrs._builder,
        "--source",
        source,
        "--output",
        output.as_output(),
        "--jobs",
        str(ctx.attrs.jobs),
    )
    if ctx.attrs.cache:
        command.add("--cache", ctx.attrs.cache)
    ctx.actions.run(
        command,
        category = "custom_llvm",
        local_only = True,
        weight = 100,
    )
    install = output.project("install")
    return [
        DefaultInfo(default_output = install),
        RustDistInfo(artifacts = {"lib": install.project("lib")}),
    ]


_custom_llvm = rule(
    impl = _custom_llvm_impl,
    attrs = {
        "jobs": attrs.int(),
        "cache": attrs.string(default = ""),
        "source": attrs.dep(),
        "_builder": attrs.source(default = "//stage0:build_custom_llvm.py"),
        "_python_bootstrap_toolchain": attrs.toolchain_dep(
            default = "toolchains//:python_bootstrap",
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
        urls = ["https://github.com/landaire/llvm-project/archive/" + _LLVM_COMMIT + ".tar.gz"],
    )
    _custom_llvm(
        name = name,
        jobs = jobs,
        cache = cache,
        source = ":" + name + "-source",
        incoming_transition = incoming_transition,
        visibility = visibility,
    )
