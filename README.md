# Goodreads Library Analytics & Book Recommendation System

A personal data science project designed to ingest, clean, enrich, and analyze Goodreads library data, store it in a structured SQL database, create insightful reading visualizations, and generate personalized book recommendations based on historical rating patterns.

---

## 📌 Project Overview

This project transforms personal reading history exported from Goodreads into an enriched data warehouse and analytical engine. By combining data engineering (ETL pipeline, SQL modeling) and data science (EDA, statistical analysis, recommendation systems), the project uncovers personal reading trends and provides tailored recommendations for future reading.

### Key Objectives

1. **Ingest & Preserve Raw Data**
   - Store unmodified Goodreads CSV exports in `data/raw/` for reproducibility and auditability.
2. **Clean & Standardize (Pipeline Specifics TBD)**
   - Parse and clean Goodreads-specific data artifacts (e.g., formula-wrapped ISBN strings `=""...""`, multi-value bookshelf tags, inconsistent date formats, and missing publication years).
3. **Data Enrichment (TBD)**
   - Supplement book metadata (genres, synopsis, cover images, subject tags, author details) using external sources such as the Open Library API, Google Books API, or web scraping.
4. **Relational SQL Database Storage (Schema TBD)**
   - Design and populate a structured relational database (e.g., SQLite or PostgreSQL) with normalized entities (such as `books`, `authors`, `shelves`, `reading_log`, and `ratings`).
5. **Interactive Visualizations & Analytics**
   - Visualize reading habits: ratings distributions, most-read authors, page count trends, reading velocity across months/years, and genre breakdowns.
6. **Personalized Book Recommendation Engine**
   - Build a recommendation model using content-based filtering, collaborative filtering, or hybrid approaches based on historical ratings and reading preferences.

---

## 📁 Repository Structure

```text
goodreads-data-project/
├── README.md
├── .gitignore
├── data/
│   ├── raw/                  # Original, immutable Goodreads CSV exports
│   │   └── goodreads_library_export.csv
│   ├── processed/            # Cleaned, standardized data files (TBD)
│   └── external/             # Supplementary data fetched from APIs (TBD)
├── notebooks/                # Jupyter notebooks for EDA and prototyping (TBD)
├── src/                      # Source code modules (TBD)
│   ├── data/                 # Ingestion, cleaning, and enrichment scripts
│   ├── database/             # Database connection, schemas, and migrations
│   ├── visualization/        # Plotting and dashboard utilities
│   └── models/               # Recommendation algorithms
└── sql/                      # DDL scripts, queries, and schema definitions (TBD)
```

---

## 📊 Raw Data Source

The baseline dataset consists of an export from Goodreads:
- **Location:** `data/raw/goodreads_library_export.csv`
- **Current attributes tracked:**
  - `Book Id`, `Title`, `Author`, `Author l-f`, `Additional Authors`
  - `ISBN`, `ISBN13`
  - `My Rating`, `Average Rating`
  - `Publisher`, `Binding`, `Number of Pages`
  - `Year Published`, `Original Publication Year`
  - `Date Read`, `Date Added`
  - `Bookshelves`, `Bookshelves with positions`, `Exclusive Shelf`
  - `My Review`, `Spoiler`, `Private Notes`, `Read Count`, `Owned Copies`

---

## 🛠 Planned Tech Stack

- **Language:** Python 3.10+
- **Data Manipulation:** `pandas`, `numpy`
- **Database:** SQLite / PostgreSQL, `SQLAlchemy`
- **Visualization:** `matplotlib`, `seaborn`, `plotly` (or interactive dashboard via `Streamlit`)
- **Machine Learning / Recommendations:** `scikit-learn` (TF-IDF, Cosine Similarity, Matrix Factorization)
- **External APIs (Potential):** Open Library Books API, Google Books API

---

## 🚀 Next Steps

1. **Design SQL Schema:** Define relational tables, primary/foreign keys, and data types for storing books, authors, and reading logs.
2. **Define Cleaning Rules:** Specify transformations for ratings, dates, shelf categories, and ISBN values.
3. **Select Enrichment Strategy:** Determine external APIs and attributes to expand book metadata.
4. **Develop EDA & Visualizations:** Identify key reading metrics and generate exploratory charts.
5. **Implement Recommendation Engine:** Model rating history to suggest next reads.
