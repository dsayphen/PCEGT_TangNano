import os
import subprocess
import sys

# Efface la console
os.system("cls")

# Lance pyserial miniterm
subprocess.run([
    sys.executable,
    "-m",
    "serial.tools.miniterm",
    "COM6",
    "115200"
])