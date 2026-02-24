#!/usr/bin/env Rscript

# ============================================================================
# Postprocess_Coexpression_Enrichment.R
# ----------------------------------------------------------------------------
# Builds gene co-expression networks and performs GO enrichment analysis for
# binary marker sets produced by the drug response prediction workflows.
# The script is designed to run independently from the main analysis pipeline.
# ============================================================================

suppressPackageStartupMessages({
  # Base dependencies required for configuration parsing and data handling
  required_cran <- c(
    "yaml", "dplyr", "tidyr", "readr", "stringr", "tibble",
    "purrr", "ggplot2", "igraph", "tidygraph", "ggraph"
  )
  required_bioc <- c("clusterProfiler", "org.Hs.eg.db", "enrichplot")

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

  library(yaml)
  library(dplyr)
  library(tidyr)
  library(readr)
  library(stringr)
  library(tibble)
  library(purrr)
  library(ggplot2)
  library(igraph)
  library(tidygraph)
  library(ggraph)
  library(clusterProfiler)
  library(enrichplot)
  library(org.Hs.eg.db)
})

options(stringsAsFactors = FALSE)

# --------------------------------------------------------------------------
# Helper functions
# --------------------------------------------------------------------------

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  config_file <- "config/example_analysis.yaml"

  if (length(args) > 0) {
    idx <- grep("^--config", args)
    if (length(idx) > 0) {
      if (args[idx] == "--config" && length(args) > idx) {
        config_file <- args[idx + 1]
      } else if (grepl("^--config=", args[idx])) {
        config_file <- sub("^--config=", "", args[idx])
      }
    }
  }

  list(config = config_file)
}

load_configuration <- function(path) {
  if (!file.exists(path)) {
    stop(sprintf("Configuration file not found: %s", path))
  }
  config <- yaml::read_yaml(path)
  if (!is.null(config$workdir)) {
    setwd(config$workdir)
  }
  config
}

resolve_data_file <- function(mode_config, global_config) {
  if (!is.null(mode_config$data_file)) {
    return(mode_config$data_file)
  }
  if (!is.null(global_config$data_file)) {
    return(global_config$data_file)
  }
  "Example_data.csv"
}

resolve_threshold <- function(config) {
  default <- 0.7
  if (!is.null(config$coexpression) && !is.null(config$coexpression$correlation_threshold)) {
    value <- suppressWarnings(as.numeric(config$coexpression$correlation_threshold))
    if (!is.na(value) && value > 0 && value <= 1) {
      return(value)
    }
  }
  default
}

extract_marker_genes <- function(result_path) {
  if (!file.exists(result_path)) {
    message(sprintf("[WARN] Missing stepwise result: %s", result_path))
    return(character())
  }
  tbl <- readr::read_csv(result_path, show_col_types = FALSE)
  if (!"Variable" %in% colnames(tbl)) {
    message(sprintf("[WARN] 'Variable' column not found in %s", result_path))
    return(character())
  }
  vars <- tbl$Variable
  vars <- vars[!is.na(vars) & nzchar(vars)]
  if (length(vars) == 0) {
    return(character())
  }
  unique(str_trim(unlist(strsplit(vars[1], "\\+"))))
}

prepare_expression_matrix <- function(data_file, exclude_cols, sample_id = NULL) {
  if (!file.exists(data_file)) {
    stop(sprintf("Data file not found: %s", data_file))
  }
  dat <- readr::read_csv(data_file, show_col_types = FALSE)
  keep_cols <- setdiff(colnames(dat), exclude_cols)
  expr <- dat[, keep_cols, drop = FALSE]

  numeric_cols <- vapply(expr, is.numeric, logical(1))
  if (!all(numeric_cols)) {
    expr[!numeric_cols] <- lapply(expr[!numeric_cols], function(x) suppressWarnings(as.numeric(x)))
    numeric_cols <- vapply(expr, is.numeric, logical(1))
  }
  expr <- expr[, numeric_cols, drop = FALSE]

  if (!is.null(sample_id) && sample_id %in% colnames(dat)) {
    rownames(expr) <- dat[[sample_id]]
  }

  expr
}

build_network_edges <- function(expr_matrix, genes, threshold) {
  if (length(genes) < 2) {
    return(tibble::tibble(source = character(), target = character(), correlation = numeric()))
  }
  cor_mat <- stats::cor(expr_matrix[, genes, drop = FALSE], use = "pairwise.complete.obs")
  cor_mat[is.na(cor_mat)] <- 0
  idx <- which(upper.tri(cor_mat), arr.ind = TRUE)
  tibble::tibble(
    source = colnames(cor_mat)[idx[, 1]],
    target = colnames(cor_mat)[idx[, 2]],
    correlation = cor_mat[idx]
  ) %>%
    dplyr::filter(abs(correlation) >= threshold)
}

export_network_plot <- function(edges, nodes, output_file, threshold) {
  if (nrow(nodes) == 0) {
    warning(sprintf("No nodes available for plotting: %s", output_file))
    return(invisible(NULL))
  }
  if (nrow(edges) == 0) {
    g <- igraph::graph.empty(n = nrow(nodes))
    igraph::V(g)$name <- nodes$gene
    igraph::V(g)$type <- nodes$type
  } else {
    g <- igraph::graph_from_data_frame(edges, vertices = nodes, directed = FALSE)
  }

  layout <- tryCatch(
    ggraph::create_layout(tidygraph::as_tbl_graph(g), layout = "fr"),
    error = function(e) ggraph::create_layout(tidygraph::as_tbl_graph(g), layout = "stress")
  )

  plot <- ggraph::ggraph(layout) +
    ggraph::geom_edge_link(aes(color = correlation), show.legend = TRUE, width = 0.6) +
    ggraph::geom_node_point(aes(shape = type, color = type), size = 3) +
    ggraph::geom_node_text(aes(label = name), repel = TRUE, size = 3) +
    scale_edge_color_gradient2(
      low = "#2c7bb6", mid = "#f7f7f7", high = "#d7191c", midpoint = 0,
      name = "Correlation"
    ) +
    scale_color_manual(values = c(Marker = "#1b7837", Coexpressed = "#762a83")) +
    scale_shape_manual(values = c(Marker = 17, Coexpressed = 19)) +
    labs(
      title = "Co-expression network",
      subtitle = sprintf("Absolute Pearson correlation ≥ %.2f", threshold),
      color = "Gene type", shape = "Gene type"
    ) +
    theme_minimal()

  ggplot2::ggsave(output_file, plot, width = 8, height = 6, dpi = 300)
}

perform_go_enrichment <- function(genes) {
  if (length(genes) == 0) {
    return(NULL)
  }
  conversion <- tryCatch(
    clusterProfiler::bitr(
      genes,
      fromType = "SYMBOL",
      toType = "ENTREZID",
      OrgDb = org.Hs.eg.db
    ),
    error = function(e) NULL
  )
  if (is.null(conversion) || nrow(conversion) == 0) {
    message("[WARN] Failed to map gene symbols to Entrez IDs for GO enrichment.")
    return(NULL)
  }
  unique_ids <- unique(conversion$ENTREZID)
  if (length(unique_ids) == 0) {
    return(NULL)
  }
  tryCatch(
    clusterProfiler::enrichGO(
      gene = unique_ids,
      OrgDb = org.Hs.eg.db,
      keyType = "ENTREZID",
      ont = "BP",
      pAdjustMethod = "BH",
      qvalueCutoff = 0.05,
      readable = TRUE
    ),
    error = function(e) {
      message(sprintf("[WARN] GO enrichment failed: %s", e$message))
      NULL
    }
  )
}

export_go_plot <- function(go_results, output_file) {
  if (is.null(go_results) || nrow(go_results@result) == 0) {
    message("[INFO] No significant GO terms to plot.")
    return(invisible(NULL))
  }
  plot <- enrichplot::dotplot(go_results, showCategory = 20) +
    ggplot2::theme_minimal() +
    ggplot2::labs(title = "GO Biological Process enrichment")
  ggplot2::ggsave(output_file, plot, width = 8, height = 6, dpi = 300)
}

write_gene_table <- function(output_file, markers, coexpressed) {
  tibble::tibble(
    gene = c(markers, setdiff(coexpressed, markers)),
    type = c(rep("Marker", length(markers)), rep("Coexpressed", length(setdiff(coexpressed, markers))))
  ) %>%
    readr::write_csv(output_file)
}

write_edge_table <- function(output_file, edges) {
  readr::write_csv(edges, output_file)
}

# --------------------------------------------------------------------------
# Main workflow
# --------------------------------------------------------------------------

main <- function() {
  args <- parse_args()
  config <- load_configuration(args$config)
  threshold <- resolve_threshold(config)

  modes <- list(
    binary = list(
      key = "binary",
      step_dir = "StepBin",
      extra_exclude = function(cfg) {
        fields <- c(cfg$sample_id %||% "sample", cfg$outcome %||% "Outcome")
        if (!is.null(cfg$time_variable) && nzchar(cfg$time_variable)) {
          fields <- c(fields, cfg$time_variable)
        }
        unique(fields)
      }
    )
  )

  `%||%` <- function(x, y) if (!is.null(x) && nzchar(x)) x else y

  for (mode_name in names(modes)) {
    mode <- modes[[mode_name]]
    mode_cfg <- config[[mode$key]]
    if (is.null(mode_cfg)) {
      message(sprintf("[INFO] Skipping %s mode (configuration missing)", mode_name))
      next
    }

    data_file <- resolve_data_file(mode_cfg, config)
    output_dir <- mode_cfg$output_dir %||% sprintf("results/%s", mode_name)
    coexp_dir <- file.path(output_dir, "coexpression")
    dir.create(coexp_dir, recursive = TRUE, showWarnings = FALSE)

    step_file <- file.path(output_dir, mode$step_dir, "Final_Stepwise_Total.csv")
    markers <- extract_marker_genes(step_file)
    if (length(markers) == 0) {
      message(sprintf("[INFO] No marker genes found for %s mode. Skipping.", mode_name))
      next
    }

    exclude_cols <- mode$extra_exclude(mode_cfg)
    expr <- prepare_expression_matrix(data_file, exclude_cols, sample_id = mode_cfg$sample_id %||% "sample")

    missing_markers <- setdiff(markers, colnames(expr))
    if (length(missing_markers) > 0) {
      message(sprintf(
        "[WARN] The following marker genes are absent from the expression matrix and will be ignored: %s",
        paste(missing_markers, collapse = ", ")
      ))
      markers <- intersect(markers, colnames(expr))
    }

    if (length(markers) == 0) {
      message(sprintf("[INFO] No usable marker genes remain for %s mode after filtering. Skipping.", mode_name))
      next
    }

    cor_matrix <- stats::cor(expr[, markers, drop = FALSE], expr, use = "pairwise.complete.obs")
    cor_matrix[is.na(cor_matrix)] <- 0

    selected <- colnames(expr)[apply(abs(cor_matrix) >= threshold, 2, any)]
    selected <- union(selected, markers)

    expr_sub <- expr[, selected, drop = FALSE]

    edges <- build_network_edges(expr_sub, colnames(expr_sub), threshold)
    nodes <- tibble::tibble(
      gene = colnames(expr_sub),
      type = ifelse(colnames(expr_sub) %in% markers, "Marker", "Coexpressed")
    )

    write_gene_table(file.path(coexp_dir, "selected_genes.csv"), markers, colnames(expr_sub))
    write_edge_table(file.path(coexp_dir, "coexpression_edges.csv"), edges)
    export_network_plot(edges, nodes, file.path(coexp_dir, "coexpression_network.png"), threshold)

    go_results <- perform_go_enrichment(colnames(expr_sub))
    if (!is.null(go_results) && nrow(go_results@result) > 0) {
      readr::write_csv(go_results@result, file.path(coexp_dir, "go_enrichment_results.csv"))
    } else {
      message(sprintf("[INFO] No significant GO terms detected for %s mode.", mode_name))
    }
    export_go_plot(go_results, file.path(coexp_dir, "go_enrichment_dotplot.png"))

    message(sprintf("[INFO] Completed co-expression analysis for %s mode (threshold = %.2f).", mode_name, threshold))
  }
}

main()

