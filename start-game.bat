@echo off
rem Double-click to start R Code Quest in your browser.
rem Uses uv if installed (it fetches Python itself), otherwise Python.
cd /d "%~dp0"

where uv >nul 2>nul
if %errorlevel%==0 (
  set "RUN=uv run"
) else (
  set "RUN=python"
)

if not exist "vendor\webr\webr.mjs" (
  echo First run: downloading webR and R packages for offline play...
  %RUN% setup_offline.py
)
%RUN% serve.py
pause
