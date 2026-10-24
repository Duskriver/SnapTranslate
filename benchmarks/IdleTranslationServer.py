import http.server,json,base64,hashlib,struct,sys
from pathlib import Path
class H(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  req=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  img=base64.b64decode(req['messages'][1]['content'][1]['image_url']['url'].split(',',1)[1],validate=True)
  assert img.startswith(b'\x89PNG\r\n\x1a\n')
  record={'bytes':len(img),'sha256':hashlib.sha256(img).hexdigest(),'dimensions':struct.unpack('>II',img[16:24])}
  with (Path(sys.argv[1])/'upload-records.jsonl').open('a') as f:f.write(json.dumps(record)+'\n')
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  for text in ['内存测试。\n','敏捷的棕色狐狸跳过懒狗。\n','每次翻译后关闭窗口。\n','这是公开测试内容。']:
   event={'choices':[{'index':0,'delta':{'content':text}}]}
   self.wfile.write(('data: '+json.dumps(event,ensure_ascii=False)+'\n\n').encode());self.wfile.flush()
  self.wfile.write(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');self.wfile.flush()
 def log_message(self,*a):pass
server=http.server.HTTPServer(('127.0.0.1',0),H)
(Path(sys.argv[1])/'port').write_text(str(server.server_port))
server.serve_forever()
