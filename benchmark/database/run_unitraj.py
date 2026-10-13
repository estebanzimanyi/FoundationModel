"""Run UniTraj (Zhu et al., NeurIPS 2025; github.com/Yasoz/UniTraj, model.pt as released) zero-shot on
the sequences of the view ModelInput and append its reconstructions to ReconstructedLonLat as the
model MODEL_NAME ('unitraj' by default).

The model is loaded by #load_unitraj_model and the inputs are built as #predict_and_save_unitraj
builds them, both of models/checkpoints/utils.py of this repository, the adapter of the frozen
benchmark of Section 6 of the paper:
  * coordinates are (lon, lat) offsets from the origin of the sequence, normalized by the robust
    statistics of the dataset (median, and half the 16-84 percentile range, of the offsets);
  * the interval channel is the elapsed time from the first position in seconds, clipped to 15 s;
  * sequences longer than 200 are skipped (none here), shorter ones are zero-padded;
  * sequences are batched by number of masked positions, as UniTraj requires.
predict_and_save_unitraj reads the frozen benchmark files, so its loop is restated here over
ModelInput, with one difference, the one run_model.py makes for the proposed model: the coordinates
of masked positions are withheld by ModelInput, so the origin is the first VISIBLE position and the
robust statistics are computed over visible offsets only; masked positions carry a zero
placeholder, which UniTraj drops before its encoder (its tokenizer has kernel 1, so no masked value
reaches a visible token). UniTraj shuffles its visible tokens with numpy's generator, seeded (SEED).

    UNITRAJ=<checkout of Yasoz/UniTraj> NORM=robust|std|worldtrace MODEL_NAME=... python run_unitraj.py
"""
import os
import sys
from itertools import groupby
from pathlib import Path

import numpy as np
import psycopg
import torch
from psycopg.rows import namedtuple_row

THESIS = Path(__file__).resolve().parents[2]
UNITRAJ = Path(os.environ['UNITRAJ'])
SEED = int(os.environ.get('SEED', '0'))
MODEL = os.environ.get('MODEL_NAME', 'unitraj')
# The scope of #_unitraj_stats: 'robust' (the default of #predict_and_save_unitraj), the median and
# half the 16-84 percentile range of the offsets of the dataset; 'std', their mean and standard
# deviation; 'worldtrace', the fixed statistics UniTraj was pretrained with.
NORM = os.environ.get('NORM', 'robust')
CLAMP_DT = 15.0
sys.path[:0] = [str(THESIS / 'models'), str(THESIS / 'benchmark'),
                str(THESIS / 'models' / 'checkpoints')]
import utils  # noqa: E402  (models/checkpoints/utils.py of the thesis)

np.random.seed(SEED)
torch.manual_seed(SEED)
DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')

model = utils.load_unitraj_model(UNITRAJ, device=DEVICE)
MAX_LEN = int(model.encoder.num_tokens)
print(f'UniTraj, {sum(p.numel() for p in model.parameters()):,} parameters, max length {MAX_LEN}, '
      f'on {DEVICE}, seed {SEED}')

with psycopg.connect() as conn:
    rows = conn.cursor(row_factory=namedtuple_row).execute(
        'SELECT Task, GapId, PointIdx, Ts, Masked, Lon, Lat FROM ModelInput '
        'ORDER BY Task, GapId, PointIdx').fetchall()
    seqs = [(key, list(g)) for key, g in groupby(rows, lambda r: (r.task, r.gapid))]
    seqs = [(key, s) for key, s in seqs if any(not r.masked for r in s)]

    recs = []
    for (task, gap), s in seqs:
        t = len(s)
        if t > MAX_LEN:
            continue
        masked = np.array([r.masked for r in s])
        m = np.flatnonzero(masked)
        if len(m) == 0 or len(m) >= t:
            continue
        vis = np.flatnonzero(~masked)
        lonlat = np.array([[np.nan, np.nan] if r.masked else [r.lon, r.lat] for r in s], np.float64)
        origin = lonlat[vis[0]].copy()
        ts = np.array([float(r.ts) for r in s])
        recs.append({'task': task, 'gap': gap, 'idx': [r.pointidx for r in s], 'off': lonlat - origin,
                     'origin': origin, 'dt': ts - ts[0], 'masked': m, 'vis': vis, 'tlen': t})

    results = []
    for task in sorted({r['task'] for r in recs}):
        trecs = [r for r in recs if r['task'] == task]
        # #_unitraj_stats over the visible positions of each sequence, whose first is the origin
        mean, std = utils._unitraj_stats(
            [{'dataset': 'dma', 'lonlat': r['off'][r['vis']] + r['origin']} for r in trecs],
            NORM)['dma']
        print(f'{task}: {len(trecs)} sequences, robust mean {mean}, std {std}')
        buckets = {}
        for i, r in enumerate(trecs):
            buckets.setdefault(len(r['masked']), []).append(i)
        for K, idxs in sorted(buckets.items()):
            for b0 in range(0, len(idxs), 256):
                chunk = idxs[b0:b0 + 256]
                B = len(chunk)
                traj = np.zeros((B, 2, MAX_LEN), np.float32)
                interv = np.zeros((B, MAX_LEN), np.float32)
                mask_idx = np.zeros((B, K), np.int64)
                for bi, ri in enumerate(chunk):
                    r = trecs[ri]; t = r['tlen']
                    z = (r['off'] - mean) / std
                    z[r['masked']] = 0.0
                    traj[bi, :, :t] = z.T.astype(np.float32)
                    interv[bi, :t] = np.clip(r['dt'], 0.0, CLAMP_DT).astype(np.float32)
                    mask_idx[bi] = r['masked']
                with torch.no_grad():
                    pred, _ = model(torch.from_numpy(traj).to(DEVICE),
                                    torch.from_numpy(interv).to(DEVICE),
                                    torch.from_numpy(mask_idx).to(DEVICE))
                pred = pred.cpu().numpy()
                for bi, ri in enumerate(chunk):
                    r = trecs[ri]; t = r['tlen']
                    pw = pred[bi].T[:t] * std + mean + r['origin']
                    for i in r['masked']:
                        results.append((MODEL, task, r['gap'], r['idx'][i],
                                        float(pw[i, 0]), float(pw[i, 1])))

    conn.execute('CREATE TABLE IF NOT EXISTS ReconstructedLonLat(Model text, Task text, '
                 'GapId bigint, PointIdx bigint, Lon float8, Lat float8)')
    conn.execute('DELETE FROM ReconstructedLonLat WHERE Model = %s', (MODEL,))
    with conn.cursor().copy('COPY ReconstructedLonLat FROM STDIN') as copy:
        for row in results:
            copy.write_row(row)
    print(f'{len(results)} reconstructed positions written as {MODEL}')
