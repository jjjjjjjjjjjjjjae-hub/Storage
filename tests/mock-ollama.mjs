import http from 'node:http';

const port = Number(process.argv[2] || 11439);
const server = http.createServer(async (req, res) => {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (req.method === 'GET' && req.url === '/api/tags') {
    res.end(JSON.stringify({models: [
      {name: 'gpt-oss:20b'}, {name: 'qwen3-vl:4b-instruct'},
    ]}));
    return;
  }
  if (req.method === 'POST' && req.url === '/api/generate') {
    let raw='';
    for await (const chunk of req) raw+=chunk;
    const data=JSON.parse(raw);
    res.end(JSON.stringify({done:true,response:'',unloaded:data.model==='gpt-oss:20b' && data.keep_alive===0}));
    return;
  }
  if (req.method === 'POST' && req.url === '/api/chat') {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const data = JSON.parse(raw);
    const last = data.messages.at(-1);
    const photo = Array.isArray(last.images) && last.images.length === 1;
    if (!photo && data.think !== 'low') {
      res.statusCode=400;res.end(JSON.stringify({error:'gpt-oss:20b requires low reasoning mode'}));return;
    }
    // Ensure both correction and Logo&AI use the selected gpt-oss:20b model.
    if (data.format && data.model !== 'gpt-oss:20b') {
      res.statusCode=400;res.end(JSON.stringify({error:'Structured job used wrong model'}));return;
    }
    if (data.format) {
      let output;
      if (data.format.properties?.prompt_en && !data.format.properties?.interpreted_kk) {
        output={prompt_en:last.content.includes('ALT_OUT') ? 'ALT_OUT: A red apple' :
          last.content.includes('ERROR_OUT') ? 'ERROR_OUT: A red apple' :
          'A red apple on a wooden table, realistic photograph'};
      } else if (data.format.properties?.prompt_en) {
        const request = JSON.parse(last.content);
        output = request.stage === 'build'
          ? {interpreted_kk:'Құрылғылар бөлімінің анимациясын тегістеу',questions:[],prompt_en:'Improve the animation in the Devices section. Respond in Kazakh.',uncertain:false}
          : {interpreted_kk:'Сайт анимациясын жақсарту',questions:['Қай бөлімді өзгертейін?'],prompt_en:'Improve website animation. Section unspecified. Respond in Kazakh.',uncertain:true};
      } else output = {corrected_text:'Сәлем, әлем!',uncertain:false};
      res.end(JSON.stringify({done:true,done_reason:'stop',message:{content:JSON.stringify(output)}}));
      return;
    }
    const accepted = photo ? data.model === 'qwen3-vl:4b-instruct' : data.model === 'gpt-oss:20b';
    res.statusCode = accepted ? 200 : 400;
    res.end(JSON.stringify(accepted ? {done:true, done_reason:'stop', message:{content: photo ? 'Фото көрінді' : 'Мәтін көрінді'}} : {error:'Wrong model or image format'}));
    return;
  }
  res.statusCode = 404; res.end(JSON.stringify({error:'not found'}));
});
server.listen(port, '127.0.0.1');
