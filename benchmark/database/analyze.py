"""The results of Section 7 of the paper from the view Errors of 05_evaluate.sql: Table db-errors
(mean, median and 90th percentile of the error of every reconstruction and task), the
window-paired differences of Fig. errors-paired and Table db-unitraj by class of the mean speed of
the vessel in the window (WinSpeed of winspeed.sql), with their 95% bootstrap intervals over 2,000
resamples of windows and the share of windows in which the first reconstruction has the smaller
error, the median error of the moving vessels against the isolation of a masked position
(recovery) and against the horizon (prediction), and the median ratio of the distance travelled
from the last visible position by a prediction to that travelled by the vessel. Prints them and
writes them to RESULTS/section7.json (RESULTS defaults to results/ beside this file).

    python analyze.py
"""
import json
import os
from pathlib import Path

import numpy as np
import pandas as pd
import psycopg

RESULTS = Path(os.environ.get('RESULTS', Path(__file__).with_name('results')))
RESULTS.mkdir(parents=True, exist_ok=True)
rng = np.random.default_rng(1508)
CLASSES = ['below 0.5 kn', '0.5 to 3 kn', '3 kn or more']

with psycopg.connect() as conn:
    err = pd.read_sql('SELECT Model, Task, GapId, PointIdx, Err FROM Errors', conn)
    speed = pd.read_sql('SELECT GapId, coalesce(Kn, 0) AS Speed FROM WinSpeed', conn)
    vis = pd.read_sql('SELECT Task, GapId, PointIdx FROM ModelInput WHERE NOT Masked', conn)
    # the distance from the last visible position travelled by each prediction and by the vessel
    travel = pd.read_sql("""
      WITH LastVis AS (
        SELECT GapId, max(PointIdx) AS L FROM ModelInput
        WHERE Task = 'prediction' AND NOT Masked GROUP BY GapId )
      SELECT r.Model, r.GapId, ST_Distance(r.Geom, lp.Geom) AS DPred,
        ST_Distance(tp.Geom, lp.Geom) AS DTrue
      FROM Reconstructed r JOIN EvalMasks m USING (Task, GapId, PointIdx)
        JOIN LastVis l USING (GapId)
        JOIN TripPoints lp ON lp.GapId = r.GapId AND lp.PointIdx = l.L
        JOIN TripPoints tp ON tp.GapId = r.GapId AND tp.PointIdx = r.PointIdx
      WHERE r.Task = 'prediction'""", conn)
for df in (err, speed, vis, travel):
    df.columns = [c.lower() for c in df.columns]
res = {'models': sorted(err.model.unique())}

# 1. Table db-errors
tab = err.groupby(['task', 'model']).err.agg(
    positions='size', mean='mean', median='median', p90=lambda x: x.quantile(0.9))
res['errors'] = {f'{t}/{m}': {k: float(v) for k, v in r.items()} for (t, m), r in tab.iterrows()}
print('Table db-errors: errors in meters')
print(tab.round(1).to_string(), '\n')

# 2. classes of the mean speed in the window
speed['cls'] = pd.cut(speed.speed, [-np.inf, 0.5, 3.0, np.inf], right=False, labels=CLASSES)
res['windows_by_class'] = {str(k): int(v) for k, v in speed.cls.value_counts().items()}
print('Windows by mean speed:', res['windows_by_class'], '\n')
pw = err.groupby(['model', 'task', 'gapid']).err.mean().unstack('model').reset_index()
pw = pw.merge(speed[['gapid', 'cls']], on='gapid', how='left')


def boot_mean_ci(d):
    """Mean of d and its 95% percentile-bootstrap interval over 2,000 resamples of windows.
    The repository has no bootstrap routine: benchmark/metrics.py holds the point summaries of
    #aggregate only, beside which this one is written."""
    d = np.asarray(d)
    idx = rng.integers(0, len(d), size=(2000, len(d)))
    m = d[idx].mean(1)
    return float(d.mean()), float(np.percentile(m, 2.5)), float(np.percentile(m, 97.5))


# 3. window-paired differences: Fig. errors-paired (crossdomain) and Table db-unitraj (UniTraj)
PAIRS = [('crossdomain', 'kinematic'), ('crossdomain', 'coordinates'), ('coordinates', 'kinematic')]
PAIRS += [(u, r) for u in ('unitraj', 'unitraj-sd', 'unitraj-wt') for r in ('kinematic', 'coordinates')]
res['paired'] = {}
print('Window-paired differences in meters, first minus second: mean [95% CI], share of windows '
      'in which the first is better')
for a, b in PAIRS:
    if a not in pw or b not in pw:
        continue
    for task in ['recovery', 'prediction']:
        sub = pw[pw.task == task].dropna(subset=[a, b])
        for name, g in [('all windows', sub)] + [(c, sub[sub.cls == c]) for c in CLASSES]:
            diff = g[a] - g[b]
            mean, lo, hi = boot_mean_ci(diff)
            better = float((g[a] < g[b]).mean())
            key = f'{a} - {b} / {task} / {name}'
            res['paired'][key] = dict(n=int(len(g)), mean=mean, lo=lo, hi=hi, better=better,
                                      median=float(diff.median()))
            print(f'{key:58s} n={len(g):5d} {mean:8.1f} [{lo:8.1f}, {hi:8.1f}] {100 * better:4.0f}%')
print()

# 4. moving vessels: median error against the isolation (recovery) and the horizon (prediction)
moving = set(speed.gapid[speed.cls == CLASSES[2]])
for task, key in [('recovery', 'isolation'), ('prediction', 'horizon')]:
    e = err[(err.task == task) & err.gapid.isin(moving)]
    vg = vis[vis.task == task].groupby('gapid').pointidx.apply(np.array).to_dict()
    pos = e[['gapid', 'pointidx']].drop_duplicates()
    if task == 'recovery':
        pos['steps'] = [int(np.abs(vg[g] - p).min()) for g, p in zip(pos.gapid, pos.pointidx)]
    else:
        pos['steps'] = [int(p - vg[g][vg[g] < p].max()) for g, p in zip(pos.gapid, pos.pointidx)]
    e = e.merge(pos, on=['gapid', 'pointidx'])
    med = e.groupby(['model', 'steps']).err.median().unstack('steps')
    print(f'Moving vessels, median {task} error in meters against the {key} in steps')
    print(med.round(0).to_string(), '\n')
    res[key] = {m: {int(s): float(x) for s, x in r.items() if not np.isnan(x)}
                for m, r in med.iterrows()}

# 5. moving vessels: median ratio of the distance travelled by a prediction to the true one
t = travel[travel.gapid.isin(moving) & (travel.dtrue > 0)]
ratio = (t.dpred / t.dtrue).groupby(t.model).median()
res['travel_ratio'] = {m: float(x) for m, x in ratio.items()}
print('Moving vessels, median ratio of the distance travelled in prediction to the true one')
print(ratio.round(2).to_string())

(RESULTS / 'section7.json').write_text(json.dumps(res, indent=1))
print('\nwritten', RESULTS / 'section7.json')
