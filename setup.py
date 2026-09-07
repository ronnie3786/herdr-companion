"""Bundle companion assets without requiring the original source checkout."""
from pathlib import Path
import shutil

from setuptools import setup
from setuptools.command.build_py import build_py


class BuildWithResources(build_py):
    def run(self):
        super().run()
        source = Path(__file__).parent
        destination = Path(self.build_lib) / "herdr_harness" / "_bundled"
        bridge = source / "pi-semantic-bridge"
        destination.mkdir(parents=True, exist_ok=True)
        if not (bridge / "package.json").is_file():
            raise RuntimeError("The Pi extension source is missing from the build input")
        target = destination / "pi-semantic-bridge"
        target.mkdir(exist_ok=True)
        shutil.copy2(bridge / "package.json", target / "package.json")
        shutil.copytree(bridge / "extensions", target / "extensions", dirs_exist_ok=True)
        shutil.copy2(source / "config.example.toml", destination / "config.example.toml")


setup(cmdclass={"build_py": BuildWithResources})
