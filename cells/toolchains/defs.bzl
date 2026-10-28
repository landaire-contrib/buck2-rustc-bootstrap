def forward_toolchains(names: list[str]):
    # In a project that includes this repository as a cell, this directory is
    # an unused package of that cell, where `rust//` does not resolve.
    if read_root_config("cells", "rust") != ".":
        return
    for name in names:
        native.toolchain_alias(
            name = name,
            actual = "rust//toolchains:" + name,
            visibility = ["PUBLIC"],
        )
