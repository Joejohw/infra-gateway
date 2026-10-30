"""Backend sintético: não autentica, não armazena dados, não chama serviços."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def respond(self):
        size = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(size).decode('utf-8')
        payload = json.dumps({
            'method': self.command,
            'uri': self.path,
            'body': body,
            'xff': self.headers.get('X-Forwarded-For'),
            'real_ip': self.headers.get('X-Real-IP'),
            'forwarded': self.headers.get('Forwarded'),
        }).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(payload)

    do_GET = do_HEAD = do_OPTIONS = do_POST = do_PUT = do_PATCH = do_DELETE = respond

    def log_message(self, *_):
        pass  # Nem a fixture registra URLs/corpos/headers.


ThreadingHTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
