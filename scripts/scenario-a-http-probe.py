#!/usr/bin/env python3
import runpy
from pathlib import Path
runpy.run_path(str(Path(__file__).resolve().parent / "scenario-a/scenario-a-http-probe.py"), run_name="__main__")
