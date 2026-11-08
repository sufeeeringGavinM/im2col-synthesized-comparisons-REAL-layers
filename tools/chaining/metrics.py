"""Accepted integer references and unchanged strict measurement parsers."""
from pathlib import Path
import re
PHASES=['planning','input_transfers','kernel_transfers','core_execution','output_transfers','tile_transitions']
def words(p):return [int(w,16) for line in p.read_text().splitlines() for w in line.split('//',1)[0].split()]

def quant(v,enable,shift,nearest):
 if not enable:return v&0xffffffff
 if nearest:
  y=(abs(v)+(1<<(shift-1) if shift else 0))//(1<<shift);y=-y if v<0 else y
 else:y=v//(1<<shift)
 return max(-128,min(127,y))&0xffffffff

def signed(v,bits=32):return v-(1<<bits) if v&(1<<(bits-1)) else v

def metrics(log):
 t=Path(log).read_text();assert 'PASS:' in t and not re.search('FATAL:|ERROR:',t),log
 total=int(re.search(r'Layer cycles[^:]*:\s*(\d+)',t)[1]);m=re.search(r'\[TILED_CYCLES\] '+' '.join(k+r'=(\d+)' for k in PHASES),t);ph=dict(zip(PHASES,map(int,m.groups())));assert sum(ph.values())==total
 return dict(cycles=total,phases=ph)

CHAIN_PHASES=PHASES+['descriptor_gaps']
def get_metrics(log):
 text=Path(log).read_text();assert 'PASS: actual 3-layer' in text and 'FATAL:' not in text
 m=re.search(r'CHAIN_METRICS cycles=(\d+) '+' '.join(p+r'=(\d+)' for p in CHAIN_PHASES),text);assert m
 row=dict(cycles=int(m[1]),phases=dict(zip(CHAIN_PHASES,map(int,m.groups()[1:]))))
 assert sum(row['phases'].values())==row['cycles'],row
 row['layers']=[dict(layer=int(a),outputs=int(b),cycles=int(c)) for a,b,c in re.findall(r'CHAIN_LAYER_PASS layer=(\d+) outputs=(\d+) cycles=(\d+)',text)]
 assert len(row['layers'])==3
 return row
