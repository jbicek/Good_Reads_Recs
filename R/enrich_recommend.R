#!/usr/bin/env Rscript

# ==============================================================================
# Tableau Goodreads Dashboard - Phase 2: Data Enrichment & User Taste Profiling
# Script: R/enrich_recommend.R
#
# Description:
#   Enriches cleaned Goodreads reading data and profiles user reading taste
#   using precision decimal ratings, creating rich feature sets ready for
#   relational database modeling and downstream Machine Learning recommendations.
#
# Key Capabilities:
#   1. Metadata Enrichment & Standardized Taxonomy:
#      - Queries Open Library Search & Book APIs using `httr2` and `jsonlite`
#        with smart on-disk caching in `data/cache/open_library_cache.rds`.
#      - Maps raw tags, API subjects, author catalogs, and titles into clean,
#        standardized primary genres (Mystery, Thriller, Romance, Fantasy,
#        Historical Fiction, Science Fiction, Children's Fiction, Non-Fiction, Fiction)
#        and granular secondary subgenres (Cozy Mystery, Crime Fiction,
#        Psychological Thriller, Contemporary Romance, Young Adult Fantasy, etc.).
#      - Updates `goodreads_cleaned`, `books_cleaned`, `genres_cleaned`, and
#        `book_genres_cleaned` relational tables.
#
#   2. User Preference Profiling (Feature Engineering with Decimal Precision):
#      - Computes volume, page counts, decimal average rating, median, standard
#        deviation, and high-star percentages across genres.
#      - Computes Author Affinity scores (N_read * Avg_Rating) and Bayesian
#        smoothed ratings, classifying authors into strategic tiers.
#      - Profiles annual reading pace and velocity over time.
#
#   Note: Recommendation candidate generation is deferred to a dedicated
#         Machine Learning model in a subsequent phase.
#
# Outputs (data/processed/):
#   - goodreads_cleaned.csv / .rds (enriched with standardized genres)
#   - books_cleaned.csv / .rds (synchronized)
#   - genres_cleaned.csv / .rds (standardized genre dimension)
#   - book_genres_cleaned.csv / .rds (updated many-to-many bridge)
#   - genre_profiles.csv / .rds (genre preference metrics)
#   - author_affinity_profiles.csv / .rds (author affinity metrics)
#   - reading_velocity_profiles.csv / .rds (annual reading pace)
# ==============================================================================
# ==============================================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(lubridate)
  library(tidyr)
  library(purrr)
  library(httr2)
  library(jsonlite)
})

# ------------------------------------------------------------------------------
# 1. API Metadata Enrichment Helpers
# ------------------------------------------------------------------------------

#' Clean title string for API querying
clean_title_for_query <- function(title) {
  if (is.null(title) || is.na(title)) return("")
  t <- stringr::str_remove(title, "\\s*\\([^)]*\\)")      # Strip series parens, e.g. (In Death, #55)
  t <- stringr::str_remove(t, ":.*$")                    # Strip subtitle after colon
  t <- stringr::str_remove_all(t, "[\"'\\[\\]#]")        # Remove quotes & brackets
  stringr::str_squish(t)
}

#' Fetch book subjects and ratings from Open Library API with disk caching
#'
#' @param title Book title
#' @param author Book author
#' @param isbn13 Clean ISBN-13 string
#' @param isbn Clean ISBN-10 string
#' @param cache_file Path to RDS cache file
#' @return List with subjects, ratings_average, ratings_count, and cache status
fetch_open_library_metadata <- function(
  title,
  author,
  isbn13 = NA_character_,
  isbn = NA_character_,
  cache_file = "data/cache/open_library_cache.rds"
) {
  # Initialize or load cache
  cache_dir <- dirname(cache_file)
  if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
  
  cache <- if (file.exists(cache_file)) {
    tryCatch(readRDS(cache_file), error = function(e) list())
  } else {
    list()
  }
  
  cache_key <- paste(tolower(trimws(title)), tolower(trimws(author)), sep = "::: ")
  if (!is.null(cache[[cache_key]])) {
    return(list(data = cache[[cache_key]], from_cache = TRUE, cache_obj = cache))
  }
  
  user_agent <- Sys.getenv("OPEN_LIBRARY_USER_AGENT", "TableauGoodreadsRecs/1.0 (tableau_rec_agent@example.com)")
  result <- list(
    title = title,
    author = author,
    subjects = character(0),
    ratings_average = NA_real_,
    ratings_count = NA_integer_,
    found = FALSE
  )
  
  q_title <- clean_title_for_query(title)
  q_author <- stringr::str_squish(as.character(author))
  
  # Perform request
  tryCatch({
    req <- httr2::request("https://openlibrary.org/search.json") %>%
      httr2::req_url_query(
        title = substr(q_title, 1, 45),
        author = substr(q_author, 1, 35),
        fields = "key,title,author_name,subject,ratings_average,ratings_count,first_publish_year",
        limit = 1
      ) %>%
      httr2::req_headers("User-Agent" = user_agent) %>%
      httr2::req_timeout(4)
    
    resp <- httr2::req_perform(req)
    body <- jsonlite::fromJSON(httr2::resp_body_string(resp), simplifyVector = FALSE)
    
    if (isTRUE(body$numFound > 0) && length(body$docs) >= 1) {
      doc <- body$docs[[1]]
      subjs <- if (!is.null(doc$subject) && is.list(doc$subject)) {
        as.character(unlist(head(doc$subject, 15)))
      } else {
        character(0)
      }
      
      avg_r <- if (!is.null(doc$ratings_average)) as.numeric(doc$ratings_average) else NA_real_
      cnt_r <- if (!is.null(doc$ratings_count)) as.integer(doc$ratings_count) else NA_integer_
      
      result$subjects <- subjs
      result$ratings_average <- avg_r
      result$ratings_count <- cnt_r
      result$found <- TRUE
    }
  }, error = function(e) {
    # Silently handle network timeouts or rate limits
  })
  
  # Save to cache
  cache[[cache_key]] <- result
  tryCatch(saveRDS(cache, cache_file), error = function(e) NULL)
  
  list(data = result, from_cache = FALSE, cache_obj = cache)
}

# ------------------------------------------------------------------------------
# 2. Hierarchical Genre Taxonomy Classifier
# ------------------------------------------------------------------------------

#' Classify a book into standardized primary and secondary genres
#'
#' Evaluates bookshelves tags, API subject tags, author bibliography, title
#' keywords, and publisher imprints using a multi-tier classification hierarchy.
classify_book_genres <- function(
  title,
  author,
  publisher = "",
  bookshelves = "",
  api_subjects = character(0)
) {
  # Normalize input text
  shelf_txt <- tolower(dplyr::coalesce(bookshelves, ""))
  api_txt   <- tolower(paste(api_subjects, collapse = " "))
  meta_txt  <- tolower(paste(
    dplyr::coalesce(title, ""),
    dplyr::coalesce(author, ""),
    dplyr::coalesce(publisher, "")
  ))
  all_txt   <- paste(shelf_txt, api_txt, meta_txt)
  
  # 1. Non-Fiction
  if (stringr::str_detect(all_txt, "colton underwood|first time: coming out|\\bmemoir\\b|\\bbiography\\b|\\bautobiography\\b|\\btrue crime\\b|\\bnon-fiction\\b|\\bnonfiction\\b|\\bessays\\b")) {
    subg <- if (stringr::str_detect(all_txt, "true crime")) "True Crime" else "Biography/Memoir"
    return(c("Non-Fiction", subg))
  }
  
  # 2. Children's / Middle Grade
  if (stringr::str_detect(all_txt, "louis sachar|ellen raskin|kate klise|\\bholes\\b|westing game|wayside school|\\bjuvenile\\b|\\bmiddle grade\\b|children's")) {
    return(c("Children's Fiction", "Middle Grade"))
  }
  
  # 3. Science Fiction / Speculative Fiction
  if (stringr::str_detect(all_txt, "sci-fi|science fiction|space opera|\\bdystopian\\b|\\balien\\b|galaxy|cyberpunk|time travel|andy weir|blake crouch|project hail mary")) {
    return(c("Science Fiction", "Speculative Fiction"))
  }
  
  # 4. Historical Fiction / Historical Mystery
  if (stringr::str_detect(all_txt, "deanna raybourn|sherry thomas|graham moore|arturo p.*rez-reverte|veronica speedwell|lady sherlock|victorian|regency|edwardian|wwii|\\bwar\\b|tudor|19th century|\\bhistorical\\b")) {
    return(c("Historical Fiction", "Historical Mystery"))
  }
  
  # 5. Fantasy / YA Fantasy / Urban Fantasy
  if (stringr::str_detect(all_txt, "rick riordan|jenny nimmo|jim butcher|rebecca yarros|angie sage|septimus heap|percy jackson|olympian|lightning thief|fourth wing|dresden|charlie bone|\\bwizard\\b|\\bmagic\\b|\\bdragon\\b|\\bwitch\\b|\\bvampire\\b|\\bfae\\b|\\bcurse\\b|sorcerer|\\bfantasy\\b")) {
    return(c("Fantasy", "Young Adult Fantasy"))
  }
  
  # 6. Cozy Mystery
  if (stringr::str_detect(all_txt, "culinary mystery|cozy|agatha raisin|hamish macbeth|goldy bear|coffeehouse|clambake|savannah reid|merry wrath|miss fortune|seaside caf|ellery adams|isis crawford|leslie langtry|dorothy howell|laura levine|mindy quigley|nancy j\\. cohen|kristin miller|ellie palmer|ann claire|dane mccaslin|anne marie stoddard|julia seales|sandra balzo|bree baker|jana deleon|lea wait|jessa maxwell|barbara ross|g\\.a\\. mckevett|needlepoint|bakeshop|bakery|tearoom|bookshop|scone|knit|quilting|\\bcat\\b|\\bdog\\b|\\binn\\b|cafe|paws|dead author|catch a killer|castle knoll|castle|murder at|murder in|death of|dead of summer|whiskey|golden spoon")) {
    return(c("Mystery", "Cozy Mystery"))
  }
  
  # 7. Crime Fiction / Police Procedural / Legal / Investigative Mystery
  if (stringr::str_detect(all_txt, "in death|j\\.d\\. robb|connelly|agatha christie|james patterson|jussi adler|jeff lindsay|hank phillippi|janice hallett|benjamin stevenson|rob rinder|jessie garcia|mary higgins clark|ashley flowers|karen m\\. mcmanus|holly jackson|jennifer lynn barnes|maureen johnson|ashley elston|jumata emill|susie dent|l\\.m\\. chilton|evelyn clarke|edgar cantero|liz moore|anthony horowitz|alafair burke|minotaur|poisoned pen|berkley prime crime|crimeline|investigation|murder|homicide|detective|whodunit|courtroom|alibi|killer|body|dead|stabbing|fatal|blood|death|thief|group chat dies|neighborhood watch|poirot|marple|marlow belle|inspector")) {
    return(c("Mystery", "Crime Fiction"))
  }
  
  # 8. Psychological Thriller / Domestic Suspense
  if (stringr::str_detect(all_txt, "lisa gardner|riley sager|gilly macmillan|ellery lloyd|amanda jayatissa|charlie donlea|lisa jackson|shari lapena|jo piazza|lisa unger|jeneva rose|kelly mullen|alex michaelides|a\\.j\\. finn|jessica knoll|a\\.r\\. torre|rachel howzell hall|gillian mcallister|laura dave|alice feeney|chandler baker|megan collins|amy tintera|julia bartz|megan lally|hannah selinger|tara laskowski|david ellis|emma rosenblum|rachel hawkins|gina lamanna|jason rekulak|joseph r\\. garber|louise hegarty|harlan coben|freida mcfadden|lucy foley|ruth ware|thriller|suspense|chilling|psychological|empty eyes|last time i lied|long weekend|the club|lying to you|girl who survived|good lie|silent patient|housemaid|behind closed doors|couple next door|look closer|mother next door|very bad company|hidden pictures|vertical run")) {
    return(c("Thriller", "Psychological Thriller"))
  }
  
  # 9. Romance / Contemporary Romance / Rom-Com
  if (stringr::str_detect(all_txt, "mary kay andrews|brenda novak|katherine center|meg cabot|beth o|carley fortune|christina lauren|sara desai|sophie cousens|ally carter|olivia muenter|audrey bellezza|sophie kinsella|emily giffin|katherine st|lucy sykes|shelby van pelt|rebecca serle|sarah adler|devon daniels|annabel monaghan|kristyn j|jane heller|lauren conrad|colleen hoover|emily henry|ali hazelwood|elin hilderbrand|nora roberts|melissa wiesner|aisha saeed|lauren okie|yulin kuang|love|wedding|summer|beach|date|heart|kiss|holiday|boy next door|shippers|save the date|golden summer|honeymoon|bride|nantucket")) {
    return(c("Romance", "Contemporary Romance"))
  }
  
  # 10. Contemporary / Humorous Fiction
  if (stringr::str_detect(all_txt, "michelle markowitz|hey ladies|satire|humor")) {
    return(c("Fiction", "Humorous Fiction"))
  }
  
  # Fallback
  return(c("Fiction", "Contemporary Fiction"))
}

# ------------------------------------------------------------------------------
# 3. User Preference Profiling
# ------------------------------------------------------------------------------

#' Profile user reading preferences across genres
profile_genre_preferences <- function(goodreads_df) {
  read_books <- goodreads_df %>%
    dplyr::filter(exclusive_shelf == "read", !is.na(my_rating))
  
  total_read_count <- nrow(read_books)
  
  genre_summary <- read_books %>%
    dplyr::group_by(primary_genre) %>%
    dplyr::summarise(
      books_read         = dplyr::n(),
      total_pages        = sum(number_of_pages, na.rm = TRUE),
      avg_decimal_rating = round(mean(my_rating), 2),
      median_rating      = median(my_rating),
      rating_sd          = round(sd(my_rating), 2),
      four_plus_pct      = round(100 * mean(my_rating >= 4.0), 1),
      five_star_pct      = round(100 * mean(my_rating == 5.0), 1),
      pct_of_library     = round(100 * dplyr::n() / total_read_count, 1),
      top_author         = names(sort(table(author), decreasing = TRUE))[1],
      .groups = "drop"
    ) %>%
    dplyr::arrange(dplyr::desc(books_read), dplyr::desc(avg_decimal_rating)) %>%
    dplyr::mutate(genre_rank = dplyr::row_number())
  
  genre_summary
}

#' Profile author affinity and composite scores
profile_author_affinity <- function(goodreads_df, authors_df) {
  read_books <- goodreads_df %>%
    dplyr::filter(exclusive_shelf == "read", !is.na(my_rating))
  
  overall_mean <- mean(read_books$my_rating, na.rm = TRUE)
  
  author_stats <- read_books %>%
    dplyr::group_by(author) %>%
    dplyr::summarise(
      books_read       = dplyr::n(),
      total_pages_read = sum(number_of_pages, na.rm = TRUE),
      avg_rating       = round(mean(my_rating), 2),
      median_rating    = median(my_rating),
      min_rating       = min(my_rating),
      max_rating       = max(my_rating),
      five_star_count  = sum(my_rating == 5.0),
      four_plus_count  = sum(my_rating >= 4.0),
      top_rated_book   = title[which.max(my_rating)][1],
      primary_genre    = names(sort(table(primary_genre), decreasing = TRUE))[1],
      affinity_score   = round(dplyr::n() * mean(my_rating), 2),
      # Bayesian smoothed rating: pulls authors with small sample size toward the library mean
      bayesian_score   = round((dplyr::n() * mean(my_rating) + 2 * overall_mean) / (dplyr::n() + 2), 2),
      .groups = "drop"
    ) %>%
    dplyr::arrange(dplyr::desc(affinity_score), dplyr::desc(avg_rating)) %>%
    dplyr::mutate(
      author_tier = dplyr::case_when(
        affinity_score >= 40.0 ~ "Tier 1: Core All-Time Favorite",
        books_read >= 4 & avg_rating >= 4.00 ~ "Tier 2: Highly Regarded Author",
        books_read >= 2 ~ "Tier 3: Solid Frequent Author",
        TRUE ~ "Tier 4: Single-Book Read"
      )
    ) %>%
    dplyr::left_join(
      authors_df %>% dplyr::select(author = name, author_id),
      by = "author"
    ) %>%
    dplyr::select(
      author_id, author_name = author, primary_genre, books_read,
      total_pages_read, avg_rating, median_rating, affinity_score,
      bayesian_score, author_tier, top_rated_book, max_rating,
      five_star_count, four_plus_count
    )
  
  author_stats
}

#' Profile reading pace and velocity across calendar years
profile_reading_velocity <- function(goodreads_df) {
  read_books <- goodreads_df %>%
    dplyr::filter(exclusive_shelf == "read", !is.na(date_read)) %>%
    dplyr::mutate(reading_year = lubridate::year(date_read))
  
  read_books %>%
    dplyr::group_by(reading_year) %>%
    dplyr::summarise(
      books_read         = dplyr::n(),
      total_pages_read   = sum(number_of_pages, na.rm = TRUE),
      avg_decimal_rating = round(mean(my_rating, na.rm = TRUE), 2),
      avg_pages_per_book = round(mean(number_of_pages, na.rm = TRUE), 0),
      five_star_count    = sum(my_rating == 5.0, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    dplyr::arrange(dplyr::desc(reading_year))
}

# ------------------------------------------------------------------------------
# 4. Main Enrichment Pipeline
# ------------------------------------------------------------------------------

enrich_and_profile_data <- function(
  processed_dir = "data/processed",
  cache_dir     = "data/cache",
  use_api       = TRUE,
  verbose       = TRUE
) {
  if (verbose) {
    cat("\n===================================================================\n")
    cat("       Tableau Goodreads Analytics - Phase 2 Data Enrichment        \n")
    cat("===================================================================\n")
    cat("Processed Directory :", processed_dir, "\n")
    cat("API Metadata Cache  :", cache_dir, "\n")
    cat("Live API Enrichment :", use_api, "\n\n")
  }
  
  # Verify input files
  required_files <- c(
    "goodreads_cleaned.rds",
    "books_cleaned.rds",
    "authors_cleaned.rds",
    "reading_log_cleaned.rds"
  )
  for (rf in required_files) {
    p <- file.path(processed_dir, rf)
    if (!file.exists(p)) {
      stop(sprintf("Required file '%s' not found. Please run Phase 1 (R/clean_data.R) first.", p))
    }
  }
  
  # Load data
  goodreads_df <- readRDS(file.path(processed_dir, "goodreads_cleaned.rds"))
  books_df     <- readRDS(file.path(processed_dir, "books_cleaned.rds"))
  authors_df   <- readRDS(file.path(processed_dir, "authors_cleaned.rds"))
  log_df       <- readRDS(file.path(processed_dir, "reading_log_cleaned.rds"))
  
  total_books <- nrow(goodreads_df)
  if (verbose) cat(sprintf("✓ Loaded %d cleaned books and %d authors from %s\n", total_books, nrow(authors_df), processed_dir))
  
  # ----------------------------------------------------------------------------
  # Step 1: Open Library API Subject & Theme Enrichment
  # ----------------------------------------------------------------------------
  cache_file <- file.path(cache_dir, "open_library_cache.rds")
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
  
  # Identify books that benefit from API lookup:
  # Unread books (to-read, currently-reading) + books with generic genres
  target_lookup_idx <- which(
    goodreads_df$exclusive_shelf %in% c("to-read", "currently-reading") |
    goodreads_df$primary_genre == "Fiction"
  )
  
  api_subjects_list <- vector("list", total_books)
  
  if (use_api && length(target_lookup_idx) > 0) {
    if (verbose) cat(sprintf("• Inspecting Open Library metadata cache for %d candidate books...\n", length(target_lookup_idx)))
    
    # Pre-populate from existing cache
    cache <- if (file.exists(cache_file)) tryCatch(readRDS(cache_file), error = function(e) list()) else list()
    cache_hits <- 0
    api_calls  <- 0
    
    for (idx in target_lookup_idx) {
      t_val <- goodreads_df$title[idx]
      a_val <- goodreads_df$author[idx]
      key   <- paste(tolower(trimws(t_val)), tolower(trimws(a_val)), sep = "::: ")
      
      if (!is.null(cache[[key]])) {
        cache_hits <- cache_hits + 1
        api_subjects_list[[idx]] <- cache[[key]]$subjects
      } else if (api_calls < 10) { # Perform polite batch lookup for un-cached books
        api_calls <- api_calls + 1
        res <- fetch_open_library_metadata(
          t_val, a_val,
          isbn13 = goodreads_df$isbn13[idx],
          isbn = goodreads_df$isbn[idx],
          cache_file = cache_file
        )
        api_subjects_list[[idx]] <- res$data$subjects
      }
    }
    if (verbose) cat(sprintf("  ✓ Open Library Cache: %d hits, %d live API requests\n", cache_hits, api_calls))
  }
  
  # ----------------------------------------------------------------------------
  # Step 2: Multi-Tier Genre Classification & Enrichment
  # ----------------------------------------------------------------------------
  if (verbose) cat("• Applying hierarchical genre taxonomy engine...\n")
  
  enriched_genres <- purrr::map(
    seq_len(total_books),
    function(i) {
      classify_book_genres(
        title        = goodreads_df$title[i],
        author       = goodreads_df$author[i],
        publisher    = goodreads_df$publisher[i],
        bookshelves  = goodreads_df$bookshelves[i],
        api_subjects = api_subjects_list[[i]]
      )
    }
  )
  
  new_primary_genres   <- purrr::map_chr(enriched_genres, 1)
  new_secondary_genres <- purrr::map_chr(enriched_genres, 2)
  
  # Update goodreads_cleaned
  goodreads_enriched <- goodreads_df %>%
    dplyr::mutate(
      primary_genre   = new_primary_genres,
      secondary_genre = new_secondary_genres
    )
  
  # Rebuild genres table with complete vocabulary from library
  all_unique_genres <- sort(unique(c(
    new_primary_genres[!is.na(new_primary_genres)],
    new_secondary_genres[!is.na(new_secondary_genres)]
  )))
  
  genres_enriched <- tibble::tibble(
    genre_id   = seq_along(all_unique_genres),
    genre_name = all_unique_genres
  )
  
  # Rebuild book_genres table
  book_genres_list <- list()
  for (b_i in seq_len(total_books)) {
    b_id <- goodreads_enriched$book_id[b_i]
    pg   <- new_primary_genres[b_i]
    sg   <- new_secondary_genres[b_i]
    
    if (!is.na(pg)) {
      gid <- genres_enriched$genre_id[genres_enriched$genre_name == pg]
      book_genres_list[[length(book_genres_list) + 1]] <- tibble::tibble(
        book_id    = b_id,
        genre_id   = gid,
        genre_type = "primary"
      )
    }
    if (!is.na(sg) && sg != pg) {
      gid <- genres_enriched$genre_id[genres_enriched$genre_name == sg]
      book_genres_list[[length(book_genres_list) + 1]] <- tibble::tibble(
        book_id    = b_id,
        genre_id   = gid,
        genre_type = "secondary"
      )
    }
  }
  
  book_genres_enriched <- dplyr::bind_rows(book_genres_list) %>%
    dplyr::distinct(book_id, genre_id, .keep_all = TRUE)
  
  # ----------------------------------------------------------------------------
  # Step 3: User Preference Profiling (ML Feature Engineering)
  # ----------------------------------------------------------------------------
  if (verbose) cat("• Profiling reading taste with granular decimal ratings...\n")
  genre_profiles          <- profile_genre_preferences(goodreads_enriched)
  author_affinity_profiles <- profile_author_affinity(goodreads_enriched, authors_df)
  reading_velocity_profiles <- profile_reading_velocity(goodreads_enriched)
  
  # ----------------------------------------------------------------------------
  # Step 4: Relational Integrity Validations
  # ----------------------------------------------------------------------------
  if (verbose) cat("• Running relational integrity assertions...\n")
  
  # 1. Check all book_genres genre_ids exist in genres table
  stopifnot("Integrity Check Failed: Missing FK in book_genres genre_id!" = 
    all(book_genres_enriched$genre_id %in% genres_enriched$genre_id))
  
  # 2. Check all book_genres book_ids exist in books table
  stopifnot("Integrity Check Failed: Missing FK in book_genres book_id!" = 
    all(book_genres_enriched$book_id %in% books_df$book_id))
  
  # ----------------------------------------------------------------------------
  # Step 5: Export Enriched & Modeled Files (.csv and .rds)
  # ----------------------------------------------------------------------------
  if (verbose) cat("• Exporting enriched datasets to", processed_dir, "...\n")
  
  export_bundle <- list(
    "goodreads_cleaned"          = goodreads_enriched,
    "genres_cleaned"             = genres_enriched,
    "book_genres_cleaned"        = book_genres_enriched,
    "books_cleaned"              = books_df,
    "genre_profiles"             = genre_profiles,
    "author_affinity_profiles"   = author_affinity_profiles,
    "reading_velocity_profiles"  = reading_velocity_profiles
  )
  
  for (tbl_name in names(export_bundle)) {
    csv_file <- file.path(processed_dir, paste0(tbl_name, ".csv"))
    rds_file <- file.path(processed_dir, paste0(tbl_name, ".rds"))
    readr::write_csv(export_bundle[[tbl_name]], csv_file, na = "")
    saveRDS(export_bundle[[tbl_name]], rds_file)
  }
  
  # ----------------------------------------------------------------------------
  # Step 6: Summary Reporting
  # ----------------------------------------------------------------------------
  if (verbose) {
    cat("\n-------------------------------------------------------------------\n")
    cat("                     ENRICHMENT SUMMARY REPORT                     \n")
    cat("-------------------------------------------------------------------\n")
    cat(sprintf("• Total Books Enriched         : %d\n", nrow(goodreads_enriched)))
    cat(sprintf("• Standardized Genres Catalog  : %d genres\n", nrow(genres_enriched)))
    cat(sprintf("• Authors Profiled             : %d\n", nrow(author_affinity_profiles)))
    cat(sprintf("• Downstream ML Recommendation : Ready for dedicated ML model\n"))
    
    cat("\n• Enriched Primary Genre Distribution:\n")
    for (g_i in seq_len(nrow(genre_profiles))) {
      cat(sprintf("   - %-22s : %3d books (%4.1f%%) | Avg Rating: %4.2f ★ | Top: %s\n",
        genre_profiles$primary_genre[g_i],
        genre_profiles$books_read[g_i],
        genre_profiles$pct_of_library[g_i],
        genre_profiles$avg_decimal_rating[g_i],
        genre_profiles$top_author[g_i]
      ))
    }
    
    cat("\n• Top 10 Author Affinity Scores (Frequency × Decimal Rating):\n")
    top_authors <- head(author_affinity_profiles, 10)
    for (a_i in seq_len(nrow(top_authors))) {
      cat(sprintf("   %2d. %-20s : Affinity %5.1f | %2d books | Avg: %4.2f ★ | %s\n",
        a_i,
        top_authors$author_name[a_i],
        top_authors$affinity_score[a_i],
        top_authors$books_read[a_i],
        top_authors$avg_rating[a_i],
        top_authors$author_tier[a_i]
      ))
    }
    
    cat("\n✓ Phase 2 Enriched Data Successfully Exported to:", processed_dir, "\n")
    cat("===================================================================\n\n")
  }
  
  invisible(list(
    goodreads_enriched        = goodreads_enriched,
    genres                    = genres_enriched,
    book_genres               = book_genres_enriched,
    genre_profiles            = genre_profiles,
    author_affinity_profiles  = author_affinity_profiles,
    reading_velocity_profiles = reading_velocity_profiles
  ))
}

# Alias for backward compatibility
enrich_and_recommend <- enrich_and_profile_data

# ------------------------------------------------------------------------------
# 5. Command Line Execution Entry Point
# ------------------------------------------------------------------------------
if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  proc_dir <- if (length(args) >= 1) args[1] else Sys.getenv("GOODREADS_PROCESSED_DIR", "data/processed")
  c_dir    <- if (length(args) >= 2) args[2] else Sys.getenv("GOODREADS_CACHE_DIR", "data/cache")
  
  enrich_and_profile_data(processed_dir = proc_dir, cache_dir = c_dir)
}
