# Tableau Goodreads Dashboard: AI Agent Task Roadmap

An end-to-end analytics and visualization project designed to ingest raw Goodreads library exports, clean and enrich reading data, and build an interactive, high-impact reading insights and recommendation dashboard in Tableau.

---

## 📌 Project Overview

This project guides an AI-assisted workflow to transform personal Goodreads reading history into a structured dataset and an engaging Tableau dashboard. Through automated data preparation, genre enrichment, custom Tableau metric engineering, and thoughtful UI/UX dashboard design, the project delivers deep insights into reading habits alongside personalized book recommendations.

---

## 🗺️ High-Level AI Agent Roadmap

### Phase 1: Data Preparation & Cleaning
**Objective:** Clean, format, and structure the raw Goodreads CSV export so it's ready for analysis and Tableau ingestion.

**Agent Instructions:**
- **Parse Goodreads Export:** Ingest and parse the raw Goodreads CSV file (`data/raw/goodreads_library_export.csv`).
- **Clean Data Fields:**
  - Standardize date formats (`Date Read`, `Date Added`).
  - Clean numerical ratings (convert `My Rating` to integers 1–5).
  - Handle missing values (e.g., books marked as "to-read" that lack read dates).
  - Strip formula-wrapped identifiers (e.g., `=""...""` on ISBN fields).
- **Extract Key Dimensions:** Extract primary/secondary genres (from tags or enriched data), author names, page counts, and publication years.
- **Output Clean Data:** Output a clean, structured CSV or Excel file ready for Tableau.

---

### Phase 2: Data Enrichment (Genres & Recommendations Prep)
**Objective:** Fill in missing data points (like subgenres) and prepare a dataset for book recommendations.

**Agent Instructions:**
- **Genre Mapping & Categorization:** Map books to broader genre categories (e.g., Sci-Fi, Mystery, Fantasy, Non-Fiction) if raw Goodreads tags are messy or missing.
- **User Preference Analysis:** Calculate key preference metrics:
  - Average ratings per genre.
  - Total books read per genre.
  - Most-read authors.
- **Recommendation Feature Framework:** Outline criteria (e.g., *"Recommend books matching top 3 genres with an average rating > 4.0 from unread authors or new releases"*) that can be joined as a secondary data source.

---

### Phase 3: Tableau Calculated Fields & Metrics
**Objective:** Define the custom calculations needed in Tableau to drive the specific visualizations.

**Agent Instructions:**
- **Reading Challenge Progress:** Write calculated fields to measure current books read this calendar year vs. user-defined annual goal:
  $$\text{Reading Challenge Progress} = \frac{\text{COUNT}(\text{Books Read in 2026})}{\text{Goal}}$$
- **Top-Rated Filter:** Develop calculation logic to isolate 5-star or highest-rated books with high review counts.
- **Author Affinity Score:** Define a weighted score combining books read per author and average rating given.

---

### Phase 4: Dashboard Layout & Visualization Design
**Objective:** Design and layout the visual components of the Tableau dashboard.

**Agent Instructions:**
- **Reading Challenge Gauge / Progress Bar:** Design a visual progress metric (bullet chart or progress bar) showing books read vs. goal for the current year.
- **Top-Rated Books Showcase:** Create a filtered view or highlight table of top-rated books (sorted by rating, then review/page count).
- **Genre Breakdown (Most Read vs. Highest Rated):** Build a dual-axis or side-by-side bar chart showing volume of books read per genre alongside average rating per genre.
- **Favorite Authors Grid:** Create a packed bubble chart or horizontal bar chart of top authors by frequency and satisfaction.
- **Dashboard Assembly & Aesthetics:**
  - Recommend a cohesive color palette (e.g., warm bookish tones like forest green, cream, and terracotta).
  - Wireframe the visual layout hierarchy for intuitive exploration.

---

### Phase 5: Recommendation Panel Integration
**Objective:** Add a dynamic or static recommendation block to the dashboard.

**Agent Instructions:**
- **Format Secondary Recommendation Data:** Format a secondary data table containing recommended titles based on the user's top genres and highest-rated authors.
- **Tableau Integration:** Integrate this table into the Tableau dashboard as a clean, styled list or pop-up tooltip view (*"Books You Might Love Next"*).

---

## 📁 Repository Structure

```text
Good_Reads_Recs/
├── README.md
├── .gitignore
├── data/
│   ├── raw/                  # Original, immutable Goodreads CSV export
│   │   └── goodreads_library_export.csv
│   ├── processed/            # Cleaned, structured CSV/Excel ready for Tableau
│   └── recommendations/      # Enriched recommendation secondary data source
├── src/                      # Data processing & enrichment scripts
│   ├── clean_data.py         # Phase 1: Parsing and cleaning
│   └── enrich_recommend.py   # Phase 2 & 5: Enrichment and rec generation
└── tableau/                  # Tableau workbooks (.twbx / .twb), calculations, and design assets
```

---

## 🛠 Tech Stack

- **Data Processing & Preparation:** Python (`pandas`, `numpy`)
- **Visualization & BI:** Tableau Desktop / Tableau Public
- **Data Storage & Exchange:** Cleaned CSV, Excel (`.xlsx`), or SQLite
- **Enrichment APIs (Optional):** Open Library API, Google Books API
