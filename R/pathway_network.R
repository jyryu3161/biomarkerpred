# STRING transport only transmits public gene identifiers, never patient rows.
# Override transport(endpoint, parameters) for offline tests; raw response bytes
# and exact request parameters are retained in the independent pathway artifact.
bmp_string_transport <- function(endpoint, parameters) {
  body <- paste(vapply(names(parameters), function(key) paste0(utils::URLencode(key, reserved = TRUE), "=", utils::URLencode(as.character(parameters[[key]]), reserved = TRUE)), character(1)), collapse = "&")
  if (requireNamespace("curl", quietly = TRUE)) {
    handle <- curl::new_handle(postfields = body, timeout = 60L, connecttimeout = 20L)
    curl::handle_setheaders(handle, "Content-Type" = "application/x-www-form-urlencoded")
    response <- curl::curl_fetch_memory(endpoint, handle)
    if (response$status_code < 200L || response$status_code >= 300L) stop(sprintf("STRING HTTP request failed (%s).", response$status_code), call. = FALSE)
    return(rawToChar(response$content))
  }
  address <- paste0(endpoint, "?", body)
  if (nchar(address, type = "bytes") > 7000L) stop("STRING request exceeds the safe GET length. Install the optional R curl package for POST transport or reduce the query size.", call. = FALSE)
  destination <- tempfile("bmp-string-"); on.exit(unlink(destination), add = TRUE)
  previous <- options(timeout = max(60, getOption("timeout", 60))); on.exit(options(previous), add = TRUE)
  status <- utils::download.file(address, destination, method = "libcurl", quiet = TRUE, mode = "wb")
  if (!identical(status, 0L)) stop("STRING download failed.", call. = FALSE)
  rawToChar(readBin(destination, "raw", n = file.info(destination)$size))
}
bmp_string_empty_edges <- function() data.frame(source = character(), target = character(), score = numeric(), nscore = numeric(), fscore = numeric(), pscore = numeric(), ascore = numeric(), escore = numeric(), dscore = numeric(), tscore = numeric(), stringsAsFactors = FALSE)
bmp_string_network <- function(genes, species = 9606L, add_nodes = 0L, score = 400L, transport = NULL, cache_dir = NULL) {
  genes <- bmp_pathway_clean_ids(genes)
  if (any(grepl("[\r\n]", genes))) stop("STRING identifiers cannot contain newline separators.", call. = FALSE)
  for (pair in list(c(species, 1, 2147483646), c(add_nodes, 0, 1000), c(score, 0, 1000))) if (length(pair) != 3L || !is.finite(pair[1]) || pair[1] != floor(pair[1]) || pair[1] < pair[2] || pair[1] > pair[3]) stop("Invalid STRING species, add_nodes (0..1000), or score (0..1000).", call. = FALSE)
  nodes <- data.frame(id = character(), gene = character(), original = logical(), query_genes = character(), stringsAsFactors = FALSE)
  edges <- bmp_string_empty_edges()
  mapping <- data.frame(source_id = genes, target_id = rep(NA_character_, length(genes)), preferred_name = rep(NA_character_, length(genes)), status = rep("unmapped", length(genes)), stringsAsFactors = FALSE)
  base <- "https://version-12-5.string-db.org/api/json"
  requests <- list(); using_default <- is.null(transport)
  if (using_default) transport <- bmp_string_transport
  request <- function(method, parameters) {
    endpoint <- paste0(base, "/", method)
    if (using_default && length(requests)) Sys.sleep(1)
    record <- list(endpoint = endpoint, parameters = parameters, requested_at = bmp_now(), status = "requested")
    save_record <- function() {
      if (!is.null(cache_dir)) {
        dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
        bmp_atomic_json(record, file.path(cache_dir, paste0(method, "-request.json")))
      }
    }
    save_record()
    tryCatch({
      text <- transport(endpoint, parameters)
      if (!is.character(text) || length(text) != 1L || !nzchar(text)) stop("STRING transport must return nonempty raw JSON text.", call. = FALSE)
      record$response_sha256 <- digest::digest(text, algo = "sha256", serialize = FALSE)
      if (!is.null(cache_dir)) {
        destination <- file.path(cache_dir, paste0(method, ".json")); writeBin(charToRaw(enc2utf8(text)), destination)
        record$response_file <- basename(destination)
      }
      decoded <- jsonlite::fromJSON(text, simplifyVector = FALSE)
      if (!is.list(decoded) || !is.null(names(decoded))) stop(paste("STRING returned an error or unexpected JSON object for", method), call. = FALSE)
      record$status <- "completed"; save_record()
      requests[[length(requests) + 1L]] <<- record
      decoded
    }, error = function(error) {
      record$status <<- "failed"; record$error <<- conditionMessage(error); save_record()
      stop(error)
    })
  }
  if (!length(genes)) return(list(status = "not_applicable", reason = "The frozen final model selected no genes.", nodes = nodes, edges = edges, mapping = mapping, requests = requests, source = base, version = "12.5"))
  raw_mapping <- request("get_string_ids", list(identifiers = paste(genes, collapse = "\r"), species = as.integer(species), echo_query = 1L, caller_identity = "BioMarkerPred"))
  for (i in seq_along(genes)) {
    candidates <- Filter(function(row) identical(as.character(row$queryItem), genes[i]) || (is.null(row$queryItem) && identical(as.integer(row$queryIndex), i - 1L)), raw_mapping)
    targets <- unique(vapply(candidates, function(row) if (is.null(row$stringId)) "" else as.character(row$stringId), character(1)))
    targets <- targets[nzchar(targets)]
    if (length(targets) > 1L) mapping$status[i] <- "ambiguous_excluded"
    else if (length(targets) == 1L) {
      candidate <- candidates[[which(vapply(candidates, function(row) identical(as.character(row$stringId), targets), logical(1)))[1L]]]
      if (!is.null(candidate$ncbiTaxonId) && as.character(candidate$ncbiTaxonId) != as.character(species)) stop("STRING identifier mapping returned an unexpected species.", call. = FALSE)
      mapping$target_id[i] <- targets; mapping$preferred_name[i] <- if (is.null(candidate$preferredName)) genes[i] else as.character(candidate$preferredName); mapping$status[i] <- "mapped"
    }
  }
  collapsed <- names(which(table(mapping$target_id) > 1L))
  mapping$status[!is.na(mapping$target_id) & mapping$target_id %in% collapsed] <- "mapped_collapsed"
  good <- mapping[!is.na(mapping$target_id), , drop = FALSE]
  ids <- bmp_pathway_clean_ids(good$target_id)
  if (!length(ids)) stop("STRING could not unambiguously map any original gene; this is not evidence of absent interactions.", call. = FALSE)
  for (id in ids) {
    rows <- good[good$target_id == id, , drop = FALSE]
    nodes <- rbind(nodes, data.frame(id = id, gene = rows$preferred_name[1], original = TRUE, query_genes = paste(rows$source_id, collapse = ";"), stringsAsFactors = FALSE))
  }
  raw_edges <- request("network", list(identifiers = paste(ids, collapse = "\r"), species = as.integer(species), required_score = as.integer(score), add_nodes = as.integer(add_nodes), network_type = "functional", caller_identity = "BioMarkerPred"))
  for (row in raw_edges) {
    fields <- c("stringId_A", "stringId_B", "preferredName_A", "preferredName_B", "score")
    if (!all(fields %in% names(row))) stop("STRING network response lacks required interaction fields.", call. = FALSE)
    a <- as.character(row$stringId_A); b <- as.character(row$stringId_B); value <- suppressWarnings(as.numeric(row$score))
    if (length(value) != 1L || !is.finite(value) || value < 0 || value > 1 || !nzchar(a) || !nzchar(b)) stop("STRING network contains invalid identifiers or scores.", call. = FALSE)
    if (!startsWith(a, paste0(species, ".")) || !startsWith(b, paste0(species, "."))) stop("STRING network contains an unexpected species.", call. = FALSE)
    if (add_nodes == 0 && (!a %in% ids || !b %in% ids)) stop("STRING expanded the network despite explicit add_nodes=0; refusing hidden expansion.", call. = FALSE)
    if (value + 1e-12 < score/1000) next
    for (side in c("A", "B")) {
      id <- as.character(row[[paste0("stringId_", side)]])
      if (!id %in% nodes$id) nodes <- rbind(nodes, data.frame(id = id, gene = as.character(row[[paste0("preferredName_", side)]]), original = id %in% ids, query_genes = "", stringsAsFactors = FALSE))
    }
    if (a != b) {
      pair <- sort(c(a, b)); edge <- data.frame(source = pair[1], target = pair[2], score = value, stringsAsFactors = FALSE)
      for (channel in c("nscore", "fscore", "pscore", "ascore", "escore", "dscore", "tscore")) {
        value_channel <- if (is.null(row[[channel]])) NA_real_ else suppressWarnings(as.numeric(row[[channel]]))
        if (length(value_channel) != 1L || (!is.na(value_channel) && (!is.finite(value_channel) || value_channel < 0 || value_channel > 1))) stop("STRING evidence-channel score must be absent or a number in [0,1].", call. = FALSE)
        edge[[channel]] <- value_channel
      }
      edges <- rbind(edges, edge)
    }
  }
  if (nrow(edges)) { edges <- edges[order(edges$source, edges$target, -edges$score), , drop = FALSE]; edges <- edges[!duplicated(edges[c("source", "target")]), , drop = FALSE] }
  unmapped <- mapping$source_id[is.na(mapping$target_id)]
  list(status = if (length(unmapped)) "partial" else "completed", reason = if (length(unmapped)) "Some original genes could not be unambiguously mapped to STRING; inspect mapping table." else if (!nrow(edges)) "Successful STRING response contains no interactions at the requested confidence and expansion settings." else NULL,
    nodes = nodes, edges = edges, mapping = mapping, mapping_policy = "STRING best-match identifier mapping is recorded; original aliases resolving to one STRING identifier collapse to one graph node. Annotation mapping remains a separate declared statistical unit.", requests = requests, source = base, version = "12.5", species = species, add_nodes = add_nodes, required_score = score,
    interpretation = "STRING functional associations; an edge does not establish a direct physical interaction or causal mechanism.")
}
