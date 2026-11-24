# auxiliary-data

- `original-point-forecasts.parquet`: every source `Point` row, unchanged (`value_raw` as in the source file),
  for every converted file. The hub's `median` values are computed from the pmfs instead (see top-level README).
- `file-provenance.csv`: one row per model-output file: source repository, path, git blob and commit,
  commit date, delay after the forecast date, selection rule, record, `is_real_time` (first committed no
  more than 3 days after the FluSight due date), `duplicate_of`, and flags for rolled-over week numbers,
  corrected years and unmerged pull requests.
- `superseded-forecasts.parquet`: training forecasts for rounds where the hub keeps the model's real-time
  forecast instead and the two differ (2 files: CU-EAKFC_SIRS and ReichLab-KCDE, 2018/19). Rows as in the
  source, in the hub's standardised columns.
- `ilinet/issue-YYYYWW.csv`: ILINet snapshots (Delphi Epidata `fluview`) used to derive truths and resolve ties.
