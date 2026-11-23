# auxiliary-data

- `original-point-forecasts.parquet`: every source `Point` row, unchanged (`value_raw` as in the source file),
  for every converted file. The hub's `median` values are computed from the pmfs instead (see top-level README).
- `file-provenance.csv`: one row per model-output file: source path, git blob and commit, commit date,
  delay after the forecast date, selection rule, record, `duplicate_of`, and flags for rolled-over week
  numbers, corrected years and unmerged pull requests.
- `ilinet/issue-YYYYWW.csv`: ILINet snapshots (Delphi Epidata `fluview`) used to derive truths and resolve ties.
