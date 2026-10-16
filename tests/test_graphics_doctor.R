# Exercise real report devices and the warning-only backend failure seen on macOS.
source("R/load.R")
local({
  workspace <- tempfile("bmp-graphics-tests-"); dir.create(workspace)
  previous_wd <- getwd(); previous_devices <- grDevices::dev.list()
  on.exit({
    setwd(previous_wd)
    for (device in setdiff(grDevices::dev.list(), previous_devices)) grDevices::dev.off(device)
    unlink(workspace, recursive = TRUE)
  })
  setwd(workspace)
  before <- list.files(tempdir(), pattern = "^bmp-graphics-doctor-", full.names = TRUE)
  successful <- bmp_cli_doctor()
  stopifnot(isTRUE(successful$ok), all(unlist(successful$graphics)),
    identical(names(successful$graphics_exports), c("svg", "pdf", "png", "tiff")),
    all(vapply(successful$graphics_exports, function(value) isTRUE(value$ok) && value$bytes > 0, logical(1))),
    identical(grDevices::dev.list(), previous_devices), !file.exists("Rplots.pdf"))

  # Reproduce cairo.so's warning followed by a return without opening a device.
  unavailable <- function(path) warning("failed to load cairo DLL: /opt/X11/lib/libSM.6.dylib", call. = FALSE)
  failure <- bmp_cli_graphics_probe(list(svg = unavailable, pdf = unavailable))
  stopifnot(!failure$graphics$cairo, failure$graphics$png, failure$graphics$tiff,
    grepl("did not open", failure$exports$svg$error),
    grepl("libSM", failure$exports$svg$warnings),
    identical(grDevices::dev.list(), previous_devices), !file.exists("Rplots.pdf"))
  diagnosis <- bmp_cli_doctor
  environment(diagnosis) <- list2env(list(bmp_cli_graphics_probe = function() failure), parent = environment(bmp_cli_doctor))
  failed_doctor <- diagnosis()
  stopifnot(!failed_doctor$ok, !failed_doctor$graphics$cairo, grepl("XQuartz", failed_doctor$error),
    !jsonlite::fromJSON(bmp_cli_json(failed_doctor))$ok)

  # A failure after opening must close that device and preserve the caller's.
  grDevices::pdf("caller.pdf"); caller <- grDevices::dev.cur()
  opened_failure <- function(path) { grDevices::pdf(path); stop("injected backend failure") }
  failure <- bmp_cli_graphics_probe(list(pdf = opened_failure))
  stopifnot(!failure$graphics$cairo, grepl("injected", failure$exports$pdf$error),
    identical(grDevices::dev.cur(), caller), identical(grDevices::dev.list(), caller),
    !file.exists("Rplots.pdf"))
  grDevices::dev.off(caller)
  stopifnot(identical(list.files(tempdir(), pattern = "^bmp-graphics-doctor-", full.names = TRUE), before))
})
cat("Graphics doctor real exports, backend failures and cleanup passed.\n")
