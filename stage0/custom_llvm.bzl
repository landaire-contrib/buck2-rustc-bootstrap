load("@prelude//python_bootstrap:python_bootstrap.bzl", "PythonBootstrapToolchainInfo")
load("//stage1:defs.bzl", "RustDistInfo")

_LLVM_COMMIT = "ec73a37e92bbe8561ae98eab4cec6c4deaa95abc"
_LLVM_SHA256 = "92825f78c351f2a8c1afb2c91cb9ccf541ae6e9b161e360ce8f947df1a2c57bf"


def _custom_llvm_impl(ctx: AnalysisContext) -> list[Provider]:
    source = ctx.attrs.source[DefaultInfo].default_outputs[0]
    output = ctx.actions.declare_output("custom-llvm", dir = True)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._python_bootstrap_toolchain[PythonBootstrapToolchainInfo].interpreter,
            ctx.attrs._builder,
            "--source",
            source,
            "--output",
            output.as_output(),
            "--jobs",
            str(ctx.attrs.jobs),
        ),
        category = "custom_llvm",
        local_only = True,
        no_outputs_cleanup = True,
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
        "source": attrs.dep(),
        "_builder": attrs.source(default = "//stage0:build_custom_llvm.py"),
        "_python_bootstrap_toolchain": attrs.toolchain_dep(
            default = "toolchains//:python_bootstrap",
            providers = [PythonBootstrapToolchainInfo],
        ),
    },
    supports_incoming_transition = True,
)


def custom_llvm(name, jobs, visibility, incoming_transition):
    native.http_archive(
        name = name + "-source",
        sha256 = _LLVM_SHA256,
        strip_prefix = "llvm-project-" + _LLVM_COMMIT,
        urls = ["https://github.com/landaire/llvm-project/archive/" + _LLVM_COMMIT + ".tar.gz"],
    )
    _custom_llvm(
        name = name,
        jobs = jobs,
        source = ":" + name + "-source",
        incoming_transition = incoming_transition,
        visibility = visibility,
    )
