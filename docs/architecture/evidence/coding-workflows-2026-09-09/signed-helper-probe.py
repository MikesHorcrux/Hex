import os,json,base64,subprocess,tempfile,time,select,sys,socket,urllib.request
# Pass the signed nested HexGateway executable; all target work uses a temporary directory.
helper=sys.argv[1]
def identity(path):
 s=os.lstat(path)
 return dict(device=s.st_dev,inode=s.st_ino,mode=s.st_mode,size=s.st_size,modifiedSeconds=s.st_mtime_ns//10**9,modifiedNanoseconds=s.st_mtime_ns%10**9,changedSeconds=s.st_ctime_ns//10**9,changedNanoseconds=s.st_ctime_ns%10**9)
class Run:
 def __init__(self,directory,code,tty=False):
  executable='/usr/bin/python3'
  if '\n' in code:code='exec('+repr(code)+')'
  self.p=subprocess.Popen([helper,'--hex-process-supervisor'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={})
  self.buffer=b''; self.events=[]; self.output=b''
  self.send(dict(executable=executable,arguments=['-u','-c',code],directory=directory,environment={'PATH':'/usr/bin:/bin','PYTHONUNBUFFERED':'1'},tty=tty,timeoutSeconds=30,identity=dict(executable=identity(executable),workingDirectory=identity(directory))))
 def send(self,message):
  self.p.stdin.write(json.dumps(message).encode()+b'\n');self.p.stdin.flush()
 def until(self,predicate,timeout=12):
  deadline=time.monotonic()+timeout
  while not predicate():
   assert time.monotonic()<deadline,(self.events,self.output[-1000:])
   ready,_,_=select.select([self.p.stdout],[],[],.1)
   if not ready:continue
   data=os.read(self.p.stdout.fileno(),65536)
   assert data,('unexpected EOF',self.events,self.output[-1000:])
   self.buffer+=data
   while b'\n' in self.buffer:
    line,self.buffer=self.buffer.split(b'\n',1)
    event=json.loads(line);self.events.append(event)
    if event.get('data'):self.output+=base64.b64decode(event['data'])
  return self
 def finish(self):
  self.until(lambda:any(e['kind'] in ('exited','failure') for e in self.events))
  self.p.wait(timeout=4)
  event=[e for e in self.events if e['kind'] in ('exited','failure')][-1]
  assert event['kind']=='exited',event
  return event
 def close(self):
  if self.p.poll() is None:
   self.p.stdin.close();self.p.wait(timeout=6)
with tempfile.TemporaryDirectory(prefix='hex-signed-coding-') as raw:
 directory=os.path.realpath(raw)
 r=Run(directory,"import sys;print('READY');print('GOT:'+sys.stdin.read())")
 try:
  r.until(lambda:b'READY' in r.output)
  r.send(dict(kind='input',operation='input-1',data=base64.b64encode(b'one input\n').decode()))
  r.send(dict(kind='eof',operation='eof-1'))
  event=r.finish();assert b'GOT:one input' in r.output and event.get('code')==0
  assert sum(e.get('operation')=='input-1' and e.get('count')==10 for e in r.events)==1
  print('PASS signed pipe input, EOF, and confirmed exit')
 finally:r.close()
 r=Run(directory,"import os,fcntl,termios,struct;f=os.open('/dev/tty',os.O_RDWR);print('TTY',os.isatty(0),os.tcgetpgrp(f)==os.getpgrp());input();print('SIZE',struct.unpack('HHHH',fcntl.ioctl(f,termios.TIOCGWINSZ,b'\\0'*8))[:2])",True)
 try:
  r.until(lambda:b'TTY True True' in r.output)
  r.send(dict(kind='resize',operation='resize',rows=41,columns=101))
  r.send(dict(kind='input',operation='input',data=base64.b64encode(b'\n').decode()))
  event=r.finish();assert b'SIZE (41, 101)' in r.output and event.get('code')==0
  print('PASS signed PTY controlling terminal, foreground group, input, and resize')
 finally:r.close()
 server="from http.server import HTTPServer,BaseHTTPRequestHandler\nclass H(BaseHTTPRequestHandler):\n def do_GET(self):\n  self.send_response(200);self.end_headers();self.wfile.write(b'hex-preview')\n def log_message(self,*args):pass\ns=HTTPServer(('127.0.0.1',0),H);print('PORT',s.server_port);s.serve_forever()"
 for owner_loss in (False,True):
  r=Run(directory,server)
  try:
   r.until(lambda:b'PORT ' in r.output and b'\n' in r.output)
   port=int(r.output.split(b'PORT ')[1].split()[0]);pid=next(e['code'] for e in r.events if e['kind']=='started')
   for _ in range(2):
    assert urllib.request.urlopen(f'http://127.0.0.1:{port}',timeout=2).read()==b'hex-preview'
   if owner_loss:r.p.stdin.close();r.p.wait(timeout=7)
   else:r.send(dict(kind='stop',operation='stop'));r.finish()
   with socket.socket() as s:assert s.connect_ex(('127.0.0.1',port))!=0
   try:os.kill(pid,0);raise AssertionError('child remained')
   except ProcessLookupError:pass
   print('PASS signed local server repeated access and '+('owner EOF cleanup' if owner_loss else 'explicit stop cleanup'))
  finally:r.close()
 r=Run(directory,"import sys;sys.stdout.buffer.write(b'x'*1000000);sys.stdout.flush();sys.exit(1)")
 try:
  event=r.finish();assert len(r.output)==1000000 and event.get('code')==1
  print('PASS signed 1,000,000-byte output drain and known exit 1')
 finally:r.close()
