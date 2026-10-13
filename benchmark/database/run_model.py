"""Run the pretrained model on the sequences of the view ModelInput and write its
reconstructions into ReconstructedLonLat(Model, Task, GapId, PointIdx, Lon, Lat).

The model is the class TrajectoryMaskedAutoEncoder of the thesis (models/model.py), loaded from the
checkpoint the thesis publishes (models/checkpoints/best.pt) as load_model of
models/checkpoints/utils.py loads it, but strictly, so that every weight of the model comes from the
checkpoint. The checkpoint is the mixture-of-experts model with the semantic cross-attention of
commit 8fc3ca2 of the thesis repository, the commit that adds it; the model code of later commits
fuses the semantics at the input, with weights the checkpoint does not hold, so THESIS is a
checkout of commit 8fc3ca2. Each sequence is turned into the channels of the model as
the data pipeline of the thesis does (normalize_trajectory of models/resampling.py and
_kinematics_raw of models/data.py), padded by _pad of models/data.py to the maximum length of 256,
with one difference: the origin and the scale of the spatial offsets are computed from the
visible positions only, since the coordinates of the masked ones are withheld.
  spatial     offsets in latitude and longitude from the first visible position, divided by the
              largest absolute offset;
  temporal    day of the week / 6 and hour / 23 in local time, minute / 59, and the elapsed time
              log1p(t - t0) / log1p(max(t - t0)) from the first position of the sequence;
  kinematic   speed / 30 clipped to [0, 1], course / 180 - 1, rate of turn / 720 clipped to
              [-1, 1], a missing value counting as 0;
  semantic    the 256-dimensional embedding of the description.
The domain is maritime (1). Two models are run: 'crossdomain' uses every channel, and
'coordinates' runs the same weights with the kinematic and the semantic channels replaced by the
learned tokens [KIN_UNK] and [NO_SEM], so that it reconstructs from positions and times only.
When PointEmbedding is empty, since embed.py has not been run, only 'coordinates' is run.

    THESIS=<checkout of MobilityDB/FoundationModel at 8fc3ca2> python run_model.py
"""
import math
import os
import sys
from itertools import groupby
from pathlib import Path

import numpy as np
import psycopg
import torch
from psycopg.rows import namedtuple_row

THESIS = Path(os.environ['THESIS'])
sys.path.insert(0, str(THESIS / 'models'))
from config import ModelConfig  # noqa: E402
from data import _pad  # noqa: E402
from model import TrajectoryMaskedAutoEncoder  # noqa: E402

MAX_LEN = 256
DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')

ckpt = torch.load(THESIS / 'models' / 'checkpoints' / 'best.pt', map_location=DEVICE,
                  weights_only=False)
cfg = ckpt['cfg'] if not isinstance(ckpt['cfg'], dict) else ModelConfig(**ckpt['cfg'])
model = TrajectoryMaskedAutoEncoder(cfg).to(DEVICE)
model.load_state_dict(ckpt['model'], strict=True)
model.eval()
print(f'Model of epoch {ckpt.get("epoch")}, {sum(p.numel() for p in model.parameters()):,} '
      f'parameters, on {DEVICE}')


def channels(seq):
    """The padded channels of one sequence and the origin and scale of its offsets"""
    masked = np.array([r.masked for r in seq])
    vis = np.flatnonzero(~masked)
    lat = np.array([np.nan if r.masked else r.lat for r in seq], dtype=np.float64)
    lon = np.array([np.nan if r.masked else r.lon for r in seq], dtype=np.float64)
    lat0, lon0 = lat[vis[0]], lon[vis[0]]
    d_lat, d_lon = lat - lat0, lon - lon0
    bbox_half = max(np.nanmax(np.abs(d_lat)), np.nanmax(np.abs(d_lon)), 1e-8)
    coords = np.nan_to_num(np.stack([d_lat, d_lon], axis=1) / bbox_half).astype(np.float32)
    ts = np.array([float(r.ts) for r in seq])
    dt = ts - ts[0]
    log_max = math.log1p(dt.max()) if dt.max() > 0 else 1.0
    tau = np.stack([np.array([r.dow for r in seq]) / 6.0, np.array([r.hour for r in seq]) / 23.0,
                    np.array([r.minute for r in seq]) / 59.0, np.log1p(dt) / log_max],
                   axis=1).astype(np.float32)
    sog = np.array([r.sog if r.sog is not None else 0.0 for r in seq], dtype=np.float32)
    cog = np.array([r.cog if r.cog is not None else 0.0 for r in seq], dtype=np.float32)
    rot = np.array([r.rot if r.rot is not None else 0.0 for r in seq], dtype=np.float32)
    kin = np.stack([np.clip(sog / 30.0, 0, 1), np.clip(cog / 180.0 - 1.0, -1, 1),
                    np.clip(rot / 720.0, -1, 1)], axis=1).astype(np.float32)
    sem = np.stack([np.asarray(r.emb, dtype=np.float32) if r.emb is not None
                    else np.zeros(cfg.sem_dim, np.float32) for r in seq])
    coords_p, pad_mask = _pad(coords, MAX_LEN)
    tensors = dict(x_spatial=coords_p, coords=coords_p, tau=_pad(tau, MAX_LEN)[0],
                   kinematics=_pad(kin, MAX_LEN)[0], pad_mask=pad_mask,
                   pos_mask=_pad(masked[:, None], MAX_LEN)[0][:, 0], e_sem=_pad(sem, MAX_LEN)[0])
    return tensors, (lat0, lon0, bbox_half)


with psycopg.connect() as conn:
    rows = conn.cursor(row_factory=namedtuple_row).execute(
        'SELECT * FROM ModelInput ORDER BY Task, GapId, PointIdx').fetchall()
    seqs = [(key, list(g)) for key, g in groupby(rows, lambda r: (r.task, r.gapid))]
    seqs = [(key, s) for key, s in seqs if any(not r.masked for r in s)]
    print(f'{len(seqs)} sequences')
    results = []
    embedded = conn.execute('SELECT EXISTS (SELECT 1 FROM PointEmbedding)').fetchone()[0]
    models = [('crossdomain', False)] if embedded else []
    models.append(('coordinates', True))
    for name, group_masked in models:
        for b in range(0, len(seqs), 256):
            batch = seqs[b:b + 256]
            inputs, params = zip(*(channels(s) for _, s in batch))
            t = {k: torch.as_tensor(np.stack([x[k] for x in inputs])).to(DEVICE)
                 for k in inputs[0]}
            with torch.no_grad():
                out = model(**t, domain_ids=torch.ones(len(batch), dtype=torch.long,
                                                      device=DEVICE),
                            kin_group_masked=group_masked, sem_group_masked=group_masked)
            pred = out['pred'][..., :2].cpu().numpy()
            for ((task, gap), seq), (lat0, lon0, bbox_half), y in zip(batch, params, pred):
                for i, r in enumerate(seq):
                    if r.masked:
                        results.append((name, task, gap, r.pointidx,
                                        lon0 + float(y[i, 1]) * bbox_half,
                                        lat0 + float(y[i, 0]) * bbox_half))
    conn.execute('DROP TABLE IF EXISTS ReconstructedLonLat CASCADE')
    conn.execute('CREATE TABLE ReconstructedLonLat(Model text, Task text, GapId bigint, '
                 'PointIdx bigint, Lon float8, Lat float8)')
    with conn.cursor().copy('COPY ReconstructedLonLat FROM STDIN') as copy:
        for row in results:
            copy.write_row(row)
    print(f'{len(results)} reconstructed positions')
