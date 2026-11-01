# Literature-review records

Coded records of the PRISMA-guided review. `analysis/review-counts.py`
recomputes every review count reported in the manuscript from these files
and checks it against the printed value (`make review-counts`, also part
of `make reproduce`).

| File | Contents |
|---|---|
| `search-log.csv` | Every query as run: stream, database, exact string, date, filters, raw hits |
| `screening-record.csv` | All 58 full-text candidates of the primary search: original decision and code, decision and code under the written criterion, reason, and the full-text passage for every changed decision or code |
| `healthcare-screening.csv` | Full-text candidates of the healthcare stream with decision, code and reason |
| `second-coder.csv` | The second author's blind decisions on the 12-paper sample (seed 20261029) |
| `matrix1-taxonomy.csv` to `matrix4-sovereignty.csv` | Matrices 1 to 4 for the 24 included studies (supplementary Tables S1 to S4) |
| `corpus-tags.csv` | Per-study tags from which the taxonomy and failure-handling counts are computed |
| `review-workbook.xlsx` | The working review workbook: search log, screening, re-screening, extraction record, second coder, and the AI-use log |

## Screening rule

A paper is screened in two steps and included only if it passes both;
included papers carry no code.

1. **Topic.** It concerns container, cloud or edge orchestration or a
   cloud service platform, and its mechanism or analysis addresses a
   failure condition named in the search string: node or host failure,
   network partition or failure, degraded connectivity, resource
   exhaustion or pressure, or failure detection, fault tolerance,
   recovery or resilience. Fault injection is not required. A paper that
   fails this step is excluded as **SCOPE** (off-topic).
2. **Evidence**, for papers that pass step 1:
   - **E1**: no hardware or simulation-based evaluation;
   - **E2**: the evaluation rests on unrealistic infrastructure
     assumptions, such as unconstrained bandwidth, zero latency, or a
     single node on which node failure or partition cannot occur;
   - **E3**: the results cannot be checked: single values with no
     variance or repetitions, or values for the same measurement that
     contradict each other.

A paper receives at most one code.
