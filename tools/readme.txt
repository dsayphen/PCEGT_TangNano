.\build_profiles.ps1 -Profile sgx

powershell -ExecutionPolicy Bypass -File .\build_profiles.ps1 -Profile cd

Image	Adresse flash
SGX	0x100000
CD	0x200000
Superset	0x300000