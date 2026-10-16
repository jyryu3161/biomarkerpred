@echo off
setlocal
if "%~1"=="--help" goto help
if "%~1"=="-h" goto help
if "%~1"=="" goto missing
if not defined BMP_DOCKER_PATH set "BMP_DOCKER_PATH=docker"
if not defined BMP_DOCKER_IMAGE set "BMP_DOCKER_IMAGE=jyryu3161/biomarkerpred:v0.5.0"
set "BMP_LAUNCH_IMAGE_ID="
REM The extra outer quotes survive cmd /c parsing of an executable path with spaces.
for /f "delims=" %%I in ('""%BMP_DOCKER_PATH%" image inspect --format "{{.Id}}" "%BMP_DOCKER_IMAGE%""') do set "BMP_LAUNCH_IMAGE_ID=%%I"
if not defined BMP_LAUNCH_IMAGE_ID (
  echo Cannot inspect the local engine image. Run docker pull jyryu3161/biomarkerpred:v0.5.0 first. 1>&2
  exit /b 1
)
"%BMP_DOCKER_PATH%" run --rm --pull never --volume "%cd%:/work" --workdir /work --env "BMP_IMAGE_DIGEST=%BMP_LAUNCH_IMAGE_ID%" "%BMP_LAUNCH_IMAGE_ID%" %*
exit /b %errorlevel%
:missing
echo Provide a CLI command; see --help. 1>&2
exit /b 2
:help
echo Usage: run_docker.bat COMMAND [CLI OPTIONS]
echo Fetch explicitly: docker pull jyryu3161/biomarkerpred:v0.5.0
echo Local builds: set BMP_DOCKER_IMAGE=biomarkerpred-engine:local
echo The current directory is mounted at /work, the container working directory.
echo Use /work/... paths or config-relative paths; absolute Windows paths are not translated.
echo Files outside the current directory are not mounted; use the desktop or explicit Docker mounts.
echo Override BMP_DOCKER_IMAGE or BMP_DOCKER_PATH if needed. Images are never pulled automatically.
echo The inspected image identity is recorded in scientific provenance.
echo Example: run_docker.bat validate --config /work/config/analysis.json --json
echo Full engine help: run_docker.bat help
exit /b 0
