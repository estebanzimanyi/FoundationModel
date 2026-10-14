"""Figures 11 and 12 of Section 7 of the paper, from RESULTS/section7.json of analyze.py, written as
PDF files to RESULTS/figures/ (RESULTS defaults to results/ beside this file):
  errors_paired.pdf          Fig. 11a, the window-paired differences between 'crossdomain' and
                             'kinematic' and between 'crossdomain' and 'coordinates', by task and
                             class of mean speed, with the share of windows in which 'crossdomain'
                             is better (drawn only when 'crossdomain' was run);
  errors_paired_unitraj.pdf  Fig. 11b, the same differences between each UniTraj variant and
                             'kinematic', 'crossdomain' and 'coordinates', on a scale linear within
                             100 m and logarithmic beyond;
  errors_isolation.pdf       Fig. 12a, the median recovery error of the moving vessels against the
                             number of minutes to the nearest visible position;
  errors_horizon.pdf         Fig. 12b, the median prediction error against the minutes after the
                             last visible position;
  errors_curves_legend.pdf   the legend shared by the two panels of Fig. 12.
The repository holds no other figure code: save, paired_axis and curve restate #save, the paired
panels and #curve of figs.py, the script that drew the first version of these figures, with the
same PGF backend (pdflatex must be installed), Latin Modern at 8 pt, and widths in fractions of the
text width of the paper, which includes them at their natural size.

    python figures.py
"""
import json
import os
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402

RESULTS = Path(os.environ.get('RESULTS', Path(__file__).with_name('results')))
OUT = RESULTS / 'figures'
OUT.mkdir(parents=True, exist_ok=True)
res = json.loads((RESULTS / 'section7.json').read_text())

plt.rcParams.update({'pgf.texsystem': 'pdflatex', 'pgf.rcfonts': False, 'font.family': 'serif',
                     'font.size': 8, 'legend.fontsize': 8,
                     'pgf.preamble': r'\usepackage[T1]{fontenc}\usepackage{lmodern}',
                     'axes.linewidth': 0.6, 'xtick.major.width': 0.6, 'ytick.major.width': 0.6,
                     'xtick.major.size': 2.5, 'ytick.major.size': 2.5})
TW = 332.89723 / 72.27      # the text width of the paper, in inches
INK, MUTED, GRAY, BLUE, ORANGE = '#222222', '#555555', '#9a9a9a', '#1f77b4', '#e8820c'
STYLE = {'kinematic': dict(color=INK, marker='s', ls='-'),
         'coordinates': dict(color=BLUE, marker='o', ls='--'),
         'crossdomain': dict(color=ORANGE, marker='o', ls='-'),
         'unitraj': dict(color='#d62728', marker='^', ls=':'),
         'unitraj-sd': dict(color='#9467bd', marker='v', ls=':'),
         'unitraj-wt': dict(color='#2ca02c', marker='D', ls=':')}
UNITRAJ = ('unitraj', 'unitraj-sd', 'unitraj-wt')
CLASSES = ('below 0.5 kn', '0.5 to 3 kn', '3 kn or more', 'all windows')
ROWS = [(task, c) for task in ('recovery', 'prediction') for c in CLASSES]
YS = [k + (0.6 if task == 'prediction' else 0) for k, (task, _) in enumerate(ROWS)]


def save(fig, name):
    """A tight box, which the paper includes at its natural size, so the 8 pt text is not scaled"""
    fig.savefig(OUT / f'{name}.pdf', backend='pgf', bbox_inches='tight', pad_inches=0.06)
    plt.close(fig)


def tex(m):
    return r'\textsf{' + m + '}'


def paired_axis(ax, rows, xlabel):
    """One panel of differences; rows lists (vertical offset, model, its comparisons by row)"""
    for off, m, cmp in rows:
        for y, (task, c) in zip(YS, ROWS):
            p = cmp[f'{task} / {c}']
            dot = STYLE[m]['color'] if m in UNITRAJ else \
                ORANGE if c == 'all windows' else INK
            ax.plot([p['lo'], p['hi']], [y + off] * 2, color=dot, lw=0.9)
            ax.scatter([p['mean']], [y + off], s=10 if m in UNITRAJ else 12, color=dot, zorder=3,
                       marker=STYLE[m]['marker'] if m in UNITRAJ else 'o', linewidths=0)
            ax.text(1.03, y + off, f'{100 * p["better"]:.0f}\\%', transform=ax.get_yaxis_transform(),
                    va='center', color=dot if m in UNITRAJ else MUTED,
                    fontsize=6 if m in UNITRAJ else 8)
    ax.text(1.03, -0.85, 'better', transform=ax.get_yaxis_transform(), va='center', color=MUTED)
    ax.axvline(0, color=GRAY, lw=0.6, ls='--')
    ax.set_yticks(YS)
    ax.tick_params(axis='y', length=0)
    ax.set_ylim(max(YS) + 0.6, -1.2)
    ax.set_xlabel(xlabel)
    for sp in ('top', 'right', 'left'):
        ax.spines[sp].set_visible(False)


def comparisons(a, b):
    """The comparisons of analyze.py of a minus b, keyed by 'task / class'"""
    return {k.split(' / ', 1)[1]: v for k, v in res['paired'].items()
            if k.split(' / ', 1)[0] == f'{a} - {b}'}


labels = [f'{task.capitalize()}, {c}' for task, c in ROWS]

# Fig. 11a: crossdomain against kinematic and coordinates
if 'crossdomain' in res['models']:
    fig = plt.figure(figsize=(TW, 2.45))
    axes = (fig.add_axes([0.335, 0.21, 0.24, 0.74]), fig.add_axes([0.745, 0.21, 0.185, 0.74]))
    for ax, b in zip(axes, ('kinematic', 'coordinates')):
        paired_axis(ax, [(0, 'crossdomain', comparisons('crossdomain', b))],
                    f'{tex("crossdomain")} $-$\n{tex(b)} (m)')
    axes[0].set_yticklabels(labels)
    axes[1].set_yticklabels([])
    save(fig, 'errors_paired')

# Fig. 11b: the three UniTraj variants against kinematic, crossdomain and coordinates
VERSUS = [b for b in ('kinematic', 'crossdomain', 'coordinates') if b in res['models']]
fig = plt.figure(figsize=(TW, 3.3))
axes = [fig.add_axes([0.29 + k * 0.255, 0.17, 0.14, 0.70]) for k in range(len(VERSUS))]
for ax, b in zip(axes, VERSUS):
    paired_axis(ax, [(off, u, comparisons(u, b)) for off, u in zip((-0.27, 0, 0.27), UNITRAJ)],
                f'UniTraj $-$\n{tex(b)} (m)')
    ax.set_xscale('symlog', linthresh=100, linscale=1)
    ax.set_xticks([-100, 0, 1000])
    ax.set_xticklabels(['$-10^2$', '', '$10^3$'])  # zero is the dashed line
    ax.set_xticks([100], minor=True)
axes[0].set_yticklabels(labels)
for ax in axes[1:]:
    ax.set_yticklabels([])
fig.legend(handles=[Line2D([], [], ls='', ms=3.5, color=STYLE[u]['color'], marker=STYLE[u]['marker'],
                           label=tex(u)) for u in UNITRAJ],
           loc='upper center', bbox_to_anchor=(0.62, 0.995), ncol=3, frameon=False, handletextpad=0.2,
           columnspacing=1.2)
save(fig, 'errors_paired_unitraj')

# Fig. 12: median error of the moving vessels against the isolation and the horizon
MODELS = [m for m in ('kinematic', 'coordinates', 'crossdomain') + UNITRAJ if m in res['models']]


def curve(key, xmax, name, xlabel):
    """One panel of Fig. 12: the median error of every model against the steps of key"""
    fig = plt.figure(figsize=(0.44 * TW, 2.1))
    ax = fig.add_axes([0.2, 0.2, 0.76, 0.76])
    for m in MODELS:
        xs = [x for x in range(1, xmax + 1) if str(x) in res[key][m]]
        ax.plot(xs, [res[key][m][str(x)] for x in xs], lw=1, ms=3, label=m, **STYLE[m])
    ax.set_yscale('log')
    ax.set_xticks(range(1, xmax + 1))
    ax.set_xlabel(xlabel)
    ax.set_ylabel('median error (m)')
    for s in ('top', 'right'):
        ax.spines[s].set_visible(False)
    ax.grid(color='#e8e8e8', lw=0.4, which='major')
    save(fig, name)


curve('isolation', 8, 'errors_isolation', 'minutes to the nearest\nvisible position')
curve('horizon', 3, 'errors_horizon', 'minutes after the last\nvisible position')
fig = plt.figure(figsize=(TW, 0.3))
fig.legend(handles=[Line2D([], [], lw=1, ms=3, label=tex(m), **STYLE[m]) for m in MODELS],
           loc='center', ncol=len(MODELS), frameon=False, handlelength=2.2, columnspacing=1.0)
save(fig, 'errors_curves_legend')
print('written', ', '.join(sorted(p.name for p in OUT.glob('*.pdf'))))
