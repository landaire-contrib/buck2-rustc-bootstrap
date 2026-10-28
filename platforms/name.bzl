load(
    "@prelude//cfg/modifier:cfg_constructor.bzl",
    "PostConstraintAnalysisParams",
    prelude_post_constraint_analysis = "cfg_constructor_post_constraint_analysis",
)
load("@prelude//platforms:defs.bzl", "host_configuration")

def platform_info_label(constraints: dict[TargetLabel, ConstraintValueInfo]) -> str:
    # Keyed by package and name: the cell name of this repository depends on
    # the project that uses it.
    settings = {}
    cell = None
    for constraint in constraints.values():
        setting = constraint.setting.label
        key = "{}:{}".format(setting.package, setting.name)
        if key == "constraints:bootstrap":
            cell = setting.cell
        if constraint.label.sub_target:
            settings[key] = "-".join(constraint.label.sub_target)
        else:
            settings[key] = constraint.label.name

    stage = settings.get("constraints:bootstrap-stage")
    workspace = settings.get("constraints:workspace")
    build_script = settings.get("constraints:build-script")
    os = settings.get("os/constraints:os")
    cpu = settings.get("cpu/constraints:cpu")

    host_os = host_configuration.os.split(":")[1]
    host_cpu = host_configuration.cpu.split(":")[1]

    if cell and not stage and not workspace and not build_script and os == host_os and cpu == host_cpu:
        return "{}//platforms:host".format(cell)

    if cell and stage and workspace and build_script:
        label = "{}//platforms/{}:{}".format(cell, stage, workspace)
        if build_script == "build-script=true":
            label += "-build-script"
        return label

    if os and cpu:
        return "{}-{}".format(os, cpu)

    if os or cpu:
        return os or cpu

    if len(settings) == 0:
        return "null"

    return "cfg"

def set_standalone_cfg_constructor(**kwargs):
    """Installs a configuration constructor when this is the root cell.

    Only the root cell's package file may install one, so a parent project
    that uses this repository as a cell keeps its own.
    """
    if read_root_config("cells", "rust") == ".":
        native.set_cfg_constructor(**kwargs)

def cfg_constructor_post_constraint_analysis(
        *,
        refs: dict[str, ProviderCollection],
        params: PostConstraintAnalysisParams) -> PlatformInfo:
    platform = prelude_post_constraint_analysis(refs = refs, params = params)
    return PlatformInfo(
        label = platform_info_label(platform.configuration.constraints),
        configuration = platform.configuration,
    )
