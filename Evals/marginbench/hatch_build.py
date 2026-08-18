"""Mark the wheel honestly: it contains the pinned x86-64 Linux Margin binary."""

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version, build_data) -> None:
        build_data["tag"] = "py3-none-manylinux_2_35_x86_64"
        build_data["pure_python"] = False
