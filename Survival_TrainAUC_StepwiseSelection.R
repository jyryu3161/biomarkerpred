library(nsROC)
library(caret)
library(survival)
library(ggplot2)
library(tiff)
library(reshape2)
# Try to load svglite, but don't fail if not available
if (!requireNamespace("svglite", quietly = TRUE)) {
  cat("STEPWISE_LOG:svglite not available, will use base svg instead\n", file = stderr())
}

# === Font detection (shared pattern) ===
available_fonts <- systemfonts::system_fonts()$family
PLOT_FONT <- if ("Arial" %in% available_fonts) {
  "Arial"
} else if ("Helvetica" %in% available_fonts) {
  "Helvetica"
} else {
  "sans"
}

# Helper function for Nature-style theme
nature_theme <- function(base_size = 10, base_family = PLOT_FONT) {
  theme_classic(base_size = base_size, base_family = base_family) +
    theme(
      plot.title = element_text(size = base_size + 2, face = "bold", hjust = 0.5, 
                                margin = margin(b = 8)),
      axis.title = element_text(size = base_size + 1, face = "bold", color = "black"),
      axis.text = element_text(size = base_size, color = "black"),
      axis.line = element_line(color = "black", linewidth = 0.5),
      axis.ticks = element_line(color = "black", linewidth = 0.5),
      legend.title = element_text(size = base_size, face = "bold", color = "black"),
      legend.text = element_text(size = base_size, color = "black"),
      legend.position = "right",
      legend.key = element_blank(),
      legend.background = element_blank(),
      panel.background = element_rect(fill = "white", color = NA),
      plot.background = element_rect(fill = "white", color = NA),
      strip.background = element_blank(),
      strip.text = element_text(size = base_size, face = "bold")
    )
}

# Nature color palette
nature_colors <- list(
  blue = "#1f77b4",
  red = "#d62728",
  green = "#2ca02c",
  orange = "#ff7f0e",
  purple = "#9467bd",
  brown = "#8c564b",
  pink = "#e377c2",
  gray = "#7f7f7f",
  yellow = "#bcbd22",
  cyan = "#17becf"
)

# Helper to create consistent tertile-based risk groups
# (이전 수정에서 이미 수정된 버전)
assign_risk_groups <- function(scores, labels = c("Low", "Medium", "High"), log_file = NULL) {
  if (length(scores) == 0 || all(is.na(scores))) {
    return(factor(rep(NA_character_, length(scores)), levels = labels))
  }

  # Log initial statistics
  if (!is.null(log_file)) {
    write(paste("\n=== assign_risk_groups called ==="), file = log_file, append = TRUE)
    write(paste("Total scores:", length(scores)), file = log_file, append = TRUE)
    write(paste("NA scores:", sum(is.na(scores))), file = log_file, append = TRUE)
    write(paste("Valid scores:", sum(!is.na(scores))), file = log_file, append = TRUE)
    write(paste("Score range:", min(scores, na.rm=TRUE), "to", max(scores, na.rm=TRUE)), file = log_file, append = TRUE)
    write(paste("Score mean:", mean(scores, na.rm=TRUE), "SD:", sd(scores, na.rm=TRUE)), file = log_file, append = TRUE)
  }

  probs <- seq(0, 1, length.out = length(labels) + 1)
  breaks <- quantile(scores, probs = probs, na.rm = TRUE, names = FALSE)

  if (!is.null(log_file)) {
    write(paste("Quantile breaks:", paste(breaks, collapse=", ")), file = log_file, append = TRUE)
    write(paste("Unique breaks:", length(unique(breaks)), "out of", length(breaks)), file = log_file, append = TRUE)
  }

  if (length(unique(breaks)) == length(breaks)) {
    # Use cut when all breaks are unique
    groups <- cut(scores, breaks = breaks, include.lowest = TRUE, labels = labels)
    if (!is.null(log_file)) {
      write("Using cut() method for group assignment", file = log_file, append = TRUE)
      write(paste("Group distribution after cut():"), file = log_file, append = TRUE)
      tbl <- table(groups, useNA = "always")
      write(paste(capture.output(print(tbl)), collapse="\n"), file = log_file, append = TRUE)
    }
    return(factor(groups, levels = labels))
  } else {
    # Manual assignment when breaks are not unique (e.g., many identical scores)
    if (!is.null(log_file)) {
      write("Using manual assignment (breaks not unique)", file = log_file, append = TRUE)
    }
    
    groups <- rep(NA_character_, length(scores))
    valid_idx <- which(!is.na(scores))
    n_valid <- length(valid_idx)
    
    if (n_valid > 0) {
      ordered_idx <- valid_idx[order(scores[valid_idx])]
      n_labels <- length(labels)
      
      base_size <- floor(n_valid / n_labels)
      rem <- n_valid %% n_labels
      
      group_sizes <- rep(base_size, n_labels)
      if (rem > 0) {
        group_sizes[1:rem] <- group_sizes[1:rem] + 1
      }
      
      if (!is.null(log_file)) {
        write(paste("Manual split - n_valid:", n_valid, "n_labels:", n_labels), file = log_file, append = TRUE)
        write(paste("Manual split - base_size:", base_size, "remainder:", rem), file = log_file, append = TRUE)
        write(paste("Manual split - group sizes:", paste(group_sizes, collapse=", ")), file = log_file, append = TRUE)
      }

      current_idx <- 1
      for (i in seq_along(labels)) {
        group_n <- group_sizes[i]
        if (group_n > 0) {
          start <- current_idx
          end <- current_idx + group_n - 1
          
          if (end > n_valid) { end <- n_valid } # Safeguard

          if (start <= end) {
             groups[ordered_idx[start:end]] <- labels[i]
             if (!is.null(log_file)) {
               write(paste("  Group", labels[i], "- indices", start, "to", end, "(n=", end-start+1, ")"), file = log_file, append = TRUE)
             }
             current_idx <- end + 1
          }
        }
      }
    }

    if (!is.null(log_file)) {
      write(paste("Group distribution after manual assignment:"), file = log_file, append = TRUE)
      tbl <- table(groups, useNA = "always")
      write(paste(capture.output(print(tbl)), collapse="\n"), file = log_file, append = TRUE)
    }

    return(factor(groups, levels = labels))
  }
}

# Helper function to save plots
save_plot <- function(plot_obj, filename_base, width_inch = 7, height_inch = 5, is_ggplot = TRUE) {
  if (!dir.exists("figures")) {
    dir.create("figures", recursive = TRUE)
  }
  filename_base <- file.path("figures", filename_base)
  
  if (is_ggplot) {
    tryCatch({
      tiff(filename = paste0(filename_base, ".tiff"), width = width_inch * 300, height = height_inch * 300, units = "px", res = 300, compression = "lzw")
      print(plot_obj)
      dev.off()
    }, error = function(e) {
      try(dev.off(), silent = TRUE)
      cat(paste("STEPWISE_LOG:Warning - Failed to save TIFF:", e$message, "\n"), file = stderr())
    })

    tryCatch({
      if (requireNamespace("svglite", quietly = TRUE)) {
        svglite::svglite(file = paste0(filename_base, ".svg"), width = width_inch, height = height_inch)
      } else {
        svg(filename = paste0(filename_base, ".svg"), width = width_inch, height = height_inch)
      }
      print(plot_obj)
      dev.off()
    }, error = function(e) {
      try(dev.off(), silent = TRUE)
      cat(paste("STEPWISE_LOG:Warning - Failed to save SVG:", e$message, "\n"), file = stderr())
    })
  } else {
    tryCatch({
      tiff(filename = paste0(filename_base, ".tiff"), width = width_inch * 300, height = height_inch * 300, units = "px", res = 300, compression = "lzw")
      print(plot_obj)
      dev.off()
    }, error = function(e) {
      try(dev.off(), silent = TRUE)
      cat(paste("STEPWISE_LOG:Warning - Failed to save TIFF:", e$message, "\n"), file = stderr())
    })

    tryCatch({
      if (requireNamespace("svglite", quietly = TRUE)) {
        svglite::svglite(file = paste0(filename_base, ".svg"), width = width_inch, height = height_inch)
      } else {
        svg(filename = paste0(filename_base, ".svg"), width = width_inch, height = height_inch)
      }
      print(plot_obj)
      dev.off()
    }, error = function(e) {
      try(dev.off(), silent = TRUE)
      cat(paste("STEPWISE_LOG:Warning - Failed to save SVG:", e$message, "\n"), file = stderr())
    })
  }
}

Extract_CandidGene <- function(dat,numSeed,SplitProp,totvar,outcandir,Freq,top_k=NULL,p_adjust_method="fdr",p_threshold=0.05){
  total_vars <- length(totvar)
  cat(paste("STEPWISE_LOG:Processing", total_vars, "variables across", numSeed, "iterations\n"), file = stderr())
  cat(paste("STEPWISE_LOG:P-value adjustment method:", p_adjust_method, ", threshold:", p_threshold, "\n"), file = stderr())
  if (!is.null(top_k)) {
    cat(paste("STEPWISE_LOG:Top-k selection enabled: selecting top", top_k, "genes per iteration\n"), file = stderr())
  }

  for (s in seq(numSeed)){
    if (s %% 10 == 0 || s == 1) {
      cat(paste("STEPWISE_LOG:Iteration", s, "of", numSeed, "(", round(s/numSeed*100, 1), "%)\n"), file = stderr())
    }
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Event, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]

      n_tr_0 <- sum(trdat$Event == 0)
      n_tr_1 <- sum(trdat$Event == 1)

      if (min(n_tr_0, n_tr_1) >= 2) break
    }
    tmpres <- NULL
    var_count <- 0
    valid_var_count <- 0
    for (j in match(totvar,colnames(dat))){
      var_name <- colnames(trdat)[j]
      var_count <- var_count + 1

      if (var_count %% 50 == 0) {
        cat(paste("STEPWISE_LOG:Iteration", s, "- Processing variable", var_count, "of", total_vars, "\n"), file = stderr())
      }

      if (length(unique(trdat[,var_name])) <= 1 || any(is.na(trdat[,var_name]))){
        next
      }
      tryCatch({
        f=as.formula(paste('Surv(Survtime,Event) ~ ',var_name,collapse = ''))
        suppressWarnings({
          CoxPHres<-coxph(f,data = trdat)
        })
        if (!is.null(CoxPHres) && !is.null(summary(CoxPHres)$coef)){
          coef_summary <- summary(CoxPHres)$coef
          if (nrow(coef_summary) >= 1 && ncol(coef_summary) >= 5 && all(is.finite(coef_summary[1,c(1:3,5)]))){
            tmpres <- rbind(tmpres,c(var_name,coef_summary[1,c(1:3,5)]))
            valid_var_count <- valid_var_count + 1
          }
        }
      }, error = function(e) {}, warning = function(w) {})
    }
    if(s==1){
      dir.create(outcandir)
    }
    if (!is.null(tmpres) && nrow(tmpres) > 0) {
      # Apply p-value adjustment and filtering
      tmpres_df <- data.frame(tmpres, stringsAsFactors = FALSE)
      colnames(tmpres_df) <- c("X", "coef", "exp.coef.", "se.coef.", "Pr...z..")
      tmpres_df$Pr...z.. <- as.numeric(tmpres_df$Pr...z..)

      # Apply p-value adjustment
      tmpres_df$Adjusted_P <- p.adjust(tmpres_df$Pr...z.., method = p_adjust_method)

      # Filter by adjusted p-value threshold
      tmpres_df <- tmpres_df[!is.na(tmpres_df$Adjusted_P) & tmpres_df$Adjusted_P < p_threshold, ]

      # If top_k is specified, select top k genes by adjusted p-value
      if (!is.null(top_k) && nrow(tmpres_df) > top_k) {
        tmpres_df <- tmpres_df[order(tmpres_df$Adjusted_P), ]
        tmpres_df <- tmpres_df[1:top_k, ]
        cat(paste("STEPWISE_LOG:Iteration", s, "- Selected top", top_k, "genes from", nrow(tmpres_df), "significant genes\n"), file = stderr())
      }

      write.csv(tmpres_df,paste0(outcandir,'/CoxPH_seed',s,'.csv'),row.names = F)
      cat(paste("STEPWISE_LOG:Iteration", s, "completed -", nrow(tmpres_df), "significant variables (adjusted p <", p_threshold, ")\n"), file = stderr())
    } else {
      cat(paste("STEPWISE_LOG:Iteration", s, "completed - No valid variables found\n"), file = stderr())
    }
  }
  cat(paste("STEPWISE_LOG:Analyzing significance across iterations...\n"), file = stderr())
  
  # Robust aggregation of significant genes across all iterations
  all_genes <- c()
  gene_lists <- list()
  valid_seeds <- c()
  
  for (s in seq(numSeed)){
    csv_file <- paste0(outcandir,'/CoxPH_seed',s,'.csv')
    if (!file.exists(csv_file)) {
      warning(paste("CSV file not found for seed", s, "- skipping"))
      next
    }
    res <- read.csv(csv_file,header = T,stringsAsFactors = F)
    if (nrow(res) == 0) {
      warning(paste("Empty CSV file for seed", s, "- skipping"))
      next
    }
    
    gene_lists[[length(gene_lists) + 1]] <- res$X
    valid_seeds <- c(valid_seeds, s)
    all_genes <- unique(c(all_genes, res$X))
  }

  if (length(all_genes) == 0) {
    stop("No valid variables found in any iteration. Please check your data.")
  }
  
  # Count frequencies
  gene_freqs <- sapply(all_genes, function(g) {
    sum(sapply(gene_lists, function(l) g %in% l))
  })
  
  SignifGene2 <- data.frame(Gene = all_genes, Freq = gene_freqs)
  write.csv(SignifGene2,paste0(outcandir,'/CoxPH_UnivariateResults.csv'),row.names = F)
  Candivar<-SignifGene2$Gene[which(SignifGene2$Freq>Freq)]
  if (length(Candivar) == 0) {
    stop("No candidate genes found after frequency filtering")
  }
  cat(paste("STEPWISE_LOG:Frequency filtering completed -", length(Candivar), "genes selected (frequency >", Freq, ")\n"), file = stderr())
  return(Candivar)
}

# Pre-screening function to quickly evaluate candidates and select top N
Survprescreen_candidates <- function(dat, candid, fixvar, prescreen_seeds, SplitProp, max_candidates, horizon){
  cat(paste("STEPWISE_LOG:Pre-screening", length(candid), "candidates with", prescreen_seeds, "seeds...\n"), file = stderr())
  prescreen_scores <- NULL
  
  for (s in seq(prescreen_seeds)){
    if (s %% 5 == 0 || s == 1) {
      cat(paste("STEPWISE_LOG:Pre-screening - Iteration", s, "of", prescreen_seeds, "\n"), file = stderr())
    }
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Event, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Event == 0)
      n_tr_1 <- sum(trdat$Event == 1)
      n_ts_0 <- sum(tsdat$Event == 0)
      n_ts_1 <- sum(tsdat$Event == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    
    for (g in setdiff(candid, fixvar)){
      tryCatch({
        f=as.formula(paste('Surv(Survtime,Event) ~ ',paste(fixvar,collapse = ' + '),' + ',g,collapse = ''))
        trdat1 <- trdat[complete.cases(trdat[,c('Survtime','Event',setdiff(c(fixvar,g),''))]),c('Survtime','Event',setdiff(c(fixvar,g),''))]
        tsdat1 <- tsdat[complete.cases(tsdat[,c('Survtime','Event',setdiff(c(fixvar,g),''))]),c('Survtime','Event',setdiff(c(fixvar,g),''))]
        
        if (nrow(trdat1) < 2 || nrow(tsdat1) < 2) {
          next
        }
        
        suppressWarnings({
          CoxPHres<-coxph(f,data = trdat1)
        })
        if (is.null(CoxPHres) || is.null(summary(CoxPHres)$coef)) {
          next
        }
        
        lptr <- predict(CoxPHres,trdat1)
        if (any(is.infinite(lptr)) || any(is.na(lptr))) {
          next
        }
        if (max(trdat1$Survtime)>=horizon){
          trauc<-cdROC(stime=trdat1$Survtime,status=trdat1$Event,marker = lptr,predict.time = horizon)$auc
        } else{
          trauc <- NA
        }
        
        lpts <- predict(CoxPHres,tsdat1)
        if (any(is.infinite(lpts)) || any(is.na(lpts))) {
          next
        }
        if (max(tsdat1$Survtime)>=horizon){
          tsauc<-cdROC(stime=tsdat1$Survtime,status=tsdat1$Event,marker = lpts,predict.time = horizon)$auc
        } else{
          tsauc <- NA
        }
        
        trauc <- ifelse(is.na(trauc), 0, as.numeric(trauc))
        tsauc <- ifelse(is.na(tsauc), 0, as.numeric(tsauc))
        
        # Use average of train and test AUC as score
        score <- (trauc + tsauc) / 2
        prescreen_scores <- rbind(prescreen_scores, c(g, score, trauc, tsauc))
      }, error = function(e) {
        # Skip this candidate if model fitting fails
      }, warning = function(w) {})
    }
  }
  
  if (is.null(prescreen_scores) || nrow(prescreen_scores) == 0) {
    cat("STEPWISE_LOG:Pre-screening failed - using all candidates\n", file = stderr())
    return(candid)
  }
  
  # Aggregate scores across seeds
  prescreen_df <- data.frame(prescreen_scores, stringsAsFactors = FALSE)
  colnames(prescreen_df) <- c("candidate", "score", "trauc", "tsauc")
  prescreen_df$score <- as.numeric(prescreen_df$score)
  prescreen_df$trauc <- as.numeric(prescreen_df$trauc)
  prescreen_df$tsauc <- as.numeric(prescreen_df$tsauc)
  
  # Calculate mean score for each candidate
  candidate_scores <- aggregate(score ~ candidate, data = prescreen_df, FUN = mean)
  candidate_scores <- candidate_scores[order(candidate_scores$score, decreasing = TRUE), ]
  
  # Select top N candidates
  n_select <- min(max_candidates, nrow(candidate_scores))
  selected_candidates <- candidate_scores$candidate[1:n_select]
  
  cat(paste("STEPWISE_LOG:Pre-screening complete - Selected top", length(selected_candidates), "candidates\n"), file = stderr())
  return(selected_candidates)
}

Survforward_step <- function(dat, candid, fixvar, horizon, numSeed, SplitProp, max_candidates_per_step = NULL, prescreen_seeds = NULL){
  # Apply pre-screening if candidates exceed threshold
  if (!is.null(max_candidates_per_step) && !is.null(prescreen_seeds) && length(candid) > max_candidates_per_step) {
    candid <- Survprescreen_candidates(dat, candid, fixvar, prescreen_seeds, SplitProp, max_candidates_per_step, horizon)
  }
  
  forward_ls <- NULL
  for (s in seq(numSeed)){
    if (s %% 20 == 0 || s == 1) {
      cat(paste("STEPWISE_LOG:Forward step - Iteration", s, "of", numSeed, "\n"), file = stderr())
    }
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Event, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Event == 0)
      n_tr_1 <- sum(trdat$Event == 1)
      n_ts_0 <- sum(tsdat$Event == 0)
      n_ts_1 <- sum(tsdat$Event == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    for (g in setdiff(candid,fixvar)){
      f=as.formula(paste('Surv(Survtime,Event) ~ ',paste(fixvar,collapse = ' + '),' + ',g,collapse = ''))
      trdat1 <- trdat[complete.cases(trdat[,c('Survtime','Event',setdiff(c(fixvar,g),''))]),c('Survtime','Event',setdiff(c(fixvar,g),''))]
      tsdat1 <- tsdat[complete.cases(tsdat[,c('Survtime','Event',setdiff(c(fixvar,g),''))]),c('Survtime','Event',setdiff(c(fixvar,g),''))]
      if (nrow(trdat1) < 2 || nrow(tsdat1) < 2) {
        next
      }
      tryCatch({
        suppressWarnings({
          CoxPHres<-coxph(f,data = trdat1)
        })
        if (is.null(CoxPHres) || is.null(summary(CoxPHres)$coef)) {
          next
        }
        lptr <- predict(CoxPHres,trdat1)
        if (any(is.infinite(lptr)) || any(is.na(lptr))) {
          next
        }
        if (max(trdat1$Survtime)>=horizon){
          trauc<-cdROC(stime=trdat1$Survtime,status=trdat1$Event,marker = lptr,predict.time = horizon)$auc
        } else{
          trauc <- NA
        }
        lpts <- predict(CoxPHres,tsdat1)
        if (any(is.infinite(lpts)) || any(is.na(lpts))) {
          next
        }
        if (max(tsdat1$Survtime)>=horizon){
          tsauc<-cdROC(stime=tsdat1$Survtime,status=tsdat1$Event,marker = lpts,predict.time = horizon)$auc
        } else{
          tsauc <- NA
        }
        trauc <- ifelse(is.na(trauc), 0, as.numeric(trauc))
        tsauc <- ifelse(is.na(tsauc), 0, as.numeric(tsauc))
        forward_ls <- rbind(forward_ls,c(s,paste(c(fixvar,g),collapse = ' + '),trauc,tsauc))
      }, error = function(e) {}, warning = function(w) {})
    }
  }
  forward_ls1 <- data.frame(forward_ls)
  forward_ls1$X3 <- as.numeric(forward_ls1$X3)
  forward_ls1$X4 <- as.numeric(forward_ls1$X4)
  AUCsumm <- NULL
  for (g in unique(forward_ls1$X2)){
    AUCsumm <- rbind(AUCsumm,c(g,colMeans(forward_ls1[which(forward_ls1$X2==g),-c(1,2)],na.rm = T)))
  }
  return(AUCsumm)
}

Survbackward_step <- function(dat, backcandid, fixvar, horizon, numSeed, SplitProp){
  backward_ls <- NULL
  for (s in seq(numSeed)){
    if (s %% 20 == 0 || s == 1) {
      cat(paste("STEPWISE_LOG:Backward step - Iteration", s, "of", numSeed, "\n"), file = stderr())
    }
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Event, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Event == 0)
      n_tr_1 <- sum(trdat$Event == 1)
      n_ts_0 <- sum(tsdat$Event == 0)
      n_ts_1 <- sum(tsdat$Event == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    for (g in backcandid){
      f=as.formula(paste('Surv(Survtime,Event) ~ ',paste(setdiff(fixvar,g),collapse = ' + '),collapse = ''))
      trdat1 <- trdat[complete.cases(trdat[,c('Survtime','Event',setdiff(fixvar,g))]),]
      tsdat1 <- tsdat[complete.cases(tsdat[,c('Survtime','Event',setdiff(fixvar,g))]),]
      if (nrow(trdat1) < 2 || nrow(tsdat1) < 2) {
        next
      }
      tryCatch({
        suppressWarnings({
          CoxPHres<-coxph(f,data = trdat1)
        })
        if (is.null(CoxPHres) || is.null(summary(CoxPHres)$coef)) {
          next
        }
        lptr <- predict(CoxPHres,trdat1)
        if (any(is.infinite(lptr)) || any(is.na(lptr))) {
          next
        }
        if (max(trdat1$Survtime)>=horizon){
          trauc<-cdROC(stime=trdat1$Survtime,status=trdat1$Event,marker = lptr,predict.time = horizon)$auc
        } else{
          trauc <- NA
        }
        lpts <- predict(CoxPHres,tsdat1)
        if (any(is.infinite(lpts)) || any(is.na(lpts))) {
          next
        }
        if (max(tsdat1$Survtime)>=horizon){
          tsauc<-cdROC(stime=tsdat1$Survtime,status=tsdat1$Event,marker = lpts,predict.time = horizon)$auc
        } else{
          tsauc <- NA
        }
        trauc <- ifelse(is.na(trauc), 0, as.numeric(trauc))
        tsauc <- ifelse(is.na(tsauc), 0, as.numeric(tsauc))
        backward_ls <- rbind(backward_ls,c(s,paste(setdiff(fixvar,g),collapse = ' + '),trauc,tsauc))
      }, error = function(e) {}, warning = function(w) {})
    }
  }
  backward_ls1 <- data.frame(backward_ls)
  backward_ls1$X3 <- as.numeric(backward_ls1$X3)
  backward_ls1$X4 <- as.numeric(backward_ls1$X4)
  AUCsumm <- NULL
  for (g in unique(backward_ls1$X2)){
    AUCsumm <- rbind(AUCsumm,c(g,colMeans(backward_ls1[which(backward_ls1$X2==g),-c(1,2)],na.rm = T)))
  }
  return(AUCsumm)
}

SurvTrainAUCStepwise <- function(totvar,dat,fixvar,excvar,horizon,numSeed,SplitProp,outdir,max_candidates_per_step = NULL,prescreen_seeds = NULL){
  if (is.null(totvar) || length(totvar) == 0) {
    cat("STEPWISE_LOG:No candidate variables provided for stepwise selection.\n", file = stderr())
    return(NULL)
  }
  imtres <- NULL
  step_count <- 0
  while (length(setdiff(fixvar,excvar))<length(totvar)){
    step_count <- step_count + 1
    candid <- setdiff(totvar,c(fixvar,excvar))
    
    ##### Forward step
    cat(paste("STEPWISE_LOG:Step", step_count, "- Forward selection with", length(candid), "candidates,", length(setdiff(fixvar,"")), "currently selected\n"), file = stderr())
    forward_ls <- Survforward_step(dat, candid, fixvar, horizon, numSeed, SplitProp, max_candidates_per_step, prescreen_seeds)
    forward.trauc1<-max(as.numeric(forward_ls[,2]), na.rm = TRUE)
    forward.var1 <- forward_ls[which.max(as.numeric(forward_ls[,2])),1]
    forward.tsauc1 <- forward_ls[which.max(as.numeric(forward_ls[,2])),3]
    forward.tsauc1 <- ifelse(is.na(forward.tsauc1), 0, as.numeric(forward.tsauc1))
    forward.newstep <-matrix(c(forward.var1,forward.trauc1,forward.tsauc1),nrow=1)
    if (length(setdiff(gsub(" ","",strsplit(forward.var1,"\\+")[[1]]),""))==1){
      dir.create(outdir)
      imtres <- rbind(imtres, forward.newstep)
      colnames(forward.newstep)<-c('Variable','trainAUC','testAUC')
      write.csv(forward.newstep, file.path(outdir, paste0("Intermediate_Forward", nrow(imtres), ".csv")), row.names = FALSE)
      fixvar <- gsub(" ","",strsplit(forward.var1,'\\+')[[1]][2])
      forward.old <- forward.newstep
      cat(paste("STEPWISE_LOG:Added variable:", fixvar, "- TrainAUC:", round(as.numeric(forward.trauc1), 4), ", TestAUC:", round(forward.tsauc1, 4), "\n"), file = stderr())
    } else{
      forward.old <- imtres[nrow(imtres),]
      if (as.numeric(forward.newstep[2]) > (as.numeric(forward.old[2]) + 0.005)){
        colnames(forward.newstep) <- colnames(imtres)
        imtres <- rbind(imtres, forward.newstep)
        colnames(forward.newstep)<-c('Variable','trainAUC','testAUC')
        write.csv(forward.newstep, file.path(outdir, paste0("Intermediate_Forward", nrow(imtres), ".csv")), row.names = FALSE)
        new_var <- gsub(' ','',strsplit(forward.var1,'\\+')[[1]])[length(gsub(' ','',strsplit(forward.var1,'\\+')[[1]]))]
        fixvar <- append(fixvar,new_var)
        forward.old <- forward.newstep
        cat(paste("STEPWISE_LOG:Added variable:", new_var, "- TrainAUC:", round(as.numeric(forward.trauc1), 4), ", TestAUC:", round(forward.tsauc1, 4), "\n"), file = stderr())
        
        if (nrow(imtres)>2){
          
          ##### Backward step
          cat(paste("STEPWISE_LOG:Step", step_count, "- Backward selection\n"), file = stderr())
          backcandid<-fixvar[c(1:(length(fixvar)-2))]
          backward_ls<-Survbackward_step(dat, backcandid, fixvar, horizon, numSeed, SplitProp)
          backward.trauc1<-max(as.numeric(backward_ls[,2]), na.rm = TRUE)
          backward.var1 <- backward_ls[which.max(as.numeric(backward_ls[,2])),1]
          backward.tsauc1 <- backward_ls[which.max(as.numeric(backward_ls[,2])),3]
          backward.tsauc1 <- ifelse(is.na(backward.tsauc1), 0, as.numeric(backward.tsauc1))
          backward.newstep <-matrix(c(backward.var1,backward.trauc1,backward.tsauc1),nrow=1)
          if (backward.trauc1 > (as.numeric(forward.old[2]) + 0.005)){
            imtres <- rbind(imtres, backward.newstep)
            colnames(backward.newstep)<-c('Variable','trainAUC','testAUC')
            write.csv(backward.newstep, file.path(outdir, paste0("Intermediate_Backward", nrow(imtres), ".csv")), row.names = FALSE)
            fixvar <- gsub(' ','',strsplit(backward_ls[which.max(as.numeric(backward_ls[,2])),1],'\\+')[[1]])
            forward.old <- backward.trauc1
            cat(paste("STEPWISE_LOG:Removed variable(s) - TrainAUC:", round(backward.trauc1, 4), ", TestAUC:", round(backward.tsauc1, 4), "\n"), file = stderr())
          }
        }
      } else{
        cat(paste("STEPWISE_LOG:No improvement - stopping stepwise selection\n"), file = stderr())
        mat<-matrix(imtres[nrow(imtres),],nrow=1)
        colnames(mat)<-c('Variable','trainAUC','testAUC')
        colnames(imtres)<-c('Variable','trainAUC','testAUC')
        write.csv(imtres, file.path(outdir, "Intermediate_Stepwise_Total.csv"), row.names = FALSE)
        write.csv(mat, file.path(outdir, "Final_Stepwise_Total.csv"), row.names = FALSE)
        final_vars <- gsub(" ","",strsplit(mat[1,1],"\\+")[[1]])
        final_vars <- final_vars[final_vars != ""]
        final_train_auc <- as.numeric(mat[1,2])
        final_test_auc <- as.numeric(mat[1,3])
        cat(paste("STEPWISE_LOG:Stepwise selection complete - Final model has", length(final_vars), "variables\n"), file = stderr())
        cat(paste("STEPWISE_LOG:Final TrainAUC:", round(final_train_auc, 4), ", TestAUC:", round(final_test_auc, 4), "\n"), file = stderr())
        break
      }
    }
  }
  mat<-matrix(imtres[nrow(imtres),],nrow=1)
  colnames(mat)<-c('Variable','trainAUC','testAUC')
  colnames(imtres)<-c('Variable','trainAUC','testAUC')
  write.csv(imtres, file.path(outdir, "Intermediate_Stepwise_Total.csv"), row.names = FALSE)
  write.csv(mat, file.path(outdir, "Final_Stepwise_Total.csv"), row.names = FALSE)
  final_vars <- gsub(" ","",strsplit(mat[1,1],"\\+")[[1]])
  final_vars <- final_vars[final_vars != ""]
  final_train_auc <- as.numeric(mat[1,2])
  final_test_auc <- as.numeric(mat[1,3])
  cat(paste("STEPWISE_LOG:Stepwise selection complete - Final model has", length(final_vars), "variables\n"), file = stderr())
  cat(paste("STEPWISE_LOG:Final TrainAUC:", round(final_train_auc, 4), ", TestAUC:", round(final_test_auc, 4), "\n"), file = stderr())
  return (mat)
}

PlotSurvROC <- function(dat,numSeed,SplitProp,Result,horizon){
  FinalRes <- NULL
  trROCobjList <- tsROCobjList <- NULL
  valid_iterations <- 0
  
  for (s in seq(numSeed)){
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Event, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Event == 0)
      n_tr_1 <- sum(trdat$Event == 1)
      n_ts_0 <- sum(tsdat$Event == 0)
      n_ts_1 <- sum(tsdat$Event == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    
    f=as.formula(paste0('Surv(Survtime,Event) ~ ',as.character(Result[1,1])))
    trdat1 <- trdat[complete.cases(trdat[,c('Survtime','Event',strsplit(Result[1,1],' \\+ ')[[1]])]),c('Survtime','Event',strsplit(Result[1,1],' \\+ ')[[1]])]
    tsdat1 <- tsdat[complete.cases(tsdat[,c('Survtime','Event',strsplit(Result[1,1],' \\+ ')[[1]])]),c('Survtime','Event',strsplit(Result[1,1],' \\+ ')[[1]])]
    
    if (nrow(trdat1) < 2 || nrow(tsdat1) < 2) {
      next
    }
    
    tryCatch({
      suppressWarnings({
        CoxPHres<-coxph(f,data = trdat1)
      })
      
      if (is.null(CoxPHres) || is.null(summary(CoxPHres)$coef)) {
        next
      }
      
      lptr <- predict(CoxPHres,trdat1)
      if (any(is.infinite(lptr)) || any(is.na(lptr))) {
        next
      }
      
      if (max(trdat1$Survtime) >= horizon){
        trROCobj <- cdROC(stime=trdat1$Survtime,status=trdat1$Event,marker = lptr,predict.time = horizon)
        trauc <- trROCobj$auc
      } else {
        next
      }
      
      lpts <- predict(CoxPHres,tsdat1)
      if (any(is.infinite(lpts)) || any(is.na(lpts))) {
        next
      }
      
      if (max(tsdat1$Survtime) >= horizon){
        tsROCobj <- cdROC(stime=tsdat1$Survtime,status=tsdat1$Event,marker = lpts,predict.time = horizon)
        tsauc <- tsROCobj$auc
      } else {
        next
      }
      
      trauc <- ifelse(is.na(trauc), 0, as.numeric(trauc))
      tsauc <- ifelse(is.na(tsauc), 0, as.numeric(tsauc))
      
      valid_iterations <- valid_iterations + 1
      trROCobjList[[valid_iterations]] <- trROCobj
      tsROCobjList[[valid_iterations]] <- tsROCobj
      FinalRes <- rbind(FinalRes,c(s,trauc,tsauc))
    }, error = function(e) {}, warning = function(w) {})
  }
  
  if (valid_iterations == 0) {
    stop("No valid iterations for ROC plotting")
  }
  
  tsTPR_list <- lapply(seq(valid_iterations), function(v) { if (is.null(tsROCobjList[[v]])) return(NULL); as.numeric(tsROCobjList[[v]]$TPR) })
  tsTNR_list <- lapply(seq(valid_iterations), function(v) { if (is.null(tsROCobjList[[v]])) return(NULL); as.numeric(tsROCobjList[[v]]$TNR) })
  trTPR_list <- lapply(seq(valid_iterations), function(v) { if (is.null(trROCobjList[[v]])) return(NULL); as.numeric(trROCobjList[[v]]$TPR) })
  trTNR_list <- lapply(seq(valid_iterations), function(v) { if (is.null(trROCobjList[[v]])) return(NULL); as.numeric(trROCobjList[[v]]$TNR) })
  
  all_lengths <- c(sapply(tsTPR_list, length), sapply(tsTNR_list, length), sapply(trTPR_list, length), sapply(trTNR_list, length))
  max_len <- max(all_lengths[all_lengths > 0], 100, na.rm = TRUE)
  
  tsTPR_mat <- do.call(cbind, lapply(tsTPR_list, function(x) { if (is.null(x)) return(rep(NA, max_len)); c(x, rep(NA, max_len - length(x))) }))
  tsTNR_mat <- do.call(cbind, lapply(tsTNR_list, function(x) { if (is.null(x)) return(rep(NA, max_len)); c(x, rep(NA, max_len - length(x))) }))
  trTPR_mat <- do.call(cbind, lapply(trTPR_list, function(x) { if (is.null(x)) return(rep(NA, max_len)); c(x, rep(NA, max_len - length(x))) }))
  trTNR_mat <- do.call(cbind, lapply(trTNR_list, function(x) { if (is.null(x)) return(rep(NA, max_len)); c(x, rep(NA, max_len - length(x))) }))
  
  MeantsTPR <- rowMeans(tsTPR_mat, na.rm = TRUE)
  MeantsTNR <- rowMeans(tsTNR_mat, na.rm = TRUE)
  MeantrTPR <- rowMeans(trTPR_mat, na.rm = TRUE)
  MeantrTNR <- rowMeans(trTNR_mat, na.rm = TRUE)
  
  MeantsTPR <- MeantsTPR[!is.na(MeantsTPR)]
  MeantsTNR <- MeantsTNR[!is.na(MeantsTNR)]
  MeantrTPR <- MeantrTPR[!is.na(MeantrTPR)]
  MeantrTNR <- MeantrTNR[!is.na(MeantrTNR)]
  
  plot_roc_func <- function() {
    par(mfrow=c(1,2), family = PLOT_FONT, bg = "white")
    par(mar = c(4.5, 4.5, 3, 1))
    
    if (valid_iterations > 0 && !is.null(trROCobjList[[1]])) {
      plot(1-trROCobjList[[1]]$TNR,trROCobjList[[1]]$TPR,col="gray70",type='l',lwd=0.8,lty=2,cex.axis=1,cex.lab=1.1,font.lab=2,xlab='1-Specificity',ylab='Sensitivity',main='[ROC curve] Training set',cex.main=1.2,font.main=2)
      if (valid_iterations > 1) { sapply(seq(2,valid_iterations),function(v) { if (!is.null(trROCobjList[[v]])) { lines(1-trROCobjList[[v]]$TNR,trROCobjList[[v]]$TPR,col="gray70",type='l',lwd=0.8,lty=2) } }) }
      if (length(MeantrTNR) > 0 && length(MeantrTPR) > 0) { lines(1-MeantrTNR,MeantrTPR,col=nature_colors$blue,type='l',lwd=1) }
      FinalRes_df <- data.frame(FinalRes); FinalRes_df[,2] <- as.numeric(FinalRes_df[,2]); FinalRes_df[,3] <- as.numeric(FinalRes_df[,3])
      legend('bottomright',legend = paste0('Mean AUC:\n',round(mean(FinalRes_df[,2],na.rm = T),3),' ± ',round(sd(FinalRes_df[,2],na.rm = T),3)),lwd=1,cex=1,col = nature_colors$blue, box.lwd=0.8)
    }
    
    if (valid_iterations > 0 && !is.null(tsROCobjList[[1]])) {
      plot(1-tsROCobjList[[1]]$TNR,tsROCobjList[[1]]$TPR,col="gray70",type='l',lwd=0.8,lty=2,cex.axis=1,cex.lab=1.1,font.lab=2,xlab='1-Specificity',ylab='Sensitivity',main='[ROC curve] Test set',cex.main=1.2,font.main=2)
      if (valid_iterations > 1) { sapply(seq(2,valid_iterations),function(v) { if (!is.null(tsROCobjList[[v]])) { lines(1-tsROCobjList[[v]]$TNR,tsROCobjList[[v]]$TPR,col="gray70",type='l',lwd=0.8,lty=2) } }) }
      if (length(MeantsTNR) > 0 && length(MeantsTPR) > 0) { lines(1-MeantsTNR,MeantsTPR,col=nature_colors$red,type='l',lwd=1) }
      FinalRes_df <- data.frame(FinalRes); FinalRes_df[,2] <- as.numeric(FinalRes_df[,2]); FinalRes_df[,3] <- as.numeric(FinalRes_df[,3])
      legend('bottomright',legend = paste0('Mean AUC:\n',round(mean(FinalRes_df[,3],na.rm = T),3),' ± ',round(sd(FinalRes_df[,3],na.rm = T),3)),lwd=1,cex=1,col = nature_colors$red, box.lwd=0.8)
    }
  }
  
  if (!dir.exists("figures")) dir.create("figures", recursive = TRUE)
  tryCatch({
    tiff(filename = 'figures/Surv_ROCcurve.tiff', width = 7*300, height = 3.5*300, units = "px", res = 300, compression = "lzw")
    plot_roc_func()
    dev.off()
  }, error = function(e) {
    try(dev.off(), silent = TRUE)
    cat(paste("STEPWISE_LOG:Warning - Failed to save ROC TIFF:", e$message, "\n"), file = stderr())
  })

  tryCatch({
    if (requireNamespace("svglite", quietly = TRUE)) {
      svglite::svglite(file = 'figures/Surv_ROCcurve.svg', width = 7, height = 3.5)
    } else {
      svg(filename = 'figures/Surv_ROCcurve.svg', width = 7, height = 3.5)
    }
    plot_roc_func()
    dev.off()
  }, error = function(e) {
    try(dev.off(), silent = TRUE)
    cat(paste("STEPWISE_LOG:Warning - Failed to save ROC SVG:", e$message, "\n"), file = stderr())
  })
}

PlotSurVarImp <- function(dat,Result){
  Scaledat <- cbind(dat[,c('Survtime','Event')],apply(dat[,match(gsub(" ","",strsplit(Result[1,1],"\\+")[[1]]),colnames(dat))],2,function(v) scale(v)))
  
  mod<-coxph(as.formula(paste0('Surv(Survtime,Event)  ~ ',as.character(Result[1,1]))),data = Scaledat)
  ce=function(model.obj){
    extract=summary(get(model.obj))$coefficients[,c(1,3)]
    return(data.frame(extract,vars=row.names(extract),model=model.obj))
  }
  coefs = ce('mod')
  names(coefs)[2]='se'
  
  p <- ggplot(coefs, aes(x = vars, y = coef, color = vars)) +
    geom_hline(yintercept = 0, linetype = "dashed", color = "gray50", linewidth = 0.5) +
    geom_errorbar(aes(ymin = coef - se, ymax = coef + se), linewidth = 0.5, width = 0, color = "black") +
    geom_point(size = 3, color = nature_colors$blue) +
    geom_text(aes(label = sprintf("%.2f", coef)), hjust = 0.4, vjust = -1, size = 3, fontface = "bold", color = "black") +
    coord_flip() +
    guides(color = "none") +
    labs(x = "Predictors", y = "Standardized Coefficient", title = "Variable Importance") +
    nature_theme(base_size = 10)
  
  save_plot(p, 'Surv_Variable_Importance', width_inch = 7, height_inch = 5)
}

# Kaplan-Meier Survival Curves by Risk Groups
#
# ==============================================================================
#  [v3 FIX] PlotSurvKM
#  - survfit (모든 그룹)과 summary(survfit) (이벤트 발생 그룹)을
#    명확히 구분하여 이벤트가 0건인 그룹을 정확히 식별합니다.
#  - 0건 이벤트 그룹(Low, Medium)에 대해 (0, 1.0) 및 (max_time, 1.0)
#    포인트를 확실하게 추가하여 수평선을 생성합니다.
# ==============================================================================
PlotSurvKM <- function(dat, numSeed, SplitProp, Result, horizon) {
  # Create debug log file
  log_file <- "figures/Surv_KM_Debug.log"
  if (!dir.exists("figures")) dir.create("figures", recursive = TRUE)

  # Initialize log file
  write(paste("=== Kaplan-Meier Plot Debug Log (v3) ==="), file = log_file, append = FALSE)
  write(paste("Timestamp:", Sys.time()), file = log_file, append = TRUE)
  write(paste("Total samples in dataset:", nrow(dat)), file = log_file, append = TRUE)
  write(paste("Variables in model:", Result[1,1]), file = log_file, append = TRUE)

  # Get risk scores for all data
  f <- as.formula(paste0('Surv(Survtime,Event) ~ ', as.character(Result[1,1])))
  Scaledat <- cbind(dat[,c('Survtime','Event')],apply(dat[,match(gsub(" ","",strsplit(Result[1,1],"\\+")[[1]]),colnames(dat))],2,function(v) scale(v)))

  suppressWarnings({
    mod <- coxph(f, data = Scaledat)
  })

  if (is.null(mod)) {
    write("ERROR: Cox model is NULL", file = log_file, append = TRUE)
    cat("STEPWISE_LOG:Kaplan-Meier plot skipped - Cox model failed\n", file = stderr())
    return(NULL)
  }

  write(paste("Cox model fitted successfully"), file = log_file, append = TRUE)
  risk_scores <- predict(mod, newdata = Scaledat)
  valid_idx <- which(!is.na(risk_scores) & !is.na(dat$Survtime) & !is.na(dat$Event))
  
  if (length(valid_idx) < 2) {
    write("ERROR: Insufficient valid samples", file = log_file, append = TRUE)
    cat("STEPWISE_LOG:Kaplan-Meier plot skipped - insufficient valid samples\n", file = stderr())
    return(NULL)
  }

  risk_scores_valid <- risk_scores[valid_idx]
  base_groups <- assign_risk_groups(risk_scores_valid, log_file = log_file)
  
  cat(paste("STEPWISE_LOG:Base groups distribution:\n"), file = stderr())
  print(table(base_groups, useNA = "always"), file = stderr())

  risk_groups <- factor(paste(base_groups, "Risk"),
                        levels = paste(c("Low", "Medium", "High"), "Risk"))
  
  cat(paste("STEPWISE_LOG:Risk groups after factor creation:\n"), file = stderr())
  print(table(risk_groups, useNA = "always"), file = stderr())

  valid_group_idx <- which(!is.na(risk_groups))
  
  if (length(valid_group_idx) < 2) {
    write("ERROR: Insufficient risk group assignments", file = log_file, append = TRUE)
    cat("STEPWISE_LOG:Kaplan-Meier plot skipped - insufficient risk group assignments\n", file = stderr())
    return(NULL)
  }
  
  # Filter data to valid groups only
  risk_groups_filtered <- risk_groups[valid_group_idx]
  surv_time <- dat$Survtime[valid_idx][valid_group_idx]
  surv_event <- dat$Event[valid_idx][valid_group_idx]
  
  group_counts <- table(risk_groups_filtered)
  cat(paste("STEPWISE_LOG:Kaplan-Meier groups:", paste(names(group_counts), "=", group_counts, collapse=", "), "\n"), file = stderr())

  if (sum(group_counts) < 2) {
    write(paste("ERROR: Only", sum(group_counts), "sample(s) found, need at least 2"), file = log_file, append = TRUE)
    cat(paste("STEPWISE_LOG:Kaplan-Meier plot skipped - insufficient samples\n"), file = stderr())
    return(NULL)
  }

  surv_data <- data.frame(
    time = surv_time,
    event = surv_event,
    risk_group = risk_groups_filtered
  )
  
  all_group_levels <- c("Low Risk", "Medium Risk", "High Risk")
  surv_data$risk_group <- factor(surv_data$risk_group, levels = all_group_levels)

  write(paste("\n=== Survival Data ==="), file = log_file, append = TRUE)
  write(paste("Survival data rows:", nrow(surv_data)), file = log_file, append = TRUE)
  write(paste("Time range:", min(surv_data$time), "to", max(surv_data$time)), file = log_file, append = TRUE)
  write(paste("Events:", sum(surv_data$event), "out of", nrow(surv_data),
              paste0("(", round(100*sum(surv_data$event)/nrow(surv_data), 1), "%)")), file = log_file, append = TRUE)

  # Fit survival curves
  tryCatch({
    surv_fit <- survfit(Surv(time, event) ~ risk_group, data = surv_data)
    surv_summary <- summary(surv_fit) # Get summary *once*
    write(paste("\n=== Survival Fit ==="), file = log_file, append = TRUE)
    write(paste("Strata in surv_fit:", paste(names(surv_fit$strata), collapse=", ")), file = log_file, append = TRUE)
    write(paste("Strata in surv_summary:", paste(unique(surv_summary$strata), collapse=", ")), file = log_file, append = TRUE)
  }, error = function(e) {
    write(paste("ERROR in survfit:", e$message), file = log_file, append = TRUE)
    cat(paste("STEPWISE_LOG:Error in survival fit:", e$message, "\n"), file = stderr())
    return(NULL)
  })

  cat(paste("STEPWISE_LOG:Survival fit strata:", paste(names(surv_fit$strata), collapse=", "), "\n"), file = stderr())

  # ====================================================================
  # [v3 FIX] Manually build plot_data to include all groups
  # ====================================================================

  # 1. Get ALL groups present in the fit
  if (!is.null(surv_fit$strata) && length(surv_fit$strata) > 0) {
    groups_in_fit <- gsub("risk_group=", "", names(surv_fit$strata))
  } else {
    groups_in_fit <- as.character(unique(surv_data$risk_group))
  }
  
  # 2. Get groups that have event/censoring data in the SUMMARY
  if (!is.null(surv_summary$strata) && length(surv_summary$time) > 0) {
    groups_in_summary <- unique(gsub("risk_group=", "", as.character(surv_summary$strata)))
  } else {
    groups_in_summary <- c() 
  }
  
  # 3. Find 0-event groups by finding the difference
  groups_without_events <- setdiff(groups_in_fit, groups_in_summary)

  write(paste("\n=== Plot Data Generation (v3 Fix) ==="), file = log_file, append = TRUE)
  write(paste("All groups in fit:", paste(groups_in_fit, collapse=", ")), file = log_file, append = TRUE)
  write(paste("Groups in summary (events):", paste(groups_in_summary, collapse=", ")), file = log_file, append = TRUE)
  write(paste("Groups WITHOUT events:", paste(groups_without_events, collapse=", ")), file = log_file, append = TRUE)

  # Initialize plot_data
  plot_data <- data.frame(
    time = numeric(),
    surv = numeric(),
    strata = factor(character(), levels = all_group_levels)
  )

  # 4. Process groups WITH events (from summary)
  if (length(groups_in_summary) > 0) {
    for (grp in groups_in_summary) {
      # Add (0, 1.0) start point
      plot_data <- rbind(plot_data, data.frame(
        time = 0,
        surv = 1.0,
        strata = factor(grp, levels = all_group_levels)
      ))
      
      # Add event data from summary
      grp_idx <- which(gsub("risk_group=", "", as.character(surv_summary$strata)) == grp)
      if (length(grp_idx) > 0) {
        grp_data <- data.frame(
          time = surv_summary$time[grp_idx],
          surv = surv_summary$surv[grp_idx],
          strata = factor(grp, levels = all_group_levels)
        )
        plot_data <- rbind(plot_data, grp_data)
      }
    }
  }
  
  # 5. Process groups WITHOUT events (create 100% survival line)
  if (length(groups_without_events) > 0) {
    max_time <- max(surv_data$time, na.rm = TRUE)
    
    for (grp in groups_without_events) {
      # Add (0, 1.0) start point
      plot_data <- rbind(plot_data, data.frame(
        time = 0,
        surv = 1.0,
        strata = factor(grp, levels = all_group_levels)
      ))
      
      # Add (max_time, 1.0) end point
      plot_data <- rbind(plot_data, data.frame(
        time = max_time,
        surv = 1.0,
        strata = factor(grp, levels = all_group_levels)
      ))
      
      log_message <- paste("Creating 100% survival line (0 events) for:", grp)
      write(log_message, file = log_file, append = TRUE)
      cat(paste("STEPWISE_LOG:", log_message, "\n"), file = stderr())
    }
  }

  # Sort by strata and time for proper plotting
  plot_data <- plot_data[order(plot_data$strata, plot_data$time), ]
  
  # ====================================================================
  # [FIX END]
  # ====================================================================

  write(paste("\n=== Final Plot Data ==="), file = log_file, append = TRUE)
  write(paste("Plot data rows:", nrow(plot_data)), file = log_file, append = TRUE)
  write(paste("Unique strata in plot:", paste(unique(plot_data$strata), collapse=", ")), file = log_file, append = TRUE)

  # 정적 컬러맵 정의
  color_map <- c(
    "Low Risk" = nature_colors$green,
    "Medium Risk" = nature_colors$orange,
    "High Risk" = nature_colors$red
  )

  write(paste("\n=== Creating Plot ==="), file = log_file, append = TRUE)

  # Create plot with proper grouping
  p <- ggplot(plot_data, aes(x = time, y = surv, color = strata, group = strata)) +
    geom_step(linewidth = 0.5) + # geom_step()이 KM커브에 적합
    labs(x = "Time (years)", y = "Survival Probability",
         title = "Kaplan-Meier Survival Curves by Risk Groups", color = "Risk Group") +
    ylim(0, 1) +
    scale_color_manual(
      values = color_map, 
      limits = names(color_map), # 범례 순서 및 전체 레벨 고정
      drop = FALSE               # 데이터에 없는 레벨도 범례에 표시
    ) +
    nature_theme(base_size = 10)

  write(paste("Plot created successfully"), file = log_file, append = TRUE)
  write(paste("\n=== Saving Plot ==="), file = log_file, append = TRUE)

  save_plot(p, 'Surv_Kaplan_Meier', width_inch = 7, height_inch = 5)

  write(paste("Plot saved successfully"), file = log_file, append = TRUE)
  write(paste("\n=== Analysis Complete ==="), file = log_file, append = TRUE)
  write(paste("Debug log saved to:", normalizePath(log_file, mustWork = FALSE)), file = log_file, append = TRUE)

  cat(paste("STEPWISE_LOG:Kaplan-Meier debug log saved to:", normalizePath(log_file, mustWork = FALSE), "\n"), file = stderr())
}

# Time-dependent AUC
PlotSurvTimeAUC <- function(dat, numSeed, SplitProp, Result) {
  time_points <- seq(1, max(dat$Survtime, na.rm = TRUE), by = 1)
  auc_over_time <- data.frame(time = numeric(), auc = numeric(), dataset = character())
  
  for (s in seq(numSeed)) {
    set.seed(s)
    repeat {
      trIdx <- createDataPartition(dat$Event, p = SplitProp, list = FALSE, times = 1)
      trdat <- dat[trIdx, ]
      tsdat <- dat[-trIdx, ]
      
      n_tr_0 <- sum(trdat$Event == 0)
      n_tr_1 <- sum(trdat$Event == 1)
      n_ts_0 <- sum(tsdat$Event == 0)
      n_ts_1 <- sum(tsdat$Event == 1)
      
      if (min(n_tr_0, n_tr_1, n_ts_0, n_ts_1) >= 2) break
    }
    
    tryCatch({
      f <- as.formula(paste0('Surv(Survtime,Event) ~ ', as.character(Result[1,1])))
      trdat1 <- trdat[complete.cases(trdat[,c('Survtime','Event',strsplit(Result[1,1],' \\+ ')[[1]])]),c('Survtime','Event',strsplit(Result[1,1],' \\+ ')[[1]])]
      tsdat1 <- tsdat[complete.cases(tsdat[,c('Survtime','Event',strsplit(Result[1,1],' \\+ ')[[1]])]),c('Survtime','Event',strsplit(Result[1,1],' \\+ ')[[1]])]
      
      if (nrow(trdat1) < 2 || nrow(tsdat1) < 2) next
      
      suppressWarnings({
        CoxPHres <- coxph(f, data = trdat1)
      })
      
      if (is.null(CoxPHres) || is.null(summary(CoxPHres)$coef)) next
      
      lptr <- predict(CoxPHres, trdat1)
      lpts <- predict(CoxPHres, tsdat1)
      
      if (any(is.infinite(lptr)) || any(is.na(lptr))) next
      if (any(is.infinite(lpts)) || any(is.na(lpts))) next
      
      for (t in time_points) {
        if (max(trdat1$Survtime) >= t) {
          trauc <- tryCatch({ cdROC(stime=trdat1$Survtime,status=trdat1$Event,marker = lptr,predict.time = t)$auc }, error = function(e) NA)
          if (!is.na(trauc)) { auc_over_time <- rbind(auc_over_time, data.frame(time = t, auc = trauc, dataset = "Training")) }
        }
        
        if (max(tsdat1$Survtime) >= t) {
          tsauc <- tryCatch({ cdROC(stime=tsdat1$Survtime,status=tsdat1$Event,marker = lpts,predict.time = t)$auc }, error = function(e) NA)
          if (!is.na(tsauc)) { auc_over_time <- rbind(auc_over_time, data.frame(time = t, auc = tsauc, dataset = "Test")) }
        }
      }
    }, error = function(e) {})
  }
  
  if (nrow(auc_over_time) == 0) return(NULL)
  
  auc_summary <- aggregate(auc ~ time + dataset, data = auc_over_time, FUN = mean, na.rm = TRUE)
  
  p <- ggplot(auc_summary, aes(x = time, y = auc, color = dataset)) +
    geom_line(linewidth = 0.5) +
    geom_point(size = 2, alpha = 0.8) +
    labs(x = "Time (years)", y = "AUC", title = "Time-dependent AUC", color = "Dataset") +
    ylim(0, 1) +
    scale_color_manual(values = c("Training" = nature_colors$blue, "Test" = nature_colors$red)) +
    nature_theme(base_size = 10)
  
  save_plot(p, 'Surv_Time_AUC', width_inch = 7, height_inch = 5)
}

# Risk Score Distribution
PlotSurvRiskDist <- function(dat, Result) {
  f <- as.formula(paste0('Surv(Survtime,Event) ~ ', as.character(Result[1,1])))
  Scaledat <- cbind(dat[,c('Survtime','Event')],apply(dat[,match(gsub(" ","",strsplit(Result[1,1],"\\+")[[1]]),colnames(dat))],2,function(v) scale(v)))

  suppressWarnings({
    mod <- coxph(f, data = Scaledat)
  })

  if (is.null(mod)) return(NULL)

  risk_scores <- predict(mod, newdata = Scaledat)
  valid_idx <- which(!is.na(risk_scores))
  if (length(valid_idx) == 0) {
    cat("STEPWISE_LOG:Risk distribution plots skipped - no valid risk scores\n", file = stderr())
    return(NULL)
  }

  risk_scores_valid <- risk_scores[valid_idx]

  risk_data <- data.frame(
    risk_score = risk_scores_valid,
    event = factor(dat$Event[valid_idx], levels = c(0, 1), labels = c("Censored", "Event"))
  )

  log_file <- "figures/Surv_Risk_Debug.log"
  risk_data$risk_group <- assign_risk_groups(risk_scores_valid, log_file = log_file)
  
  n_total <- length(risk_data$risk_score)
  range_risk <- diff(range(risk_data$risk_score))
  bin_width <- range_risk / 30
  
  p1 <- ggplot(risk_data, aes(x = risk_score, fill = event)) +
    geom_histogram(alpha = 0.7, bins = 30, position = "identity", linewidth = 0.3) +
    geom_density(alpha = 0.4, aes(y = after_stat(density) * n_total * bin_width),
                linewidth = 0.5, inherit.aes = TRUE) +
    labs(x = "Risk Score", y = "Frequency", 
         title = "Distribution of Risk Scores", fill = "Event Status") +
    scale_fill_manual(values = c("Censored" = nature_colors$blue, "Event" = nature_colors$red)) +
    nature_theme(base_size = 10)
  
  p2 <- ggplot(risk_data, aes(x = risk_group, y = risk_score, fill = risk_group)) +
    geom_boxplot(alpha = 0.7, outlier.size = 1.5, linewidth = 0.5) +
    geom_jitter(width = 0.2, alpha = 0.3, size = 1) +
    labs(x = "Risk Group", y = "Risk Score", title = "Risk Score by Group") +
    scale_fill_manual(values = c("Low" = nature_colors$green, 
                                   "Medium" = nature_colors$orange,
                                   "High" = nature_colors$red)) +
    nature_theme(base_size = 10) +
    theme(legend.position = "none")
  
  save_plot(p1, 'Surv_Risk_Distribution', width_inch = 7, height_inch = 5)
  save_plot(p2, 'Surv_Risk_Group_Boxplot', width_inch = 5, height_inch = 5)
}

# Calibration Plot for Survival
PlotSurvCalibration <- function(dat, numSeed, SplitProp, Result, horizon) {
  cat("STEPWISE_LOG:Survival calibration plot generation skipped\n", file = stderr())
  invisible(NULL)
}

# Stepwise Selection Process Visualization
PlotSurvStepwiseProcess <- function(outdir) {
  stepwise_file <- paste0(outdir, '/Intermediate_Stepwise_Total.csv')
  if (!file.exists(stepwise_file)) return(NULL)
  
  stepwise_data <- read.csv(stepwise_file, stringsAsFactors = FALSE)
  
  stepwise_data$step <- seq_len(nrow(stepwise_data))
  stepwise_data$n_vars <- sapply(strsplit(stepwise_data$Variable, " \\+ "), length)
  stepwise_data$trainAUC <- as.numeric(stepwise_data$trainAUC)
  stepwise_data$testAUC <- as.numeric(stepwise_data$testAUC)
  
  auc_long <- reshape2::melt(stepwise_data[, c("step", "trainAUC", "testAUC")], 
                              id.vars = "step", variable.name = "type", value.name = "AUC")
  
  p <- ggplot(auc_long, aes(x = step, y = AUC, color = type, group = type)) +
    geom_line(linewidth = 0.5) +
    geom_point(size = 2.5, alpha = 0.8) +
    geom_text(aes(label = sprintf("%.3f", AUC)), vjust = -0.5, size = 2.8, fontface = "bold") +
    labs(x = "Step", y = "AUC", title = "Stepwise Selection Process", color = "Dataset") +
    scale_color_manual(values = c("trainAUC" = nature_colors$blue, "testAUC" = nature_colors$red),
                       labels = c("Training", "Test")) +
    nature_theme(base_size = 10)
  
  save_plot(p, 'Surv_Stepwise_Process', width_inch = 7, height_inch = 5)
}