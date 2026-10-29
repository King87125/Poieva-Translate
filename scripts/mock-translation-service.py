#!/usr/bin/env python3
"""Loopback-only development fixture. Fixed samples, no real model or request logs."""
import json
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.path == '/http-redirect':
            self.send_response(302)
            self.send_header('Location', '/translation/language/translate')
            self.end_headers()
            return
        if self.path not in ['/v1/chat/completions', '/deepl/v2/translate', '/baidu', '/youdao', '/translation/language/translate']:
            self.send_error(404)
            return
        try:
            length = int(self.headers.get('Content-Length', 0))
            if not 0 < length <= 1048576:
                self.send_error(413)
                return
            data = self.rfile.read(length)
            words = {'Hello.': '你好。', 'Hello': '你好', '你好': 'Hello',
                     '谢谢': 'Thank you', '请帮我测试翻译。': 'Please help me test the translation.',
                     '你好，译入 12': 'Hello, Yiru 12'}
            if self.path == '/v1/chat/completions':
                body = json.loads(data)
                payload = json.loads(body['messages'][1]['content'])
                if body.get('model') in ['local-test-assistant', 'local-test-guided']:
                    reference = payload.get('reference', {})
                    if (reference.get('before') != 'Welcome to TypeBridge.'
                            or reference.get('after') != 'Next sentence.'
                            or reference.get('preferences') != 'Short sentences.'
                            or reference.get('terminology') != [{'source': '译入', 'translation': 'TypeBridge'}]):
                        self.send_error(400)
                        return
                    values = []
                    for s in payload['segments']:
                        source = s.get('source', s.get('text'))
                        if source != '你好，译入 12' or ('draft' in s and s['draft'] != 'Hello, Yiru 12'):
                            self.send_error(400)
                            return
                        values.append({'id': s['id'], 'text': 'Hello, TypeBridge 12'})
                else:
                    values = [{'id': s['id'], 'text': words.get(s.get('text', s.get('draft')), s.get('text', s.get('draft')))}
                              for s in payload['segments']]
                content = json.dumps({'translations': values}, ensure_ascii=False)
                response = {'choices': [{'message': {'content': content}, 'finish_reason': 'stop'}]}
            elif self.path == '/translation/language/translate':
                if self.headers.get('Authorization') != 'Bearer local-test-secret':
                    self.send_error(401)
                    return
                body = json.loads(data)
                directions = {'1': ('EN', 'ZH'), '2': ('en', 'zh-cn'),
                              '3': ('en', 'zh'), '4': ('en', 'zh-CHS')}
                chinese_directions = {'1': ('ZH', 'EN'), '2': ('zh-cn', 'en'),
                                      '3': ('zh', 'en'), '4': ('zh-CHS', 'en')}
                pair = (body.get('sourceLang'), body.get('targetLang'))
                if (set(body) != {'text', 'sourceLang', 'targetLang', 'type'}
                        or not isinstance(body.get('text'), str)
                        or body.get('type') not in directions
                        or pair not in [directions[body['type']], chinese_directions[body['type']]]):
                    self.send_error(400)
                    return
                response = {'code': 200, 'msg': 'Request successful',
                            'data': {'translatedText': words.get(body['text'], body['text'])}}
            elif self.path == '/deepl/v2/translate':
                if self.headers.get('Authorization') != 'DeepL-Auth-Key local-test-secret':
                    self.send_error(403)
                    return
                body = json.loads(data)
                response = {'translations': [{'text': words.get(s, s)} for s in body['text']]}
            else:
                fields = {k: v[0] for k, v in parse_qs(data.decode()).items()}
                query = fields['q']
                if self.path == '/baidu':
                    raw = fields['appid'] + query + fields['salt'] + 'local-test-secret'
                    expected = hashlib.md5(raw.encode()).hexdigest()
                    response = {'trans_result': [{'src': s, 'dst': words.get(s, s)} for s in query.split('\n')]}
                else:
                    value = query if len(query) <= 20 else query[:10] + str(len(query)) + query[-10:]
                    raw = fields['appKey'] + value + fields['salt'] + fields['curtime'] + 'local-test-secret'
                    expected = hashlib.sha256(raw.encode()).hexdigest()
                    response = {'errorCode': '0', 'query': query, 'translation': [words.get(query, query)]}
                if fields['sign'] != expected:
                    self.send_error(403)
                    return
            result = json.dumps(response, ensure_ascii=False).encode()
        except (ValueError, KeyError, TypeError):
            self.send_error(400)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(result)))
        self.end_headers()
        try:
            self.wfile.write(result)
        except BrokenPipeError:
            pass


if __name__ == '__main__':
    print('固定样例测试服务：http://127.0.0.1:19081/v1（Control+C 退出）', flush=True)
    try:
        ThreadingHTTPServer(('127.0.0.1', 19081), Handler).serve_forever()
    except KeyboardInterrupt:
        pass
