#!/usr/bin/env python3
"""Stage 09 - data visualization for the customer-retention analysis.

Creates portfolio-quality Matplotlib charts from the read-only SQLite database
built in earlier stages. Chart inputs are taken from the project's own SQL
statements (sql/04, sql/05, sql/06) so the figures use exactly the documented
metric definitions, and every chart input is reconciled against the
corresponding SQL result and the verified audit totals before it is drawn.

Outputs (reports/figures/):
  01_customer_value_concentration.png
  02_rfm_score_distributions.png
  03_cohort_retention_heatmap.png
  04_monthly_customer_activity.png

The database is opened read-only (mode=ro); no data, SQL, raw files, or the
database are modified. No CustomerID is ever selected, plotted, or printed.

Run:  python scripts/create_visualizations.py
"""
from pathlib import Path
import sqlite3
import sys

import matplotlib

matplotlib.use("Agg")  # headless, deterministic rendering
import matplotlib.pyplot as plt
import numpy as np

REPO = Path(__file__).resolve().parents[1]
DB_PATH = REPO / "data" / "processed" / "customer_retention.sqlite3"
SQL_DIR = REPO / "sql"
FIG_DIR = REPO / "reports" / "figures"

# Verified audit totals (see reports/data_quality_and_methodology.md).
EXP_ELIGIBLE_LINES = 397_884
EXP_ELIGIBLE_CUSTOMERS = 4_338
EXP_TOTAL_GPV = 8_911_407.90
EXP_COHORTS = 13

# Consistent portfolio palette.
C_PRIMARY = "#1F4E79"   # deep blue
C_SECOND = "#2E75B6"    # medium blue
C_LIGHT = "#9DC3E6"     # light blue
C_ACCENT = "#C00000"    # highlight red
C_GREY = "#7F7F7F"
C_MASK = "#D9D9D9"      # unobservable cells in the heatmap

FOOTER = (
    "Source: UCI Online Retail (Chen, D., 2015; CC BY 4.0). "
    "GPV = Gross Purchase Value (gross, not net of returns). "
    "Eligible population: 4,338 customers / 397,884 lines."
)

# Full per-customer GPV concentration curve (aggregate only; no CustomerID).
CONCENTRATION_CURVE_SQL = """
SELECT m FROM (
  SELECT ROUND(SUM(gross_purchase_value), 2) AS m
  FROM prepared_transactions
  WHERE is_eligible_purchase_line = 1
  GROUP BY CustomerID
)
ORDER BY m DESC
"""

CHECKS = []


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def connect() -> sqlite3.Connection:
    """Open the analysis database strictly read-only."""
    return sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)


def fetch(conn, sql):
    """Return (column_names, rows) for a single SELECT statement."""
    cur = conn.execute(sql)
    return [d[0] for d in cur.description], cur.fetchall()


def load_statements(sql_path: Path):
    """Split a project SQL file into statements (same rule as the README runner).

    Lines whose first non-space characters are '--' are dropped, then the
    remainder is split on ';'. Comment lines must not end with ';'.
    """
    body = "\n".join(
        line for line in sql_path.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("--")
    )
    return [stmt.strip() for stmt in body.split(";") if stmt.strip()]


def find_statement(statements, *needles):
    """Return the first statement containing all needle substrings."""
    for stmt in statements:
        if all(needle in stmt for needle in needles):
            return stmt
    raise KeyError(f"no statement containing {needles!r}")


def check(name, ok, detail=""):
    CHECKS.append((name, bool(ok), detail))


def configure_style():
    plt.rcParams.update({
        "figure.dpi": 150,
        "savefig.dpi": 150,
        "savefig.bbox": "standard",
        "font.size": 10,
        "axes.titlesize": 13,
        "axes.titleweight": "bold",
        "axes.titlepad": 10,
        "axes.labelsize": 10.5,
        "axes.grid": True,
        "axes.axisbelow": True,
        "grid.alpha": 0.30,
        "grid.linewidth": 0.6,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "figure.facecolor": "white",
        "axes.facecolor": "white",
        "legend.frameon": False,
        "legend.fontsize": 9,
    })


def add_footer(fig, note=None):
    """Add an optional wrapped note plus the standard source footer."""
    if note:
        fig.text(0.01, 0.088, note, ha="left", va="bottom", fontsize=7.4,
                 color=C_GREY, linespacing=1.6)
    fig.text(0.01, 0.018, FOOTER, ha="left", va="bottom", fontsize=6.8,
             color=C_GREY)


# ---------------------------------------------------------------------------
# Figure 1 - Customer value concentration
# ---------------------------------------------------------------------------
def figure_concentration(conn, f4_vertical, out_path: Path):
    _, rows = fetch(conn, CONCENTRATION_CURVE_SQL)
    vals = np.array([r[0] for r in rows], dtype=float)
    n = vals.size
    total = vals.sum()
    cum_pct = np.cumsum(vals) / total * 100.0
    x_pct = np.arange(1, n + 1) / n * 100.0

    segments = {seg: (int(k), float(pct)) for seg, k, _gpv, pct in f4_vertical}

    fig, ax = plt.subplots(figsize=(9.4, 6.8))
    x_curve = np.concatenate([[0.0], x_pct])
    y_curve = np.concatenate([[0.0], cum_pct])
    ax.fill_between(x_curve, 0, y_curve, step="post", color=C_LIGHT,
                    alpha=0.35, zorder=1)
    ax.plot(x_curve, y_curve, drawstyle="steps-post", color=C_PRIMARY,
            lw=2.2, zorder=2, label="Observed GPV concentration")
    ax.plot([0, 100], [0, 100], ls="--", lw=1.1, color=C_GREY, zorder=2,
            label="Line of equality (uniform spend)")

    markers = [
        ("top_10_customers", "Top 10 customers", C_ACCENT, "D", (0, 14)),
        ("top_1pct", "Top 1% of customers", C_ACCENT, "o", (8, 10)),
        ("top_5pct", "Top 5%", C_SECOND, "o", (8, -16)),
        ("top_10pct", "Top 10%", C_SECOND, "o", (10, 6)),
    ]
    for seg, label, color, marker, offset in markers:
        k, pct = segments[seg]
        x = k / n * 100.0
        ax.scatter([x], [pct], s=58, marker=marker, color=color,
                   edgecolor="white", linewidth=0.8, zorder=4)
        ax.annotate(f"{label}\n{k} of {n:,} \u2192 {pct:.1f}% of GPV",
                    xy=(x, pct), xytext=offset, textcoords="offset points",
                    fontsize=8.6, color=color, fontweight="bold",
                    ha="left" if offset[0] >= 0 else "right", va="center")

    ax.set_xlim(0, 100)
    ax.set_ylim(0, 100)
    ax.set_xticks([0, 20, 40, 60, 80, 100])
    ax.set_yticks([0, 20, 40, 60, 80, 100])
    ax.set_xlabel("Customers, ranked by Gross Purchase Value (cumulative %)")
    ax.set_ylabel("Cumulative Gross Purchase Value (%)")
    ax.set_title("Customer Value Concentration\n"
                 "Cumulative gross purchase value by customer rank")
    ax.legend(loc="lower right")

    k1, p1 = segments["top_1pct"]
    k10, p10 = segments["top_10pct"]
    ax.text(0.36, 0.20,
            f"Top 1% of customers ({k1} of {n:,}) account for {p1:.1f}% of GPV.\n"
            f"Top 10% ({k10} of {n:,}) account for {p10:.1f}% of GPV.",
            transform=ax.transAxes, fontsize=9, ha="left", va="center",
            bbox=dict(boxstyle="round,pad=0.5", facecolor="#F2F2F2",
                      edgecolor=C_GREY, linewidth=0.6))

    add_footer(fig)
    fig.subplots_adjust(bottom=0.155)
    fig.savefig(out_path)
    plt.close(fig)

    return {"n": n, "total": total, "cum_pct": cum_pct, "segments": segments}


# ---------------------------------------------------------------------------
# Figure 2 - RFM score distributions
# ---------------------------------------------------------------------------
def figure_rfm(r_counts, f_counts, m_counts, total_customers, out_path: Path):
    panels = [
        ("Recency (R) score", r_counts, 5,
         "5 = most recent (\u2264 13 days)   \u2192   1 = least recent (> 180 days)"),
        ("Frequency (F) score", f_counts, 4,
         "1 = one-time   \u2192   4 = most frequent (6+ invoices)"),
        ("Monetary (M) score", m_counts, 5,
         "1 = lowest GPV   \u2192   5 = highest GPV (> \u00a32,059.45)"),
    ]
    fig, axes = plt.subplots(1, 3, figsize=(14.2, 5.4))
    for ax, (title, counts, n_scores, note) in zip(axes, panels):
        scores = list(range(1, n_scores + 1))
        values = [counts[s] for s in scores]
        colors = plt.cm.Blues(np.linspace(0.35, 0.9, n_scores))
        bars = ax.bar([str(s) for s in scores], values, color=colors,
                      edgecolor="white", linewidth=0.8, width=0.72)
        for bar, value in zip(bars, values):
            ax.text(bar.get_x() + bar.get_width() / 2, value,
                    f"{value:,}\n{value / total_customers * 100:.1f}%",
                    ha="center", va="bottom", fontsize=8.4)
        ax.set_ylim(0, max(values) * 1.22)
        ax.set_title(title)
        ax.set_xlabel("Score band")
        ax.set_ylabel("Customers (count)")
        ax.text(0.0, -0.20, note, transform=ax.transAxes, fontsize=8,
                color=C_GREY, ha="left", va="top")
    fig.suptitle(
        f"RFM Score Distributions \u2014 {total_customers:,} eligible customers",
        fontsize=14, fontweight="bold", x=0.01, ha="left")
    fig.text(0.01, 0.905,
             "Percentage labels are of the 4,338 eligible customers. "
             "Bands are mutually exclusive and exhaustive.",
             fontsize=8.5, color=C_GREY, ha="left")
    add_footer(fig, "R/F/M score bands are defined in "
                    "reports/data_quality_and_methodology.md.")
    fig.subplots_adjust(top=0.80, bottom=0.205, wspace=0.28)
    fig.savefig(out_path)
    plt.close(fig)


# ---------------------------------------------------------------------------
# Figure 3 - Cohort retention heatmap
# ---------------------------------------------------------------------------
def figure_cohort(matrix_rows, out_path: Path):
    cohorts = sorted({r[0] for r in matrix_rows})
    ages = list(range(max(r[2] for r in matrix_rows) + 1))
    sizes = {r[0]: int(r[1]) for r in matrix_rows}

    data = np.full((len(cohorts), len(ages)), np.nan)
    cidx = {cm: i for i, cm in enumerate(cohorts)}
    for cm, _size, age, _active, rate in matrix_rows:
        data[cidx[cm], age] = rate * 100.0

    masked = np.ma.masked_invalid(data)
    cmap = plt.cm.Blues.copy()
    cmap.set_bad(C_MASK)

    fig, ax = plt.subplots(figsize=(11.2, 7.0))
    im = ax.imshow(masked, aspect="auto", cmap=cmap, vmin=0, vmax=100,
                   origin="upper")

    ax.set_xticks(range(len(ages)))
    ax.set_xticklabels([str(a) for a in ages])
    ax.set_yticks(range(len(cohorts)))
    ax.set_yticklabels([f"{cm}  (n={sizes[cm]:,})" for cm in cohorts])
    ax.set_xlabel("Cohort age (calendar months since first observed purchase)")
    ax.set_ylabel("Cohort (month of first observed eligible purchase)")
    ax.set_title("Cohort Retention \u2014 Observed Monthly Activity Rate\n"
                 "Share of each cohort active at a given age")
    ax.grid(False)

    for i in range(len(cohorts)):
        for j in range(len(ages)):
            value = data[i, j]
            if np.isnan(value):
                continue
            ax.text(j, i, f"{value:.0f}", ha="center", va="center",
                    fontsize=7.4,
                    color=("white" if value > 62 else "#1A1A1A"))

    cbar = fig.colorbar(im, ax=ax, fraction=0.038, pad=0.02)
    cbar.set_label("Observed activity rate (% of cohort active that month)",
                   fontsize=9)

    note = (
        "Grey cells are unobservable (cohort age beyond the last observed month, "
        "2011-12) and are masked \u2014 never zero; observable cells with no activity "
        "are a genuine 0.\n"
        "Cohort = month of first OBSERVED purchase (left-truncated; 2010-12 is a "
        "partial start, 2011-12 ends 2011-12-09).\n"
        "These are observed repeat-activity rates, not censoring-adjusted retention; "
        "cohort observation windows are unequal."
    )
    add_footer(fig, note)
    fig.subplots_adjust(bottom=0.255, left=0.145)
    fig.savefig(out_path)
    plt.close(fig)
    return {"cohorts": cohorts, "ages": ages, "data": data}


# ---------------------------------------------------------------------------
# Figure 4 - Monthly customer activity
# ---------------------------------------------------------------------------
def figure_monthly_activity(monthly_rows, out_path: Path):
    months = [r[0] for r in monthly_rows]
    new = np.array([r[3] for r in monthly_rows], dtype=float)
    repeat = np.array([r[4] for r in monthly_rows], dtype=float)
    total = np.array([r[5] for r in monthly_rows], dtype=float)
    status = [r[6] for r in monthly_rows]

    x = np.arange(len(months))
    fig, ax = plt.subplots(figsize=(12.6, 6.4))
    bars_new = ax.bar(x, new, color=C_LIGHT, edgecolor="white", linewidth=0.8,
                      width=0.72, label="New (first observed month)")
    bars_rep = ax.bar(x, repeat, bottom=new, color=C_PRIMARY,
                      edgecolor="white", linewidth=0.8, width=0.72,
                      label="Repeat-active (first observed in an earlier month)")

    for i, s in enumerate(status):
        if s != "full":
            for bar in (bars_new[i], bars_rep[i]):
                bar.set_hatch("///")
                bar.set_edgecolor("white")

    for i, value in enumerate(total):
        ax.text(x[i], value, f"{int(value):,}", ha="center", va="bottom",
                fontsize=8.2, color="#333333")

    ax.set_xticks(x)
    ax.set_xticklabels(months, rotation=45, ha="right")
    ax.set_ylim(0, total.max() * 1.30)
    ax.set_xlabel("Month")
    ax.set_ylabel("Active customers (distinct)")
    ax.set_title("Monthly Customer Activity \u2014 New vs Repeat Active Customers")
    ax.legend(loc="upper left")
    ax.text(0.985, 0.985,
            "Hatched bars = incomplete months\n"
            "2010-12: partial start\n"
            "2011-12: truncated (data stop 2011-12-09)",
            transform=ax.transAxes, ha="right", va="top", fontsize=8,
            color=C_ACCENT, linespacing=1.55,
            bbox=dict(boxstyle="round,pad=0.5", facecolor="#FBF3F3",
                      edgecolor=C_ACCENT, linewidth=0.7))
    add_footer(fig, "Partial and truncated months are not directly comparable to "
                    "full months. A single year is observed, so no seasonal trend "
                    "is claimed.")
    fig.subplots_adjust(bottom=0.295)
    fig.savefig(out_path)
    plt.close(fig)
    return {"months": months, "new": new, "repeat": repeat, "total": total,
            "status": status}


# ---------------------------------------------------------------------------
# Output verification
# ---------------------------------------------------------------------------
def verify_figure(path: Path):
    if not path.is_file():
        return False, "missing"
    size = path.stat().st_size
    if size <= 0:
        return False, "zero bytes"
    arr = plt.imread(path)
    if arr.size == 0:
        return False, "unreadable image"
    if arr.std() <= 0.01:
        return False, "blank image (no pixel variance)"
    return True, f"{size:,} bytes, {arr.shape[1]}x{arr.shape[0]} px"


def main() -> None:
    if not DB_PATH.is_file():
        raise SystemExit(f"ERROR: database not found: {DB_PATH}")
    FIG_DIR.mkdir(parents=True, exist_ok=True)

    configure_style()

    s04 = load_statements(SQL_DIR / "04_rfm_scoring.sql")
    s05 = load_statements(SQL_DIR / "05_cohort_retention.sql")
    s06 = load_statements(SQL_DIR / "06_business_findings.sql")

    conn = connect()
    try:
        # --- gather chart inputs from the project's own SQL ---
        _, f1_row = fetch(conn, find_statement(s06, "AS eligible_line_gpv"))
        f1 = dict(zip(
            ["eligible_lines", "eligible_customers", "eligible_line_gpv",
             "customer_level_gpv", "gpv_difference"], f1_row[0]))

        _, f4_wide_row = fetch(conn, find_statement(s06, "AS top10customers_pct_gpv"))
        f4_wide = dict(zip(
            ["eligible_customers", "gpv_total", "k1", "gpv1", "pct1",
             "k5", "gpv5", "pct5", "k10", "gpv10", "pct10",
             "top10cust_gpv", "top10cust_pct"], f4_wide_row[0]))
        f4_vertical = fetch(conn, find_statement(s06, "'top_1pct' AS segment"))[1]

        _, d0_row = fetch(conn, find_statement(s04, "n_r_missing"))
        d0 = dict(zip(
            ["n_customers", "n_r_missing", "n_f_missing", "n_m_missing",
             "r_valid", "f_valid", "m_valid", "mon_pos", "mon_recon"], d0_row[0]))

        rfm_band_rows = fetch(conn, find_statement(s04, "'r1' AS band"))[1]
        r_counts = {int(b[1:]): c for b, c in rfm_band_rows if b.startswith("r")}
        f_counts = {int(b[1:]): c for b, c in rfm_band_rows if b.startswith("f")}
        m_counts = {int(b[1:]): c for b, c in rfm_band_rows if b.startswith("m")}

        _, f2_row = fetch(conn, find_statement(s06, "AS one_time_customers"))
        f2 = dict(zip(
            ["eligible_customers", "one_time_customers", "pct_one_time",
             "repeat_customers", "pct_repeat"], f2_row[0]))

        cohort_integrity = dict(fetch(
            conn, find_statement(s05, "exactly_one_cohort_per_customer"))[1])
        cohort_validation = dict(fetch(
            conn, find_statement(s05, "zero_filled_unobservable_cells"))[1])
        matrix_rows = fetch(conn, find_statement(s05, "AS retention_rate"))[1]

        monthly_s05 = fetch(conn, find_statement(s05, "AS repeat_active_customers"))[1]
        monthly_f7 = fetch(conn, find_statement(s06, "AS month_status"))[1]
    finally:
        conn.close()

    # --- reconciliation checks ---
    check("F1 eligible lines == 397,884",
          f1["eligible_lines"] == EXP_ELIGIBLE_LINES, str(f1["eligible_lines"]))
    check("F1 eligible customers == 4,338",
          f1["eligible_customers"] == EXP_ELIGIBLE_CUSTOMERS,
          str(f1["eligible_customers"]))
    check("F1 line-level GPV == \u00a38,911,407.90",
          abs(f1["eligible_line_gpv"] - EXP_TOTAL_GPV) < 0.01,
          f"{f1['eligible_line_gpv']}")
    check("F1 customer vs line GPV difference == 0",
          f1["gpv_difference"] == 0, str(f1["gpv_difference"]))
    check("F4 concentration denominators agree with line GPV",
          abs(f4_wide["gpv_total"] - f1["eligible_line_gpv"]) < 0.01,
          f"{f4_wide['gpv_total']} vs {f1['eligible_line_gpv']}")

    # 04 D0 / D1 (RFM scoring integrity)
    check("04 D0 customers == 4,338",
          d0["n_customers"] == EXP_ELIGIBLE_CUSTOMERS, str(d0["n_customers"]))
    check("04 D0 no missing R/F/M scores",
          d0["n_r_missing"] == d0["n_f_missing"] == d0["n_m_missing"] == 0,
          f"{d0['n_r_missing']}/{d0['n_f_missing']}/{d0['n_m_missing']}")
    check("04 D0 all in-range & Monetary > 0",
          d0["r_valid"] == d0["f_valid"] == d0["m_valid"] == d0["mon_pos"]
          == EXP_ELIGIBLE_CUSTOMERS and d0["mon_recon"] == 0,
          f"recon={d0['mon_recon']}")
    check("04 D1 R/F/M band sums == 4,338",
          sum(r_counts.values()) == sum(f_counts.values()) == sum(m_counts.values())
          == EXP_ELIGIBLE_CUSTOMERS,
          f"R={sum(r_counts.values())} F={sum(f_counts.values())} "
          f"M={sum(m_counts.values())}")
    check("RFM F=1 count matches F2 one-time customers",
          f_counts[1] == f2["one_time_customers"],
          f"{f_counts[1]} vs {f2['one_time_customers']}")

    # 05 cohort integrity
    check("05 cohorts sum to eligible customers",
          cohort_integrity["exactly_one_cohort_per_customer"] == 1
          and cohort_validation["cohorts_sum_equals_eligible"] == 1,
          f"sum={cohort_integrity['cohorts_sum']}")
    check("05 unobservable cells are masked, not zero-filled",
          cohort_validation["zero_filled_unobservable_cells"] == 0,
          str(cohort_validation["zero_filled_unobservable_cells"]))
    check("05 age-0 activity is 100% for every cohort",
          cohort_validation["cohorts_with_age0_not_100pct"] == 0,
          str(cohort_validation["cohorts_with_age0_not_100pct"]))
    check("05 observable cells match the matrix",
          cohort_validation["observable_cells_in_matrix"] == len(matrix_rows),
          f"{len(matrix_rows)} vs "
          f"{cohort_validation['observable_cells_in_matrix']}")
    check("05 cohort-month count == 13",
          len({r[0] for r in matrix_rows}) == EXP_COHORTS,
          str(len({r[0] for r in matrix_rows})))

    # monthly activity
    check("monthly new customers sum to 4,338",
          sum(r[3] for r in monthly_f7) == EXP_ELIGIBLE_CUSTOMERS,
          str(sum(r[3] for r in monthly_f7)))
    check("monthly new+repeat == total active each month",
          all(r[3] + r[4] == r[5] for r in monthly_f7), "")
    check("monthly F7 agrees with sql/05 statement 5",
          [(r[0], r[3], r[4], r[5]) for r in monthly_f7]
          == [(r[0], r[1], r[2], r[3]) for r in monthly_s05], "")
    check("partial start and truncated end flagged",
          monthly_f7[0][6] == "partial_start"
          and monthly_f7[-1][6] == "truncated_end",
          f"{monthly_f7[0][6]} / {monthly_f7[-1][6]}")

    # cross-check the concentration curve against the F4 markers
    cconn = connect()
    try:
        _, rows = fetch(cconn, CONCENTRATION_CURVE_SQL)
    finally:
        cconn.close()
    vals = np.array([r[0] for r in rows], dtype=float)
    cum = np.cumsum(vals) / vals.sum() * 100.0
    seg = {s: (k, p) for s, k, _g, p in f4_vertical}
    check("concentration curve matches F4 top-1% share",
          round(cum[seg["top_1pct"][0] - 1], 2) == round(seg["top_1pct"][1], 2),
          f"{round(cum[seg['top_1pct'][0] - 1], 2)} vs {seg['top_1pct'][1]}")
    check("concentration curve matches F4 top-10% share",
          round(cum[seg["top_10pct"][0] - 1], 2) == round(seg["top_10pct"][1], 2),
          f"{round(cum[seg['top_10pct'][0] - 1], 2)} vs {seg['top_10pct'][1]}")

    # --- draw figures ---
    fig1 = FIG_DIR / "01_customer_value_concentration.png"
    conn = connect()
    try:
        curve_info = figure_concentration(conn, f4_vertical, fig1)
    finally:
        conn.close()

    fig2 = FIG_DIR / "02_rfm_score_distributions.png"
    figure_rfm(r_counts, f_counts, m_counts, f1["eligible_customers"], fig2)

    fig3 = FIG_DIR / "03_cohort_retention_heatmap.png"
    heat = figure_cohort(matrix_rows, fig3)

    fig4 = FIG_DIR / "04_monthly_customer_activity.png"
    figure_monthly_activity(monthly_f7, fig4)

    # masked-cell reconciliation used by the heatmap
    check("heatmap masks exactly the unobservable cells",
          int(np.isnan(heat["data"]).sum())
          == cohort_validation["unobservable_cells_omitted_as_na"],
          f"{int(np.isnan(heat['data']).sum())} vs "
          f"{cohort_validation['unobservable_cells_omitted_as_na']}")

    # --- verify outputs ---
    outputs = [fig1, fig2, fig3, fig4]
    for path in outputs:
        ok, detail = verify_figure(path)
        check(f"output {path.name}", ok, detail)

    # --- report ---
    print("Stage 09 - data visualization")
    print(f"Database (read-only): {DB_PATH}")
    print(f"Figures written to:   {FIG_DIR}")
    print()
    failures = 0
    for name, ok, detail in CHECKS:
        status = "PASS" if ok else "FAIL"
        if not ok:
            failures += 1
        suffix = f"  [{detail}]" if detail else ""
        print(f"[{status}] {name}{suffix}")
    print()
    print(f"Reconciliation & validation checks: {len(CHECKS) - failures}/{len(CHECKS)} passed")
    for path in outputs:
        print(f"  - {path.name}")
    print()
    if failures:
        raise SystemExit(f"ERROR: {failures} check(s) failed")
    print("DONE")


if __name__ == "__main__":
    sys.exit(main())
