#!/usr/bin/env Rscript

# ============================================================================
# ORA_PPI_Analysis.R
# ----------------------------------------------------------------------------
# Over-Representation Analysis with PPI (Protein-Protein Interaction) integration.
# Fetches PPI data from STRING DB, combines with candidate genes, and runs
# pathway enrichment analysis using clusterProfiler (GO, KEGG, Reactome).
#
# Usage:
#   Rscript ORA_PPI_Analysis.R --input results/binary/auc_iterations.csv --output-dir results/binary/pathway
#   Rscript ORA_PPI_Analysis.R --genes "BRCA1;TP53;EGFR" --output-dir /tmp/pathway
# ============================================================================

suppressPackageStartupMessages({
  required_cran <- c("yaml", "dplyr", "readr", "stringr", "tibble",
                     "ggplot2", "igraph", "tidygraph", "ggraph",
                     "svglite", "jsonlite", "httr")
  required_bioc <- c("clusterProfiler", "org.Hs.eg.db", "enrichplot", "ReactomePA")

  install_missing_cran <- function(pkgs) {
    missing <- pkgs[!vapply(pkgs, requireNamespace, FUN.VALUE = logical(1), quietly = TRUE)]
    if (length(missing) > 0) {
      install.packages(missing, repos = "https://cloud.r-project.org", quiet = TRUE)
    }
  }

  install_missing_bioc <- function(pkgs) {
    missing <- pkgs[!vapply(pkgs, requireNamespace, FUN.VALUE = logical(1), quietly = TRUE)]
    if (length(missing) > 0) {
      if (!requireNamespace("BiocManager", quietly = TRUE)) {
        install.packages("BiocManager", repos = "https://cloud.r-project.org", quiet = TRUE)
      }
      BiocManager::install(missing, ask = FALSE, update = FALSE)
    }
  }

  install_missing_cran(required_cran)
  install_missing_bioc(required_bioc)

  library(dplyr)
  library(readr)
  library(stringr)
  library(tibble)
  library(ggplot2)
  library(igraph)
  library(tidygraph)
  library(ggraph)
  library(svglite)
  library(jsonlite)
  library(httr)
  library(clusterProfiler)
  library(enrichplot)
  library(org.Hs.eg.db)
})

options(stringsAsFactors = FALSE)

# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------

log_step <- function(current, total, message) {
  cat(sprintf("ORA_LOG:Step %d of %d - %s\n", current, total, message), file = stderr())
}

log_total <- function(total) {
  cat(sprintf("ORA_LOG:Total steps: %d\n", total), file = stderr())
}

log_done <- function() {
  cat("ORA_LOG:DONE\n", file = stderr())
}

log_info <- function(msg) {
  cat(sprintf("[INFO] %s\n", msg), file = stderr())
}

log_warn <- function(msg) {
  cat(sprintf("[WARN] %s\n", msg), file = stderr())
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  params <- list(
    input = NULL,
    genes = NULL,
    output_dir = "results/binary/pathway",
    ppi_confidence = 0.7,
    organism = 9606,
    skip_ppi = FALSE
  )

  i <- 1
  while (i <= length(args)) {
    arg <- args[i]
    if (grepl("^--input=", arg)) {
      params$input <- sub("^--input=", "", arg)
    } else if (arg == "--input" && i < length(args)) {
      i <- i + 1
      params$input <- args[i]
    } else if (grepl("^--genes=", arg)) {
      params$genes <- sub("^--genes=", "", arg)
    } else if (arg == "--genes" && i < length(args)) {
      i <- i + 1
      params$genes <- args[i]
    } else if (grepl("^--output-dir=", arg)) {
      params$output_dir <- sub("^--output-dir=", "", arg)
    } else if (arg == "--output-dir" && i < length(args)) {
      i <- i + 1
      params$output_dir <- args[i]
    } else if (grepl("^--ppi-confidence=", arg)) {
      params$ppi_confidence <- as.numeric(sub("^--ppi-confidence=", "", arg))
    } else if (arg == "--ppi-confidence" && i < length(args)) {
      i <- i + 1
      params$ppi_confidence <- as.numeric(args[i])
    } else if (grepl("^--organism=", arg)) {
      params$organism <- as.integer(sub("^--organism=", "", arg))
    } else if (arg == "--organism" && i < length(args)) {
      i <- i + 1
      params$organism <- as.integer(args[i])
    } else if (arg == "--skip-ppi") {
      params$skip_ppi <- TRUE
    }
    i <- i + 1
  }

  params
}

# --------------------------------------------------------------------------
# Gene extraction
# --------------------------------------------------------------------------

extract_genes_from_csv <- function(csv_path) {
  if (!file.exists(csv_path)) {
    stop(sprintf("Input file not found: %s", csv_path))
  }

  dat <- readr::read_csv(csv_path, show_col_types = FALSE)
  headers_lower <- tolower(gsub("[_\\s]", "", colnames(dat)))

  # Find gene column (flexible matching)
  gene_candidates <- c("selectedgenes", "genes", "selectedgene", "gene")
  gene_col_idx <- NA
  for (cand in gene_candidates) {
    idx <- which(headers_lower == cand)
    if (length(idx) > 0) {
      gene_col_idx <- idx[1]
      break
    }
  }

  if (is.na(gene_col_idx)) {
    stop("No gene column found in CSV. Expected: selected_genes, genes, gene")
  }

  all_genes <- dat[[gene_col_idx]]
  all_genes <- all_genes[!is.na(all_genes) & nzchar(trimws(all_genes))]

  if (length(all_genes) == 0) {
    stop("Gene column is empty")
  }

  # Split by semicolons, commas, or whitespace-plus patterns
  unique_genes <- unique(trimws(unlist(strsplit(
    paste(all_genes, collapse = ";"),
    "[;,]+"
  ))))
  unique_genes <- unique_genes[nzchar(unique_genes) & unique_genes != "+"]
  unique_genes
}

parse_gene_string <- function(gene_str) {
  genes <- trimws(unlist(strsplit(gene_str, "[;,]+")))
  genes <- genes[nzchar(genes)]
  unique(genes)
}

# --------------------------------------------------------------------------
# STRING API PPI fetch
# --------------------------------------------------------------------------

fetch_string_ppi <- function(genes, species = 9606, score_threshold = 0.7) {
  if (length(genes) == 0) {
    return(list(edges = data.frame(source = character(), target = character(),
                                    score = numeric(), stringsAsFactors = FALSE),
                interactors = character(0)))
  }

  # STRING API score is 0-1000, threshold is 0.0-1.0
  string_score <- as.integer(score_threshold * 1000)

  # STRING API has a limit; chunk if needed
  max_per_request <- 500
  all_edges <- data.frame(source = character(), target = character(),
                          score = numeric(), stringsAsFactors = FALSE)

  gene_chunks <- split(genes, ceiling(seq_along(genes) / max_per_request))

  for (chunk in gene_chunks) {
    identifiers <- paste(chunk, collapse = "%0d")
    url <- sprintf(
      "https://string-db.org/api/json/network?identifiers=%s&species=%d&required_score=%d&network_type=functional",
      identifiers, species, string_score
    )

    response <- tryCatch({
      resp <- httr::GET(url, httr::timeout(30))
      if (httr::status_code(resp) != 200) {
        log_warn(sprintf("STRING API returned status %d", httr::status_code(resp)))
        return(NULL)
      }
      jsonlite::fromJSON(httr::content(resp, "text", encoding = "UTF-8"))
    }, error = function(e) {
      log_warn(sprintf("STRING API request failed: %s", e$message))
      NULL
    })

    if (!is.null(response) && is.data.frame(response) && nrow(response) > 0) {
      chunk_edges <- data.frame(
        source = response$preferredName_A,
        target = response$preferredName_B,
        score  = response$score,
        stringsAsFactors = FALSE
      )
      all_edges <- rbind(all_edges, chunk_edges)
    }
  }

  if (nrow(all_edges) == 0) {
    return(list(edges = all_edges, interactors = character(0)))
  }

  # Remove duplicate edges
  all_edges <- all_edges %>%
    dplyr::distinct(source, target, .keep_all = TRUE)

  # Extract interactors not in original gene list
  all_proteins <- unique(c(all_edges$source, all_edges$target))
  interactors <- setdiff(all_proteins, genes)

  list(edges = all_edges, interactors = interactors)
}

# --------------------------------------------------------------------------
# Gene ID conversion
# --------------------------------------------------------------------------

convert_gene_ids <- function(genes) {
  conversion <- tryCatch(
    clusterProfiler::bitr(
      genes,
      fromType = "SYMBOL",
      toType = "ENTREZID",
      OrgDb = org.Hs.eg.db
    ),
    error = function(e) {
      log_warn(sprintf("Gene ID conversion failed: %s", e$message))
      NULL
    }
  )

  if (is.null(conversion) || nrow(conversion) == 0) {
    return(NULL)
  }

  unmapped <- setdiff(genes, conversion$SYMBOL)
  if (length(unmapped) > 0) {
    log_warn(sprintf("%d of %d genes could not be mapped: %s",
                     length(unmapped), length(genes),
                     paste(head(unmapped, 5), collapse = ", ")))
  }

  conversion
}

# --------------------------------------------------------------------------
# ORA Analysis
# --------------------------------------------------------------------------

run_go_enrichment <- function(entrez_ids, ont = "BP") {
  tryCatch(
    clusterProfiler::enrichGO(
      gene          = entrez_ids,
      OrgDb         = org.Hs.eg.db,
      keyType       = "ENTREZID",
      ont           = ont,
      pAdjustMethod = "BH",
      qvalueCutoff  = 0.05,
      readable      = TRUE
    ),
    error = function(e) {
      log_warn(sprintf("GO %s enrichment failed: %s", ont, e$message))
      NULL
    }
  )
}

run_kegg_enrichment <- function(entrez_ids) {
  tryCatch(
    clusterProfiler::enrichKEGG(
      gene          = entrez_ids,
      organism      = "hsa",
      pAdjustMethod = "BH",
      qvalueCutoff  = 0.05
    ),
    error = function(e) {
      log_warn(sprintf("KEGG enrichment failed: %s", e$message))
      NULL
    }
  )
}

run_reactome_enrichment <- function(entrez_ids) {
  if (!requireNamespace("ReactomePA", quietly = TRUE)) {
    log_warn("ReactomePA package not available, skipping Reactome analysis")
    return(NULL)
  }
  tryCatch(
    ReactomePA::enrichPathway(
      gene          = entrez_ids,
      organism      = "human",
      pAdjustMethod = "BH",
      qvalueCutoff  = 0.05,
      readable      = TRUE
    ),
    error = function(e) {
      log_warn(sprintf("Reactome enrichment failed: %s", e$message))
      NULL
    }
  )
}

# --------------------------------------------------------------------------
# Visualization
# --------------------------------------------------------------------------

save_dual_format <- function(plot_obj, path_stem, width = 10, height = 8) {
  tryCatch({
    ggplot2::ggsave(paste0(path_stem, ".svg"), plot_obj,
                    width = width, height = height, device = svglite::svglite)
    ggplot2::ggsave(paste0(path_stem, ".png"), plot_obj,
                    width = width, height = height, dpi = 300)
  }, error = function(e) {
    log_warn(sprintf("Failed to save plot %s: %s", path_stem, e$message))
  })
}

generate_enrichment_plots <- function(result, name, fig_dir) {
  if (is.null(result) || nrow(result@result) == 0) {
    log_info(sprintf("No significant terms for %s, skipping plots", name))
    return(invisible(NULL))
  }

  # Dotplot
  tryCatch({
    p <- enrichplot::dotplot(result, showCategory = 20) +
      ggplot2::theme_minimal(base_family = "Arial") +
      ggplot2::labs(title = sprintf("%s Enrichment", toupper(name)))
    save_dual_format(p, file.path(fig_dir, paste0(name, "_dotplot")))
  }, error = function(e) log_warn(sprintf("dotplot failed for %s: %s", name, e$message)))

  # Barplot (only for GO BP)
  if (grepl("go_bp", name)) {
    tryCatch({
      p <- barplot(result, showCategory = 15) +
        ggplot2::theme_minimal(base_family = "Arial") +
        ggplot2::labs(title = "GO Biological Process Enrichment")
      save_dual_format(p, file.path(fig_dir, paste0(name, "_barplot")))
    }, error = function(e) log_warn(sprintf("barplot failed for %s: %s", name, e$message)))
  }
}

generate_cnetplot <- function(result, fig_dir) {
  if (is.null(result) || nrow(result@result) == 0) return(invisible(NULL))

  tryCatch({
    p <- enrichplot::cnetplot(result, showCategory = 10, circular = FALSE) +
      ggplot2::theme_void(base_family = "Arial") +
      ggplot2::labs(title = "Gene-Pathway Network (GO:BP)")
    save_dual_format(p, file.path(fig_dir, "cnetplot"), width = 12, height = 10)
  }, error = function(e) log_warn(sprintf("cnetplot failed: %s", e$message)))
}

generate_emapplot <- function(result, fig_dir) {
  if (is.null(result) || nrow(result@result) == 0) return(invisible(NULL))

  tryCatch({
    result_sim <- enrichplot::pairwise_termsim(result)
    p <- enrichplot::emapplot(result_sim, showCategory = 30) +
      ggplot2::theme_void(base_family = "Arial") +
      ggplot2::labs(title = "Pathway Similarity Network (GO:BP)")
    save_dual_format(p, file.path(fig_dir, "emapplot"), width = 12, height = 10)
  }, error = function(e) log_warn(sprintf("emapplot failed: %s", e$message)))
}

generate_ppi_network_plot <- function(edges, candidate_genes, all_genes, fig_dir) {
  if (length(all_genes) == 0) return(invisible(NULL))

  nodes <- tibble::tibble(
    gene = all_genes,
    type = ifelse(all_genes %in% candidate_genes, "Candidate", "PPI Interactor")
  )

  if (nrow(edges) == 0) {
    g <- igraph::graph.empty(n = nrow(nodes))
    igraph::V(g)$name <- nodes$gene
    igraph::V(g)$type <- nodes$type
  } else {
    # Filter edges to only include genes we have
    edges_filtered <- edges %>%
      dplyr::filter(source %in% all_genes & target %in% all_genes)
    if (nrow(edges_filtered) == 0) {
      g <- igraph::graph.empty(n = nrow(nodes))
      igraph::V(g)$name <- nodes$gene
      igraph::V(g)$type <- nodes$type
    } else {
      g <- igraph::graph_from_data_frame(edges_filtered, vertices = nodes, directed = FALSE)
    }
  }

  layout <- tryCatch(
    ggraph::create_layout(tidygraph::as_tbl_graph(g), layout = "fr"),
    error = function(e) ggraph::create_layout(tidygraph::as_tbl_graph(g), layout = "stress")
  )

  tryCatch({
    p <- ggraph::ggraph(layout) +
      ggraph::geom_edge_link(aes(alpha = after_stat(index)), show.legend = FALSE, width = 0.4, colour = "grey60") +
      ggraph::geom_node_point(aes(shape = type, colour = type), size = 3.5) +
      ggraph::geom_node_text(aes(label = name), repel = TRUE, size = 2.8, family = "Arial") +
      scale_colour_manual(values = c("Candidate" = "#d7191c", "PPI Interactor" = "#2c7bb6")) +
      scale_shape_manual(values = c("Candidate" = 17, "PPI Interactor" = 19)) +
      labs(
        title = "Protein-Protein Interaction Network",
        subtitle = sprintf("%d candidate genes + %d PPI interactors",
                           sum(nodes$type == "Candidate"),
                           sum(nodes$type == "PPI Interactor")),
        colour = "Gene Type", shape = "Gene Type"
      ) +
      theme_void(base_family = "Arial") +
      theme(legend.position = "bottom")
    save_dual_format(p, file.path(fig_dir, "ppi_network"), width = 12, height = 10)
  }, error = function(e) log_warn(sprintf("PPI network plot failed: %s", e$message)))
}

# --------------------------------------------------------------------------
# Export helpers
# --------------------------------------------------------------------------

export_enrichment_csv <- function(result, name, output_dir) {
  if (is.null(result) || nrow(result@result) == 0) {
    # Write empty CSV with header
    readr::write_csv(tibble::tibble(
      ID = character(), Description = character(), GeneRatio = character(),
      BgRatio = character(), pvalue = numeric(), p.adjust = numeric(),
      qvalue = numeric(), geneID = character(), Count = integer()
    ), file.path(output_dir, paste0("ora_", name, ".csv")))
    return(invisible(NULL))
  }
  readr::write_csv(result@result, file.path(output_dir, paste0("ora_", name, ".csv")))
}

write_summary_json <- function(candidate_genes, ppi_interactors, all_genes,
                                ppi_confidence, organism, ora_results, output_dir) {
  get_summary <- function(result) {
    if (is.null(result) || nrow(result@result) == 0) {
      return(list(significantTerms = 0, topTerm = ""))
    }
    sig <- result@result %>% dplyr::filter(p.adjust < 0.05)
    list(
      significantTerms = nrow(sig),
      topTerm = if (nrow(sig) > 0) sig$Description[1] else ""
    )
  }

  summary_data <- list(
    candidateGenes = candidate_genes,
    candidateGeneCount = length(candidate_genes),
    ppiInteractors = ppi_interactors,
    ppiInteractorCount = length(ppi_interactors),
    totalGenesAnalyzed = length(all_genes),
    ppiConfidence = ppi_confidence,
    organism = organism,
    results = list(
      go_bp = get_summary(ora_results$go_bp),
      go_mf = get_summary(ora_results$go_mf),
      go_cc = get_summary(ora_results$go_cc),
      kegg = get_summary(ora_results$kegg),
      reactome = get_summary(ora_results$reactome)
    ),
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  )

  jsonlite::write_json(summary_data, file.path(output_dir, "summary.json"),
                       auto_unbox = TRUE, pretty = TRUE)
}

# --------------------------------------------------------------------------
# Main workflow
# --------------------------------------------------------------------------

main <- function() {
  params <- parse_args()
  total_steps <- 8
  log_total(total_steps)

  # ---- Step 1: Parse candidate genes ----
  log_step(1, total_steps, "Parsing candidate genes")

  candidate_genes <- if (!is.null(params$genes) && nzchar(params$genes)) {
    parse_gene_string(params$genes)
  } else if (!is.null(params$input) && nzchar(params$input)) {
    extract_genes_from_csv(params$input)
  } else {
    stop("Either --genes or --input must be provided")
  }

  if (length(candidate_genes) == 0) {
    stop("No candidate genes found")
  }
  log_info(sprintf("Found %d candidate genes: %s",
                   length(candidate_genes),
                   paste(head(candidate_genes, 10), collapse = ", ")))

  # Create output directories
  output_dir <- params$output_dir
  fig_dir <- file.path(output_dir, "figures")
  dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

  # ---- Step 2: Fetch PPI from STRING DB ----
  log_step(2, total_steps, "Fetching PPI from STRING DB")

  ppi_interactors <- character(0)
  ppi_edges <- data.frame(source = character(), target = character(),
                          score = numeric(), stringsAsFactors = FALSE)

  if (!params$skip_ppi) {
    ppi_result <- fetch_string_ppi(candidate_genes,
                                    species = params$organism,
                                    score_threshold = params$ppi_confidence)
    if (!is.null(ppi_result)) {
      ppi_edges <- ppi_result$edges
      ppi_interactors <- ppi_result$interactors
      log_info(sprintf("PPI: %d interactions found, %d interactors added",
                       nrow(ppi_edges), length(ppi_interactors)))
    } else {
      log_warn("PPI fetch failed, proceeding with candidate genes only")
    }
  } else {
    log_info("PPI fetch skipped (--skip-ppi)")
  }

  # Combine genes
  all_genes <- unique(c(candidate_genes, ppi_interactors))
  log_info(sprintf("Total genes for analysis: %d (%d candidates + %d interactors)",
                   length(all_genes), length(candidate_genes), length(ppi_interactors)))

  # Export PPI data
  readr::write_csv(ppi_edges, file.path(output_dir, "ppi_network.csv"))
  if (length(ppi_interactors) > 0 && nrow(ppi_edges) > 0) {
    # Build interactor table with source gene and best score
    interactor_details <- ppi_edges %>%
      tidyr::pivot_longer(cols = c(source, target), names_to = "role", values_to = "gene") %>%
      dplyr::filter(gene %in% ppi_interactors) %>%
      dplyr::mutate(source_gene = ifelse(role == "source",
                                          ppi_edges$target[match(score, ppi_edges$score)],
                                          ppi_edges$source[match(score, ppi_edges$score)])) %>%
      dplyr::select(gene, source_gene, score) %>%
      dplyr::group_by(gene) %>%
      dplyr::slice_max(score, n = 1, with_ties = FALSE) %>%
      dplyr::ungroup()
    readr::write_csv(interactor_details, file.path(output_dir, "ppi_interactors.csv"))
  } else if (length(ppi_interactors) > 0) {
    readr::write_csv(
      tibble::tibble(gene = ppi_interactors, source_gene = NA_character_, score = NA_real_),
      file.path(output_dir, "ppi_interactors.csv")
    )
  }

  # ---- Step 3: Gene ID conversion ----
  log_step(3, total_steps, "Gene ID conversion (SYMBOL to ENTREZID)")

  gene_mapping <- convert_gene_ids(all_genes)
  if (is.null(gene_mapping)) {
    stop("Failed to map any gene symbols to Entrez IDs")
  }
  readr::write_csv(gene_mapping, file.path(output_dir, "gene_mapping.csv"))
  entrez_ids <- unique(gene_mapping$ENTREZID)
  log_info(sprintf("Mapped %d genes to %d Entrez IDs", nrow(gene_mapping), length(entrez_ids)))

  # ---- Step 4: GO enrichment analysis ----
  log_step(4, total_steps, "GO enrichment analysis (BP, MF, CC)")

  ora_results <- list()
  for (ont in c("BP", "MF", "CC")) {
    ora_results[[paste0("go_", tolower(ont))]] <- run_go_enrichment(entrez_ids, ont)
    result <- ora_results[[paste0("go_", tolower(ont))]]
    if (!is.null(result) && nrow(result@result) > 0) {
      sig_count <- sum(result@result$p.adjust < 0.05)
      log_info(sprintf("GO %s: %d significant terms", ont, sig_count))
    } else {
      log_info(sprintf("GO %s: no significant terms", ont))
    }
  }

  # ---- Step 5: KEGG pathway analysis ----
  log_step(5, total_steps, "KEGG pathway analysis")

  ora_results$kegg <- run_kegg_enrichment(entrez_ids)
  if (!is.null(ora_results$kegg) && nrow(ora_results$kegg@result) > 0) {
    sig_count <- sum(ora_results$kegg@result$p.adjust < 0.05)
    log_info(sprintf("KEGG: %d significant pathways", sig_count))
  } else {
    log_info("KEGG: no significant pathways")
  }

  # ---- Step 6: Reactome pathway analysis ----
  log_step(6, total_steps, "Reactome pathway analysis")

  ora_results$reactome <- run_reactome_enrichment(entrez_ids)
  if (!is.null(ora_results$reactome) && nrow(ora_results$reactome@result) > 0) {
    sig_count <- sum(ora_results$reactome@result$p.adjust < 0.05)
    log_info(sprintf("Reactome: %d significant pathways", sig_count))
  } else {
    log_info("Reactome: no significant pathways")
  }

  # ---- Step 7: Generating visualizations ----
  log_step(7, total_steps, "Generating visualizations")

  # PPI network plot
  generate_ppi_network_plot(ppi_edges, candidate_genes, all_genes, fig_dir)

  # Enrichment plots per category
  for (name in c("go_bp", "go_mf", "go_cc", "kegg", "reactome")) {
    generate_enrichment_plots(ora_results[[name]], name, fig_dir)
  }

  # Combined plots (using GO BP as primary)
  generate_cnetplot(ora_results$go_bp, fig_dir)
  generate_emapplot(ora_results$go_bp, fig_dir)

  # ---- Step 8: Exporting results ----
  log_step(8, total_steps, "Exporting results")

  # Export enrichment CSVs
  for (name in c("go_bp", "go_mf", "go_cc", "kegg", "reactome")) {
    export_enrichment_csv(ora_results[[name]], name, output_dir)
  }

  # Write summary JSON
  write_summary_json(candidate_genes, ppi_interactors, all_genes,
                     params$ppi_confidence, params$organism, ora_results, output_dir)

  log_info(sprintf("Results written to: %s", output_dir))
  log_done()
}

# Run
main()
