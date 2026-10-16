# Real child-process fixture for desktop cancellation acceptance.
# Usage: Rscript worker_process_tree.R MARKER_DIRECTORY
# A ready marker appears only after both local PSOCK workers publish their PIDs.
# The caller must stop the whole process tree and verify all three PIDs stopped.
local({
  args <- commandArgs(TRUE)
  if (length(args) != 1L) stop("Expected one marker directory argument.")
  markers <- normalizePath(args[1L], winslash = "/", mustWork = TRUE)
  workers <- parallel::makePSOCKcluster(2L, outfile = file.path(markers, "workers.log"))
  on.exit(parallel::stopCluster(workers), add = TRUE)
  parallel::clusterCall(workers, function(directory) {
    pid <- Sys.getpid()
    writeLines(as.character(pid), file.path(directory, paste0("worker-", pid, ".pid")))
    pid
  }, markers)
  writeLines(as.character(Sys.getpid()), file.path(markers, "parent.pid"))
  writeLines("ready", file.path(markers, "ready"))
  Sys.sleep(600)
})
