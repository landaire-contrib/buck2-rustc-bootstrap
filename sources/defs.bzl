"""The source tree of the Rust fork, assembled from the archives in BUCK."""

_BACKTRACE = "library/backtrace/"

def _source(ctx: AnalysisContext, path: str) -> Artifact:
    if path.startswith(_BACKTRACE):
        backtrace = ctx.attrs._backtrace[DefaultInfo].default_outputs[0]
        return backtrace.project(path.removeprefix(_BACKTRACE))
    return ctx.attrs._rust[DefaultInfo].default_outputs[0].project(path)

def _rust_source_files_impl(ctx: AnalysisContext) -> list[Provider]:
    return [DefaultInfo(sub_targets = {
        path: [DefaultInfo(default_output = _source(ctx, path))]
        for path in ctx.attrs.paths
    })]

# Files or directories of the source tree, each as the subtarget named by its
# path relative to the root of the tree.
rust_source_files = rule(
    impl = _rust_source_files_impl,
    attrs = {
        "paths": attrs.list(attrs.string()),
        "_backtrace": attrs.default_only(attrs.dep(default = "//sources:backtrace")),
        "_rust": attrs.default_only(attrs.dep(default = "//sources:rust")),
    },
)

def _rust_version_flags_impl(ctx: AnalysisContext) -> list[Provider]:
    version = _source(ctx, "src/version")
    suffix = ctx.attrs.version_suffix
    flags = ctx.actions.declare_output("version-flags")

    def write_flags(ctx: AnalysisContext, artifacts, outputs):
        release = artifacts[version].read_string().strip()
        ctx.actions.write(outputs[flags], [
            "--env-set=CFG_RELEASE=" + release,
            "--env-set=CFG_VERSION={} {}".format(release, suffix),
        ])

    ctx.actions.dynamic_output(
        dynamic = [version],
        inputs = [],
        outputs = [flags.as_output()],
        f = write_flags,
    )
    return [DefaultInfo(default_output = flags)]

# An argument file of rustc flags that set the compiler version for env!.
rust_version_flags = rule(
    impl = _rust_version_flags_impl,
    attrs = {
        "version_suffix": attrs.string(),
        "_backtrace": attrs.default_only(attrs.dep(default = "//sources:backtrace")),
        "_rust": attrs.default_only(attrs.dep(default = "//sources:rust")),
    },
)

def _rust_checkout_impl(ctx: AnalysisContext) -> list[Provider]:
    checkout = ctx.actions.declare_output("rust", dir = True)
    ctx.actions.run(
        [
            ctx.attrs._frob[RunInfo],
            cmd_args(checkout.as_output(), format = "checkout={}"),
            "--overlay",
            ctx.attrs._rust[DefaultInfo].default_outputs[0],
            "{checkout}",
            "--overlay",
            ctx.attrs._backtrace[DefaultInfo].default_outputs[0],
            "{checkout}/" + _BACKTRACE.removesuffix("/"),
        ],
        category = "rust_checkout",
    )
    return [DefaultInfo(default_output = checkout)]

rust_checkout = rule(
    impl = _rust_checkout_impl,
    attrs = {
        "_backtrace": attrs.default_only(attrs.dep(default = "//sources:backtrace")),
        "_frob": attrs.default_only(attrs.exec_dep(providers = [RunInfo], default = "//stage0:frob")),
        "_rust": attrs.default_only(attrs.dep(default = "//sources:rust")),
    },
)
