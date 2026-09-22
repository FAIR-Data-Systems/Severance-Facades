# Severance-internal query templates for the Beacon facade

These two files are **not part of the facade app** — per Severance's security
model, query text only ever lives inside Severance Internal. Copy both files
into your Severance Internal deployment's `./queries` folder (see
`Severance/internal/README.md`); Internal re-reads that folder on every poll
cycle and will register them with External automatically.

## Shared filter contract

Both templates take the same 7 optional, unbound-safe bindings (see
`../handoff-beacon-caresm.md` decision #3). A filter that is *absent* from
the `bindings` object in the Severance job submission is simply never
substituted, so its `?_name_type` placeholder stays an unbound SPARQL
variable and every `FILTER(!BOUND(...) || EXISTS { ... })` guard for that
filter evaluates true — i.e. omitted filters impose no constraint.

| Binding key                  | Type      | Example value                                  |
|-------------------------------|-----------|-------------------------------------------------|
| `sex`                         | iri       | `http://purl.obolibrary.org/obo/NCIT_C16576`    |
| `disease`                     | iri       | `http://www.orpha.net/ORDO/Orphanet_93552`      |
| `symptom`                     | iri       | `http://purl.obolibrary.org/obo/HP_0001638`     |
| `gene_variant`                | string    | `NC_000023.9:g.32317682G>A`                     |
| `birthyear_min`/`_max`         | integer   | `1980` / `2010`                                 |
| `age_symptom_onset_min`/`_max` | integer   | `0` / `18`                                      |
| `age_diagnosis_min`/`_max`     | integer   | `0` / `100`                                     |

`birthyear`, `age_symptom_onset`, and `age_diagnosis` are **range** filters:
each takes independent `_min`/`_max` bindings (either or both may be
supplied; an exact match is just `_min == _max`). See
`../lib/filter_mapper.rb` for how a Beacon `>=`/`<=`/`=` filter is
turned into these.

## The VP is not GA4GH Beacon v2-compliant — built for it as the real, only caller

The originally planned design (below) assumed a spec-faithful Beacon v2
client. Reading ERDERA's actual `RDVP-Portal-backend` /
`BeaconIndividualsQueryHandler.java` showed it deviates in ways that matter
for these templates specifically:

- **`sex` and `disease` can arrive as multiple values** (an OR-filter value
  array for sex; an ontology filter with multiple ids for disease).
  Severance's binding substitution is scalar — a placeholder can only be
  replaced with one value, not fanned out into a `FILTER(?x IN (...))` list
  — so `FilterMapper` takes the *first* value and reports the rest as an
  `unsupportedFilters` warning. Extending this would mean changing
  Severance's substitution model, not just these templates.
- **Age-like filters are always sent as a `>=`/`<=` range**, never an exact
  value, hence the `_min`/`_max` binding pairs above.
- **The VP's "age this year" filter is tagged with Birthyear's own NCIT
  code** (`obo:NCIT_C83164`) but its value is an actual age in years, not a
  birth year. `FilterMapper` inverts it into a birth-year range before it
  ever reaches these templates — see the comment there.

## Assumptions baked into these templates — validate before production

These were written from the CARE-SM-2 model diagrams
(`diagrams/CARE-SM-obo-*.md`) and the structural pattern used in
`implementation/SPARQL/complete_query.sparql` / `diagnostic.sparql`, **not**
against a live triplestore (per the handoff's own open TODO — the filter
list "may have changed since CARE-SM-2 was designed"). Specifically:

1. **Person/role identity spans record graphs.** Each record is its own
   named graph (`GRAPH ?record { ... }`), and the model diagrams don't show
   explicitly whether `?person sio:SIO_000228 ?role` is re-asserted inside
   every record's graph or lives once outside all of them. These templates
   assume it recurs per-graph (matching `complete_query.sparql`'s pattern).
   If a real deployment stores that triple once globally instead, the
   per-filter `GRAPH ?xxxrecord { ?role sio:SIO_000356 ?xxxprocess ... }`
   blocks below will need their `?role` binding moved outside the `GRAPH`.
2. **Disease/symptom "positive" match.** A diagnosis/phenotype only counts
   as a match when its `Output_` value is the string `"true"` (confirmed),
   per the model's `DiagnosisPresent`/`PhenotypePresent` boolean data value.
   Compared via `STR(?value) = "true"` to tolerate either `xsd:boolean` or
   plain string literals — confirm which the real data uses.
3. **`age_diagnosis`** is mapped to the *record-level* age (`sio:SIO_000687`
   on the record itself, as seen in `complete_query.sparql`) for the record
   containing a Diagnosis output — not a value on the Diagnosis process
   itself (the Diagnosis diagram only models start/end *dates*, not an age
   integer). This is still the most interpretive of the 7 mappings — the
   record-level age is our best structural candidate for "age at
   diagnosis," but note that ERDERA's own filter id for this
   (`obo:NCIT_C156420`) doesn't correspond to anything in any CARE-SM-2
   model diagram, so there's no independent confirmation this is the
   right property. Revisit against real data.
