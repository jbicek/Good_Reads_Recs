#!/usr/bin/env Rscript

# ==============================================================================
# Tableau Goodreads Dashboard - Phase 1: Data Preparation & Cleaning
# Script: R/clean_data.R
#
# Description:
#   Ingests and cleans raw Goodreads CSV exports using tidyverse.
#   - Standardizes dates (Date Read, Date Added) to ISO YYYY-MM-DD.
#   - Strips formula-wrapped identifiers on ISBN/ISBN13 fields.
#   - Extracts granular quarter-star ratings (0.25, 0.50, 0.75, etc.) from
#     Private Notes, My Review, Bookshelf tags, and raw decimal ratings,
#     mapping unrated (0) books to NA/NULL.
#   - Extracts key dimensions: authors, books, genres, and reading logs.
#   - Exports both a comprehensive clean flat dataset and normalized
#     relational tables (.csv and .rds) into data/processed/.
# ==============================================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(lubridate)
  library(tidyr)
  library(purrr)
})

# ------------------------------------------------------------------------------
# 1. Helper Functions
# ------------------------------------------------------------------------------

#' Clean formula-wrapped and malformed ISBN strings
#'
#' Goodreads exports ISBNs formatted as `=""1728295807""` or `=""""`.
#' This function strips Excel formula prefixes, quotes, and whitespace,
#' returning a clean character string or NA_character_.
clean_isbn <- function(x) {
  if (is.null(x)) return(character(0))
  cleaned <- stringr::str_remove_all(as.character(x), '[="]')
  cleaned <- stringr::str_trim(cleaned)
  dplyr::if_else(nzchar(cleaned), cleaned, NA_character_)
}

#' Extract quarter-star and fractional ratings
#'
#' Scans Private Notes, My Review, bookshelf tags, and the raw rating column
#' for quarter-star increments (e.g., 1.25, 2.75, 3.50, 4.75).
#' Falls back to the Goodreads integer rating if positive, or NA if unrated (0).
extract_quarter_rating <- function(notes, review, shelves, raw_rating) {
  parse_single_text <- function(txt) {
    if (is.na(txt) || !nzchar(trimws(txt))) return(NA_real_)
    
    # Pattern 1: Tag format, e.g. "4-25-stars", "rating-4-75", "stars-3-50", "4_25"
    m_tag <- stringr::str_match(
      txt,
      "(?i)(?:rating[-_]|stars?[-_])?([1-5])[-_](25|5|50|75)(?:[-_]stars?)?"
    )
    if (!is.na(m_tag[1, 1])) {
      base <- as.numeric(m_tag[1, 2])
      dec_str <- m_tag[1, 3]
      dec <- if (dec_str == "5") 0.50 else as.numeric(paste0("0.", dec_str))
      val <- base + dec
      if (val >= 0.25 && val <= 5.0) return(val)
    }
    
    # Pattern 2: Text format, e.g. "4.25 / 5", "4.75 stars", "3.5★", "Rating: 4.25", "4.75 out of 5"
    m_star <- stringr::str_match(
      txt,
      "(?i)(?:rating\\s*[:=-]?\\s*)?([0-5](?:\\.(?:25|5|50|75))?)\\s*(?:/\\s*5(?:\\.0)?|\\s*stars?|\\s*★|\\s*out\\s+of\\s+5)"
    )
    if (!is.na(m_star[1, 2])) {
      val <- as.numeric(m_star[1, 2])
      if (!is.na(val) && val > 0 && val <= 5.0) return(val)
    }
    
    # Pattern 3: Explicit decimal notation, e.g. "4.25", "3.75", "4.50"
    m_dec <- stringr::str_match(txt, "(?i)\\b([0-5]\\.(?:25|5|50|75))\\b")
    if (!is.na(m_dec[1, 2])) {
      val <- as.numeric(m_dec[1, 2])
      if (!is.na(val) && val > 0 && val <= 5.0) return(val)
    }
    
    return(NA_real_)
  }

  n <- length(raw_rating)
  res <- numeric(n)
  raw_num <- suppressWarnings(as.numeric(raw_rating))
  
  for (i in seq_len(n)) {
    val <- NA_real_
    
    # 1. Scan Private Notes
    if (!is.null(notes) && length(notes) >= i) {
      val <- parse_single_text(notes[i])
    }
    
    # 2. Scan My Review
    if (is.na(val) && !is.null(review) && length(review) >= i) {
      val <- parse_single_text(review[i])
    }
    
    # 3. Scan Bookshelves
    if (is.na(val) && !is.null(shelves) && length(shelves) >= i) {
      val <- parse_single_text(shelves[i])
    }
    
    # 4. Check if raw rating is already a quarter-star decimal (e.g. 3.75)
    r <- raw_num[i]
    if (is.na(val) && !is.na(r) && (r %% 1 != 0)) {
      rounded <- round(r * 4) / 4
      if (abs(r - rounded) < 0.01 && rounded > 0 && rounded <= 5) {
        val <- rounded
      }
    }
    
    # 5. Fallback to raw Goodreads integer rating
    if (is.na(val)) {
      if (!is.na(r) && r > 0) {
        val <- r
      } else {
        val <- NA_real_ # Unrated (0) maps to NA
      }
    }
    
    # Ensure precision is rounded to quarter stars
    if (!is.na(val)) {
      val <- round(val * 4) / 4
    }
    res[i] <- val
  }
  
  res
}

#' Assign rating tier according to Tableau analytical categories
get_rating_tier <- function(rating) {
  dplyr::case_when(
    is.na(rating)            ~ "Unrated",
    rating >= 4.75           ~ "Masterpiece / All-Time Favorite (4.75–5.00★)",
    rating >= 4.25           ~ "Highly Recommended (4.25–4.50★)",
    rating >= 3.50           ~ "Solid Read (3.50–4.00★)",
    rating >= 2.75           ~ "Mixed / Average (2.75–3.25★)",
    TRUE                     ~ "Disappointing (< 2.75★)"
  )
}

#' Extract primary and secondary genres from bookshelves with heuristic fallback
parse_genres_from_shelves <- function(shelves, title, publisher, author) {
  cleaned_shelves <- tolower(dplyr::coalesce(shelves, ""))
  tags <- stringr::str_split(cleaned_shelves, ",")[[1]]
  tags <- stringr::str_trim(tags)
  
  # Remove system shelves and rating tags
  ignore_pattern <- "^(to-read|currently-reading|read|owned|favorites|books-i-own|kindle|audiobook|ebook|paperback|hardcover|dnf|did-not-finish|rating-.*|[0-5](?:[-_.][0-9]+)?-stars?|\\d+-stars?)$"
  genre_tags <- tags[!stringr::str_detect(tags, ignore_pattern) & nzchar(tags)]
  
  if (length(genre_tags) >= 2) {
    p <- stringr::str_to_title(stringr::str_replace_all(genre_tags[1], "[-_]", " "))
    s <- stringr::str_to_title(stringr::str_replace_all(genre_tags[2], "[-_]", " "))
    return(list(primary = p, secondary = s))
  } else if (length(genre_tags) == 1) {
    p <- stringr::str_to_title(stringr::str_replace_all(genre_tags[1], "[-_]", " "))
    return(list(primary = p, secondary = NA_character_))
  }
  
  # Heuristic fallback based on Title, Publisher, and Author keywords
  txt <- tolower(paste(
    dplyr::coalesce(title, ""),
    dplyr::coalesce(publisher, ""),
    dplyr::coalesce(author, "")
  ))
  
  if (stringr::str_detect(txt, "culinary mystery|cozy|agatha raisin|hamish macbeth|goldy bear|coffeehouse|clambake|savannah reid|merry wrath|miss fortune|seaside caf")) {
    return(list(primary = "Mystery", secondary = "Cozy Mystery"))
  }
  if (stringr::str_detect(txt, "mystery|murder|homicide|detective|poirot|whodunit|minotaur|poisoned pen|crimeline|berkley prime crime|in death|j\\.d\\. robb|kinsey millhone|kay scarpetta|agatha christie|anthony horowitz")) {
    return(list(primary = "Mystery", secondary = "Crime Fiction"))
  }
  if (stringr::str_detect(txt, "thriller|suspense|chilling|psychological|connelly|lisa gardner|david baldacci|lee child|harlan coben|freida mcfadden|lucy foley|ruth ware")) {
    return(list(primary = "Thriller", secondary = "Suspense"))
  }
  if (stringr::str_detect(txt, "fantasy|magic|dragon|wizard|witch|sword|spell|angie sage|septimus heap|tolkien|rowling|sanderson|sarah j\\. maas")) {
    return(list(primary = "Fantasy", secondary = "Young Adult Fantasy"))
  }
  if (stringr::str_detect(txt, "sci-fi|science fiction|space|alien|galaxy|dystopi|time travel|cyber")) {
    return(list(primary = "Science Fiction", secondary = "Speculative Fiction"))
  }
  if (stringr::str_detect(txt, "historical|wwii|war|regency|victorian|tudor|century|florence|renaissance")) {
    return(list(primary = "Historical Fiction", secondary = "Historical"))
  }
  if (stringr::str_detect(txt, "romance|love story|wedding|beach read|hilderbrand|colleen hoover|emily henry|ali hazelwood")) {
    return(list(primary = "Romance", secondary = "Contemporary Romance"))
  }
  if (stringr::str_detect(txt, "memoir|biography|autobiography|non-fiction|history|essay")) {
    return(list(primary = "Non-Fiction", secondary = "Biography/Memoir"))
  }
  
  return(list(primary = "Fiction", secondary = "General Fiction"))
}

# ------------------------------------------------------------------------------
# 2. Main ETL Pipeline Function
# ------------------------------------------------------------------------------

clean_goodreads_data <- function(
  raw_file = "data/raw/goodreads_library_export.csv",
  output_dir = "data/processed",
  verbose = TRUE
) {
  if (verbose) {
    cat("\n===================================================================\n")
    cat("       Tableau Goodreads Analytics - Phase 1 Data Cleaning          \n")
    cat("===================================================================\n")
    cat("Input Raw CSV  :", raw_file, "\n")
    cat("Output Dir     :", output_dir, "\n\n")
  }

  if (!file.exists(raw_file)) {
    stop(sprintf("Raw Goodreads file '%s' not found. Please verify the path.", raw_file))
  }
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  # Read raw export with character defaults to prevent any silent truncation
  df_raw <- readr::read_csv(
    raw_file,
    col_types = readr::cols(.default = readr::col_character()),
    show_col_types = FALSE
  )
  
  total_records <- nrow(df_raw)
  if (verbose) cat(sprintf("✓ Ingested %d raw records from %s\n", total_records, raw_file))

  # ----------------------------------------------------------------------------
  # Data Cleaning & Transformations
  # ----------------------------------------------------------------------------
  
  # Standardize dates
  date_read_parsed <- lubridate::ymd(df_raw$`Date Read`)
  date_added_parsed <- lubridate::ymd(df_raw$`Date Added`)
  
  # Clean ISBN identifiers
  clean_isbn10 <- clean_isbn(df_raw$ISBN)
  clean_isbn13 <- clean_isbn(df_raw$ISBN13)
  
  # Parse fractional ratings & integer Goodreads ratings
  raw_ratings_num <- suppressWarnings(as.numeric(df_raw$`My Rating`))
  decimal_ratings <- extract_quarter_rating(
    df_raw$`Private Notes`,
    df_raw$`My Review`,
    df_raw$Bookshelves,
    df_raw$`My Rating`
  )
  raw_gr_ratings <- as.integer(floor(dplyr::coalesce(raw_ratings_num, 0)))

  # Extract genres
  genre_results <- purrr::map(
    seq_len(total_records),
    ~parse_genres_from_shelves(
      df_raw$Bookshelves[.x],
      df_raw$Title[.x],
      df_raw$Publisher[.x],
      df_raw$Author[.x]
    )
  )
  primary_genres <- purrr::map_chr(genre_results, "primary")
  secondary_genres <- purrr::map_chr(genre_results, "secondary")

  # Formatted star labels and tiers
  rating_labels <- dplyr::if_else(
    !is.na(decimal_ratings),
    sprintf("%.2f ★", decimal_ratings),
    NA_character_
  )
  rating_tiers <- get_rating_tier(decimal_ratings)

  # Build unified flat clean dataframe
  goodreads_cleaned <- tibble::tibble(
    book_id               = as.integer(df_raw$`Book Id`),
    title                 = stringr::str_squish(df_raw$Title),
    author                = stringr::str_squish(df_raw$Author),
    author_lf             = stringr::str_squish(df_raw$`Author l-f`),
    additional_authors    = stringr::str_squish(df_raw$`Additional Authors`),
    isbn                  = clean_isbn10,
    isbn13                = clean_isbn13,
    my_rating             = decimal_ratings,
    raw_goodreads_rating  = raw_gr_ratings,
    rating_label          = rating_labels,
    rating_tier           = rating_tiers,
    publisher             = stringr::str_squish(df_raw$Publisher),
    binding               = stringr::str_squish(df_raw$Binding),
    number_of_pages       = as.integer(df_raw$`Number of Pages`),
    year_published        = as.integer(df_raw$`Year Published`),
    original_pub_year     = as.integer(df_raw$`Original Publication Year`),
    date_read             = date_read_parsed,
    date_added            = date_added_parsed,
    exclusive_shelf       = stringr::str_squish(df_raw$`Exclusive Shelf`),
    bookshelves           = df_raw$Bookshelves,
    primary_genre         = primary_genres,
    secondary_genre       = secondary_genres,
    read_count            = dplyr::coalesce(as.integer(df_raw$`Read Count`), 1L),
    owned_copies          = dplyr::coalesce(as.integer(df_raw$`Owned Copies`), 0L)
  ) %>%
    dplyr::mutate(
      publisher = dplyr::if_else(nzchar(publisher), publisher, NA_character_),
      binding = dplyr::if_else(nzchar(binding), binding, NA_character_),
      additional_authors = dplyr::if_else(nzchar(additional_authors), additional_authors, NA_character_)
    )

  # ----------------------------------------------------------------------------
  # Relational Tables (Matching Phase 3 SQL Schema)
  # ----------------------------------------------------------------------------

  # 1. authors: author_id PK, name, name_lf
  authors_df <- goodreads_cleaned %>%
    dplyr::transmute(
      name = author,
      name_lf = author_lf
    ) %>%
    dplyr::distinct(name, .keep_all = TRUE) %>%
    dplyr::arrange(name) %>%
    dplyr::mutate(author_id = dplyr::row_number()) %>%
    dplyr::select(author_id, name, name_lf)

  # 2. books: book_id PK, title, author_id FK, isbn, isbn13, publisher, binding, number_of_pages, year_published, original_pub_year
  books_df <- goodreads_cleaned %>%
    dplyr::left_join(
      authors_df %>% dplyr::select(author = name, author_id),
      by = "author"
    ) %>%
    dplyr::transmute(
      book_id = book_id,
      title = title,
      author_id = author_id,
      isbn = isbn,
      isbn13 = isbn13,
      publisher = publisher,
      binding = binding,
      number_of_pages = number_of_pages,
      year_published = year_published,
      original_pub_year = original_pub_year
    )

  # 3. genres: genre_id PK, genre_name
  distinct_genres <- sort(unique(c(
    primary_genres[!is.na(primary_genres)],
    secondary_genres[!is.na(secondary_genres)]
  )))
  genres_df <- tibble::tibble(
    genre_id = seq_along(distinct_genres),
    genre_name = distinct_genres
  )

  # 4. book_genres: book_id FK, genre_id FK, genre_type
  book_genres_list <- list()
  for (i in seq_len(total_records)) {
    b_id <- goodreads_cleaned$book_id[i]
    pg <- primary_genres[i]
    sg <- secondary_genres[i]
    
    if (!is.na(pg)) {
      gid <- genres_df$genre_id[genres_df$genre_name == pg]
      book_genres_list[[length(book_genres_list) + 1]] <- tibble::tibble(
        book_id = b_id,
        genre_id = gid,
        genre_type = "primary"
      )
    }
    if (!is.na(sg) && sg != pg) {
      gid <- genres_df$genre_id[genres_df$genre_name == sg]
      book_genres_list[[length(book_genres_list) + 1]] <- tibble::tibble(
        book_id = b_id,
        genre_id = gid,
        genre_type = "secondary"
      )
    }
  }
  book_genres_df <- dplyr::bind_rows(book_genres_list) %>%
    dplyr::distinct(book_id, genre_id, .keep_all = TRUE)

  # 5. reading_log: log_id PK, book_id FK, my_rating NUMERIC(3, 2), raw_goodreads_rating INT, date_read, date_added, exclusive_shelf, read_count
  reading_log_df <- goodreads_cleaned %>%
    dplyr::transmute(
      log_id = dplyr::row_number(),
      book_id = book_id,
      my_rating = my_rating,
      raw_goodreads_rating = raw_goodreads_rating,
      date_read = date_read,
      date_added = date_added,
      exclusive_shelf = exclusive_shelf,
      read_count = read_count
    )

  # ----------------------------------------------------------------------------
  # Validation & Integrity Checks
  # ----------------------------------------------------------------------------
  invalid_ratings <- reading_log_df %>%
    dplyr::filter(!is.na(my_rating)) %>%
    dplyr::filter((my_rating < 0.0 | my_rating > 5.0) | ((my_rating * 100) %% 25 != 0))

  missing_author_fks <- sum(is.na(books_df$author_id))
  missing_book_fks <- sum(!reading_log_df$book_id %in% books_df$book_id)
  missing_genre_fks <- sum(!book_genres_df$genre_id %in% genres_df$genre_id)

  stopifnot("Integrity Check Failed: Invalid quarter-star rating found!" = nrow(invalid_ratings) == 0)
  stopifnot("Integrity Check Failed: Books with missing author FK!" = missing_author_fks == 0)
  stopifnot("Integrity Check Failed: Reading log with missing book FK!" = missing_book_fks == 0)
  stopifnot("Integrity Check Failed: Book genres with missing genre FK!" = missing_genre_fks == 0)

  # ----------------------------------------------------------------------------
  # Export Clean Datasets (.csv and .rds)
  # ----------------------------------------------------------------------------
  export_targets <- list(
    "goodreads_cleaned"  = goodreads_cleaned,
    "books_cleaned"      = books_df,
    "authors_cleaned"    = authors_df,
    "genres_cleaned"     = genres_df,
    "book_genres_cleaned"= book_genres_df,
    "reading_log_cleaned"= reading_log_df
  )

  for (name in names(export_targets)) {
    csv_file <- file.path(output_dir, paste0(name, ".csv"))
    rds_file <- file.path(output_dir, paste0(name, ".rds"))
    readr::write_csv(export_targets[[name]], csv_file, na = "")
    saveRDS(export_targets[[name]], rds_file)
  }

  # ----------------------------------------------------------------------------
  # Summary Reporting
  # ----------------------------------------------------------------------------
  if (verbose) {
    cat("\n-------------------------------------------------------------------\n")
    cat("                       CLEANING SUMMARY REPORT                     \n")
    cat("-------------------------------------------------------------------\n")
    cat(sprintf("• Total Books Processed       : %d\n", nrow(books_df)))
    cat(sprintf("• Unique Authors Extracted    : %d\n", nrow(authors_df)))
    cat(sprintf("• Unique Genres Cataloged     : %d\n", nrow(genres_df)))
    cat(sprintf("• Reading Log Entries         : %d\n", nrow(reading_log_df)))
    cat(sprintf("• Valid ISBN-10 Cleaned       : %d (%.1f%%)\n", sum(!is.na(books_df$isbn)), 100 * mean(!is.na(books_df$isbn))))
    cat(sprintf("• Valid ISBN-13 Cleaned       : %d (%.1f%%)\n", sum(!is.na(books_df$isbn13)), 100 * mean(!is.na(books_df$isbn13))))
    cat(sprintf("• Rated Books Count           : %d (%.1f%%)\n", sum(!is.na(reading_log_df$my_rating)), 100 * mean(!is.na(reading_log_df$my_rating))))
    cat(sprintf("• Unrated Books (NA / NULL)   : %d (%.1f%%)\n", sum(is.na(reading_log_df$my_rating)), 100 * mean(is.na(reading_log_df$my_rating))))
    cat(sprintf("• Date Read Coverage (read)   : %d / %d (%.1f%%)\n",
      sum(!is.na(reading_log_df$date_read) & reading_log_df$exclusive_shelf == "read"),
      sum(reading_log_df$exclusive_shelf == "read"),
      100 * mean(!is.na(reading_log_df$date_read[reading_log_df$exclusive_shelf == "read"]))
    ))

    cat("\n• Quarter-Star Rating Distribution:\n")
    rating_dist <- reading_log_df %>%
      dplyr::filter(!is.na(my_rating)) %>%
      dplyr::count(my_rating) %>%
      dplyr::mutate(pct = round(100 * n / sum(n), 1))
    for (r_idx in seq_len(nrow(rating_dist))) {
      cat(sprintf("   - %4.2f ★ : %3d books (%4.1f%%)\n", rating_dist$my_rating[r_idx], rating_dist$n[r_idx], rating_dist$pct[r_idx]))
    }

    cat("\n• Books by Exclusive Shelf:\n")
    shelf_dist <- reading_log_df %>% dplyr::count(exclusive_shelf)
    for (s_idx in seq_len(nrow(shelf_dist))) {
      cat(sprintf("   - %-18s : %d books\n", shelf_dist$exclusive_shelf[s_idx], shelf_dist$n[s_idx]))
    }

    cat("\n• Primary Genre Distribution:\n")
    genre_dist <- goodreads_cleaned %>% dplyr::count(primary_genre, sort = TRUE)
    for (g_idx in seq_len(nrow(genre_dist))) {
      cat(sprintf("   - %-22s : %d books\n", genre_dist$primary_genre[g_idx], genre_dist$n[g_idx]))
    }

    cat("\n✓ All files successfully exported to:", output_dir, "\n")
    cat("   - goodreads_cleaned.csv / .rds\n")
    cat("   - books_cleaned.csv / .rds\n")
    cat("   - authors_cleaned.csv / .rds\n")
    cat("   - genres_cleaned.csv / .rds\n")
    cat("   - book_genres_cleaned.csv / .rds\n")
    cat("   - reading_log_cleaned.csv / .rds\n")
    cat("===================================================================\n\n")
  }

  invisible(list(
    goodreads_cleaned = goodreads_cleaned,
    books             = books_df,
    authors           = authors_df,
    genres            = genres_df,
    book_genres       = book_genres_df,
    reading_log       = reading_log_df
  ))
}

# ------------------------------------------------------------------------------
# 3. Command Line Execution Entry Point
# ------------------------------------------------------------------------------
if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  raw_path <- if (length(args) >= 1) args[1] else Sys.getenv("GOODREADS_RAW_PATH", "data/raw/goodreads_library_export.csv")
  out_path <- if (length(args) >= 2) args[2] else Sys.getenv("GOODREADS_PROCESSED_DIR", "data/processed")
  clean_goodreads_data(raw_file = raw_path, output_dir = out_path)
}

