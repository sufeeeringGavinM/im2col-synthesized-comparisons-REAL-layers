"""Portable sequential tool launch and atomic progress reporting; inherits user license setup."""
from pathlib import Path
import base64,datetime,hashlib,json,os,shutil,subprocess,time
ROOT=Path(__file__).resolve().parents[2]
MAP={'channel_first':'NHWC','centralized':'NCHW_centralized','explicit':'explicit','im2collette_fifo':'im2collette_fifo'}
STATE={}
BATCH=None
SCOPE=None
VIVADO_ROOT=None
UNI=None
WINDOWS_TOOLS=False

def source(variant):return ROOT/SCOPE/MAP[variant]
def fixture(layer):
    folder=ROOT/'tools/workloads'/SCOPE/layer
    manifest=json.loads((ROOT/'tools/workloads/manifest.json').read_text())
    for name in ['input_tensor.txt','kernel_tensor.txt','output_tensor.txt']:
        assert hashlib.sha256((folder/name).read_bytes()).hexdigest()==manifest[SCOPE+'/'+layer+'/'+name],'Fixture changed: '+str(folder/name)
    return folder
def accepted(variant):return json.loads((ROOT/'reports'/SCOPE/MAP[variant]/'cycles/accepted.json').read_text())
def save_state():
    STATE['updated']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    tmp=BATCH/'status.tmp';tmp.write_text(json.dumps(STATE,indent=2)+'\n');tmp.replace(BATCH/'status.json')
def run(command,folder,log,timeout=900):
    with log.open('w') as output:
        process=subprocess.Popen(command,cwd=folder,stdout=output,stderr=subprocess.STDOUT)
        start=time.monotonic()
        while process.poll() is None:
            save_state()
            if time.monotonic()-start>timeout:
                process.kill();process.wait();raise RuntimeError('Timed out: '+str(log))
            time.sleep(5)
    if process.returncode:raise RuntimeError('Command failed: '+str(log)+'\n'+log.read_text(errors='replace')[-2500:])
def windows_path(path):
    path=Path(path).resolve()
    if WINDOWS_TOOLS and os.name!='nt':
        return subprocess.check_output(['wslpath','-w',str(path)],text=True).strip().replace('\\','/')
    return str(path).replace('\\','/')
def execute_tool(tool,arguments,cwd,label,timeout=3600):
    executable=VIVADO_ROOT/'bin'/(tool+('.bat' if WINDOWS_TOOLS else ''))
    if not WINDOWS_TOOLS:
        return run([str(executable),*map(str,arguments)],cwd,cwd/(label+'_console.log'),timeout)
    def quote(value):
        value=str(value)
        if any(c in value for c in ['"','\n','\r','%','!']):raise ValueError('Unsupported character in Windows tool argument')
        return '"'+value+'"'
    script=cwd/(label+'.cmd')
    command='call '+quote(windows_path(executable))+' '+' '.join(quote(v) for v in arguments)
    script.write_text('@echo off\nset "XILINX_VIVADO='+windows_path(VIVADO_ROOT)+'"\n'+command+' > '+quote(label+'_console.log')+' 2>&1\nexit /b %errorlevel%\n')
    if os.name=='nt':
        command=[os.environ.get('COMSPEC','cmd.exe'),'/d','/s','/c',quote(str(script))]
    else:
        encoded=base64.b64encode(quote(windows_path(script)).encode()).decode()
        ps="$c=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+encoded+"')); $p=Start-Process $env:ComSpec -ArgumentList @('/d','/s','/c',('\"'+$c+'\"')) -WorkingDirectory '"+windows_path(cwd).replace("'","''")+"' -PassThru; $h=$p.Handle; $p.WaitForExit(); exit $p.ExitCode"
        command=['powershell.exe','-NoProfile','-EncodedCommand',base64.b64encode(ps.encode('utf-16le')).decode()]
    run(command,cwd,cwd/(label+'_launcher.log'),timeout)
def table_values(path):
    values={}
    for line in path.read_text(errors='replace').splitlines():
        if line.startswith('|'):
            f=[x.strip() for x in line.strip().strip('|').split('|')]
            if len(f)>1:values[f[0].rstrip('*')]=f[1:]
    return values
