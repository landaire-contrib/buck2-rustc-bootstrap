load("@prelude//:rules.bzl", "rust_library")
load("@prelude//rust:cargo_buildscript.bzl", "buildscript_run")
load("@prelude//rust:cargo_package.bzl", "apply_platform_attrs")
load("@prelude//rust:proc_macro_alias.bzl", "rust_proc_macro_alias")
load("@prelude//utils:type_defs.bzl", "is_select")
load("//constraints:defs.bzl", "transition_alias")
load("//sources:defs.bzl", "rust_source_files")

# Paths under rust/ name files of the Rust source tree, which comes from
# //sources rather than from this repository.
_RUST_TREE = "rust/"

def _rust_tree_paths(paths):
    return [path for path in paths if path.startswith(_RUST_TREE)]

def _rust_tree_files(name, paths):
    """Declares `name` with `paths` from the source tree as subtargets.

    Returns a function from such a path to the label of its subtarget.
    """
    rust_source_files(
        name = name,
        paths = [path.removeprefix(_RUST_TREE) for path in paths],
    )
    return lambda path: ":{}[{}]".format(name, path.removeprefix(_RUST_TREE))

def _rust_tree_srcs(name, srcs):
    """Splits `srcs` into local sources and `mapped_srcs` of the source tree."""
    paths = _rust_tree_paths(srcs)
    if not paths:
        return srcs, {}
    label = _rust_tree_files("{}-rust-srcs".format(name), paths)
    local = [src for src in srcs if not src.startswith(_RUST_TREE)]
    return local, {label(path): path for path in paths}

def rust_bootstrap_alias(actual, **kwargs):
    if not actual.endswith("-0.0.0"):
        native.alias(
            actual = actual,
            target_compatible_with = _target_constraints(None),
            **kwargs
        )

def rust_bootstrap_binary(
        name,
        crate,
        crate_root,
        platform = {},
        rustc_flags = [],
        srcs = [],
        **kwargs):
    extra_rustc_flags = []

    if crate_root.startswith("rust/library/"):
        default_target_platform = "//platforms/stage1:library-build-script"
    elif crate_root.startswith("rust/compiler/") or crate_root.startswith("rust/src/"):
        default_target_platform = "//platforms/stage1:compiler"
    else:
        default_target_platform = "//platforms/stage1:compiler"
        extra_rustc_flags.append("--cap-lints=allow")

    srcs, mapped_srcs = _rust_tree_srcs(name, srcs)

    native.rust_binary(
        name = name,
        crate = crate,
        crate_root = crate_root,
        default_target_platform = default_target_platform,
        mapped_srcs = mapped_srcs,
        rustc_flags = rustc_flags + extra_rustc_flags,
        srcs = srcs,
        target_compatible_with = _target_constraints(crate_root),
        **apply_platform_attrs(platform, kwargs)
    )

def rust_bootstrap_library(
        name,
        crate,
        crate_root,
        deps = [],
        env = {},
        platform = {},
        preferred_linkage = None,
        proc_macro = False,
        rustc_flags = [],
        srcs = [],
        target_compatible_with = None,
        visibility = None,
        **kwargs):
    extra_deps = []
    extra_env = {}
    extra_rustc_flags = []

    if crate_root.startswith("rust/library/"):
        default_target_platform = "//platforms/stage1:library"
    elif crate_root.startswith("rust/compiler/") or crate_root.startswith("rust/src/"):
        default_target_platform = "//platforms/stage1:compiler"
        extra_env["CFG_RELEASE_CHANNEL"] = "dev"
        extra_env["CFG_COMPILER_HOST_TRIPLE"] = "$(target_triple)"
        extra_deps.append("//toolchains/target:rustc_target_triple")

        # CFG_RELEASE and CFG_VERSION, from the source tree's src/version.
        extra_rustc_flags.append("@$(location //sources:version-flags)")
    else:
        default_target_platform = None
        extra_rustc_flags.append("--cap-lints=allow")

    srcs, mapped_srcs = _rust_tree_srcs(name, srcs)

    target_compatible_with = target_compatible_with or _target_constraints(crate_root)

    if name.endswith("-0.0.0"):
        versioned_name = name
        name = name.removesuffix("-0.0.0")
        native.alias(
            name = versioned_name,
            actual = ":{}".format(name),
            default_target_platform = default_target_platform,
            target_compatible_with = target_compatible_with,
        )
        visibility = ["PUBLIC"]

    if proc_macro:
        rust_proc_macro_alias(
            name = name,
            actual_exec = ":_{}".format(name),
            actual_plugin = ":_{}".format(name),
            default_target_platform = default_target_platform,
            target_compatible_with = target_compatible_with,
            visibility = visibility,
        )
        name = "_{}".format(name)
        visibility = []

    rust_library(
        name = name,
        crate = crate,
        crate_root = crate_root,
        default_target_platform = default_target_platform,
        mapped_srcs = mapped_srcs,
        preferred_linkage = preferred_linkage or "static",
        proc_macro = proc_macro,
        srcs = srcs,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
        **apply_platform_attrs(platform, kwargs | dict(
            deps = deps + extra_deps,
            env = env + extra_env if is_select(env) else env | extra_env,
            rustc_flags = rustc_flags + extra_rustc_flags,
        ))
    )

def rust_bootstrap_buildscript_run(name, local_manifest_dir = None, **kwargs):
    if local_manifest_dir and local_manifest_dir.startswith(_RUST_TREE):
        label = _rust_tree_files("{}-manifest-dir".format(name), [local_manifest_dir])
        kwargs["manifest_dir"] = label(local_manifest_dir)
        local_manifest_dir = None

    constraints = _target_constraints(None)
    buildscript_run(
        name = name,
        local_manifest_dir = local_manifest_dir,
        target_compatible_with = constraints,
        buildscript_compatible_with = select({
            "DEFAULT": ["prelude//:none"],
            "//constraints:build-script=true": constraints,
        }),
        **kwargs
    )

def cxx_bootstrap_library(
        name,
        deps = [],
        headers = [],
        srcs = [],
        target_compatible_with = [],
        visibility = None,
        **kwargs):
    extra_deps = ["//toolchains/cxx:stdlib"]

    source_paths = [src if type(src) == "string" else src[0] for src in srcs]
    tree_paths = _rust_tree_paths(source_paths + headers)
    if tree_paths:
        label = _rust_tree_files("{}-rust-srcs".format(name), tree_paths)

        def from_tree(src):
            return label(src) if src.startswith(_RUST_TREE) else src

        headers = [from_tree(header) for header in headers]
        srcs = [
            from_tree(src) if type(src) == "string" else (from_tree(src[0]), src[1])
            for src in srcs
        ]

    target_compatible_with = [
        select({
            "DEFAULT": "prelude//:none",
        } | {
            constraint: constraint
            for constraint in disjunction.split(" || ")
        })
        for disjunction in target_compatible_with
    ]

    native.cxx_library(
        name = "{}-compile".format(name),
        deps = deps + extra_deps,
        headers = headers,
        preferred_linkage = "static",
        default_target_platform = "//platforms:host",
        srcs = srcs,
        target_compatible_with = target_compatible_with,
        **kwargs
    )

    transition_alias(
        name = name,
        actual = ":{}-compile".format(name),
        incoming_transition = "//toolchains/cxx:prune_cxx_configuration",
        default_target_platform = "//platforms:host",
        target_compatible_with = target_compatible_with,
        visibility = visibility,
    )

def _target_constraints(crate_root):
    if crate_root and crate_root.startswith("rust/library/"):
        target_compatible_with = ["//constraints:library"]
    elif crate_root and (crate_root.startswith("rust/compiler/") or crate_root.startswith("rust/src/")):
        target_compatible_with = ["//constraints:compiler"]
    else:
        target_compatible_with = select({
            "DEFAULT": ["prelude//:none"],
            "//constraints:compiler": [],
            "//constraints:library": [],
        })

    return target_compatible_with
