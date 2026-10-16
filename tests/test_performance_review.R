# Independent numerical equivalence checks for the optimized primitives.
script <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())][1L])
repo <- dirname(dirname(normalizePath(script, mustWork = TRUE)))
source(file.path(repo, "R", "load.R"))
near <- function(actual, expected, tolerance = 1e-9) {
  stopifnot(isTRUE(all.equal(as.numeric(actual), as.numeric(expected), tolerance = tolerance)))
}
config <- bmp_load_config(list(analysis_type = "binary", data_file = file.path(repo, "tests", "fixtures", "binary.csv"), sample_id = "sample", group_column = "patient",
  outcome = "response", positive_class = "1", negative_class = "0", p_adjust_method = "fdr"))
set.seed(191)
patients <- sprintf("patient_%02d", 1:30)
for (iteration in seq_len(40)) {
  multiplicity <- sample(1:4, length(patients), replace = TRUE)
  data <- data.frame(sample = sprintf("%06d", seq_len(sum(multiplicity))),
    patient = rep(patients, multiplicity), response = rep(rep(c("0", "1"), 15), multiplicity))
  genes <- paste0("quoted, gene ", 1:12)
  for (gene in genes) {
    values <- rnorm(nrow(data))
    values[sample.int(nrow(data), floor(nrow(data) * .25))] <- NA_real_
    data[[gene]] <- values
  }
  data[[genes[2]]] <- 3 # Same constant/insufficient guard as the declared policy.
  data[[genes[3]]] <- NA_real_
  data[[genes[4]]] <- as.numeric(data$response) + rnorm(nrow(data), sd = .2)
  data[[genes[5]]] <- 1e12 + rnorm(nrow(data))
  stats <- bmp_screen_statistics(data, config, genes)
  expected_p <- numeric(length(genes))
  for (index in seq_along(genes)) {
    gene <- genes[index]
    x <- data[[gene]]
    expected <- if (sum(!is.na(x)) < 3 || length(unique(x[!is.na(x)])) < 2) NULL else {
      means <- tapply(x, data$patient, function(value) if (all(is.na(value))) NA_real_ else mean(value, na.rm = TRUE))
      y <- data$response[match(names(means), data$patient)] == "1"
      tryCatch(stats::t.test(means[y], means[!y]), error = function(error) NULL)
    }
    actual <- stats[match(gene, stats$gene), ]
    if (is.null(expected)) {
      stopifnot(is.na(actual$statistic), is.na(actual$p_value), nzchar(actual$reason))
      expected_p[index] <- NA_real_
    } else {
      near(actual$statistic, expected$statistic)
      near(actual$p_value, expected$p.value)
      expected_p[index] <- expected$p.value
    }
  }
  near(stats$adjusted_p[match(genes, stats$gene)], stats::p.adjust(expected_p, "fdr", n = length(genes)))
}
cat("Independent vectorized patient-mean Welch review passed with uneven repeats, missing values and constants.\n")

for (iteration in seq_len(100)) {
  y <- rbinom(50, 1, .4)
  p <- sample(seq(0, 1, .1), 50, replace = TRUE)
  weights <- sample(c(.1, .25, 1, 2, 3), 50, replace = TRUE)
  positive <- which(y == 1); negative <- which(y == 0)
  numerator <- sum(vapply(positive, function(i) sum(weights[i] * weights[negative] *
    ((p[i] > p[negative]) + .5 * (p[i] == p[negative]))), numeric(1)))
  reference <- numerator / (sum(weights[positive]) * sum(weights[negative]))
  actual <- bmp_binary_metrics(y, p, weights = weights, curves = FALSE)
  near(actual$metrics$roc_auc$estimate, reference)
  time <- sample(1:10, 50, replace = TRUE)
  event <- rbinom(50, 1, .6)
  lp <- sample(0:5, 50, replace = TRUE)
  pair <- bmp_concordance_pairs(time, event, lp, weights)
  # Package reference uses case weights as pair products and reverse risk.
  reference_c <- survival::concordance(survival::Surv(time, event) ~ lp,
    weights = weights, reverse = TRUE, timefix = FALSE)$concordance
  near(pair$numerator / pair$denominator, reference_c)
}
cat("Independent weighted/tied ROC and survival-concordance review passed.\n")
