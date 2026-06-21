const http = require('http');

const PORT = process.env.PORT || 8080;

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end('<html><body><h1>Hello from AWS App Runner!</h1></body></html>\n');
});

server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
