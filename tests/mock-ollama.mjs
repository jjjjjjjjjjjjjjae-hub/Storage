import http from 'node:http';

const port = Number(process.argv[2] || 11439);
const server = http.createServer(async (req, res) => {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (req.method === 'GET' && req.url === '/api/tags') {
    res.end(JSON.stringify({models: [
      {name: 'qwen3:4b-instruct'}, {name: 'qwen3-vl:4b-instruct'},
    ]}));
    return;
  }
  if (req.method === 'POST' && req.url === '/api/chat') {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const data = JSON.parse(raw);
    const last = data.messages.at(-1);
    const photo = Array.isArray(last.images) && last.images.length === 1;
    const accepted = photo ? data.model === 'qwen3-vl:4b-instruct' : data.model === 'qwen3:4b-instruct';
    res.statusCode = accepted ? 200 : 400;
    res.end(JSON.stringify(accepted ? {done:true, done_reason:'stop', message:{content: photo ? 'Фото көрінді' : 'Мәтін көрінді'}} : {error:'Wrong model or image format'}));
    return;
  }
  res.statusCode = 404; res.end(JSON.stringify({error:'not found'}));
});
server.listen(port, '127.0.0.1');
