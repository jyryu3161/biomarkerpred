# Atomic directory locks protect one run from concurrent CLI mutations.
# PID alone is insufficient across containers, hosts and reboot/PID reuse.
bmp_lock_context <- function() {
  read_one <- function(path) if (file.exists(path)) paste(readLines(path, warn = FALSE), collapse = "") else "unknown"
  namespace <- if (file.exists("/proc/self/ns/pid")) Sys.readlink("/proc/self/ns/pid") else "unknown"
  list(host = unname(Sys.info()["nodename"]), boot = read_one("/proc/sys/kernel/random/boot_id"), pid_namespace = namespace)
}
bmp_process_identity <- function(pid) {
  path <- file.path("/proc", as.character(pid), "stat")
  if (dir.exists("/proc")) {
    if (!file.exists(path)) return(list(alive = FALSE, start = NULL))
    line <- tryCatch(readLines(path, warn = FALSE), error = function(error) character())
    if (!length(line)) return(list(alive = NA, start = NULL))
    fields <- strsplit(sub("^.*\\) ", "", line[1L]), " +")[[1L]]
    return(list(alive = !fields[1L] %in% c("Z", "X"), start = fields[20L]))
  }
  # Portable uncertainty is deliberate: no automatic stale takeover unless
  # termination can be verified, or the explicit cross-context token is supplied.
  list(alive = if (identical(as.integer(pid), Sys.getpid())) TRUE else NA, start = NULL)
}
bmp_lock_acquire <- function(run_dir, operation, recover_token = NULL) {
  path <- file.path(run_dir, ".mutation.lock"); recovery <- file.path(run_dir, ".lock-recovery")
  context <- bmp_lock_context()
  if (dir.exists(recovery)) stop("Another process is recovering this run lock; retry after it finishes.", call. = FALSE)
  if (!dir.create(path, showWarnings = FALSE)) {
    owner_path <- file.path(path, "owner.json")
    if (!file.exists(owner_path)) stop("Run lock is being initialized or has incomplete owner metadata. Verify the owning process has stopped before manually removing .mutation.lock.", call. = FALSE)
    owner <- bmp_read_json(owner_path)
    same <- identical(bmp_hash_object(owner$context), bmp_hash_object(context))
    identity <- if (same) bmp_process_identity(owner$pid) else list(alive = NA, start = NULL)
    alive <- isTRUE(identity$alive) && (is.null(owner$process_start) || identical(identity$start, owner$process_start))
    if (alive) stop(sprintf("Run is locked by live PID %s (%s). Wait or cancel that process; locks cannot be stolen.", owner$pid, owner$operation), call. = FALSE)
    stopped <- same && (identical(identity$alive, FALSE) || (isTRUE(identity$alive) && !is.null(owner$process_start) && !identical(identity$start, owner$process_start)))
    explicit <- !is.null(recover_token) && identical(as.character(recover_token), owner$token)
    if (!stopped && !explicit) stop(paste("Cannot verify termination of the run-lock owner in this host/container context. Verify that original process/container has stopped, then explicitly acknowledge with --recover-lock", owner$token), call. = FALSE)
    if (!dir.create(recovery, showWarnings = FALSE)) stop("Another process is recovering the run lock.", call. = FALSE)
    on.exit(unlink(recovery, recursive = TRUE), add = TRUE)
    latest <- bmp_read_json(owner_path)
    if (!identical(latest$token, owner$token)) stop("Run-lock owner changed during recovery; retry.", call. = FALSE)
    archived <- file.path(run_dir, paste0(".stale-lock-", owner$token))
    if (!file.rename(path, archived)) stop("Unable to archive stale run lock.", call. = FALSE)
    if (!dir.create(path, showWarnings = FALSE)) stop("Another process acquired the run while stale ownership was being recovered.", call. = FALSE)
  }
  token <- basename(tempfile(pattern = paste0(Sys.getpid(), "-")))
  owner <- list(schema_version = 1L, token = token, pid = Sys.getpid(), process_start = bmp_process_identity(Sys.getpid())$start,
    context = context, operation = operation, acquired_at = bmp_now())
  tryCatch(bmp_atomic_json(owner, file.path(path, "owner.json")), error = function(error) { unlink(path, recursive = TRUE); stop(error) })
  list(path = path, token = token)
}
bmp_lock_release <- function(lock) {
  if (is.null(lock) || !dir.exists(lock$path)) return(invisible(FALSE))
  path <- file.path(lock$path, "owner.json")
  owner <- tryCatch(bmp_read_json(path), error = function(error) NULL)
  if (!is.null(owner) && identical(owner$token, lock$token)) { unlink(lock$path, recursive = TRUE); return(invisible(TRUE)) }
  invisible(FALSE)
}
